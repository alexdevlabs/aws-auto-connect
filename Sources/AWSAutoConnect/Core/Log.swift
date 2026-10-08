import Foundation
import os

/// Logs to the unified log and to ~/Library/Logs/AWSAutoConnect.log. Every line goes through
/// `redact`, so the file can be sent along with a bug report.
struct AppLog: Sendable {
    let category: String
    private let logger: Logger

    init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: "aws-autoconnect", category: category)
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AWSAutoConnect.log")
    /// The previous file, kept when the log starts over.
    static let oldFileURL = fileURL.deletingLastPathComponent().appendingPathComponent("AWSAutoConnect.old.log")
    static let queue = DispatchQueue(label: "aws-autoconnect.log")

    func info(_ message: String) { write(message, error: false) }

    func error(_ message: String) { write(message, error: true) }

    private func write(_ message: String, error: Bool) {
        let now = Date()
        let (logger, category) = (logger, category)
        // Masking is regex work: keep it off the caller's thread (usually the main one).
        Self.queue.async {
            let message = Self.redact(message)
            if error { logger.error("\(message, privacy: .public)") } else { logger.notice("\(message, privacy: .public)") }
            Self.append("[\(category)] \(error ? "ERROR " : "")\(message)", at: now)
        }
    }

    /// A command's output, last `lines` lines, one log line each.
    func output(_ title: String, _ text: String, lines: Int = 20) {
        let all = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !all.isEmpty else { return info("\(title): (no output)") }
        let shown = all.suffix(lines)
        info("\(title)\(all.count > shown.count ? " (last \(shown.count) of \(all.count) lines)" : ""):")
        for line in shown { info("  | \(line.prefix(500))") }
    }

    /// Masks what shouldn't leave the Mac: tokens, codes, keys and secrets in URLs, env vars and JSON,
    /// Authorization headers, JWTs, bearer tokens, device codes, AWS secret keys, email addresses and
    /// other long opaque strings.
    nonisolated static func redact(_ text: String) -> String {
        var s = text
        for (pattern, template) in redactions {
            s = pattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    private nonisolated static let secretName = "[a-z0-9_]*(?:token|secret|password|passwd|key|code|session|credential|signature|sig|assertion|samlresponse|relaystate|state)[a-z0-9_]*"
    private nonisolated static let redactions: [(NSRegularExpression, String)] = [
        // Command-line flags: --token abc, --password=abc, --api-key abc
        (#"(?i)(\s|^)(--?[a-z0-9-]*(?:token|password|passwd|secret|key|credential)[a-z0-9-]*)(=|\s+)(?!-)[^\s"']+"#, "$1$2$3<redacted>"),
        // name=value in URLs and env vars (user_code=…, AWS_SECRET_ACCESS_KEY=…)
        (#"(?i)\b("# + secretName + #"=)[^&\s"']+"#, "$1<redacted>"),
        // "name": "value" in JSON ("SecretAccessKey", "accessToken", …)
        (#"(?i)("[a-z0-9_]*(?:token|secret|password|passwd|key|code|session|credential)[a-z0-9_]*"\s*:\s*")[^"]*""#, "$1<redacted>\""),
        (#"(?i)\b(authorization["']?\s*[:=]\s*["']?(?:bearer|basic|token)?\s*)[^\s"',]+"#, "$1<redacted>"),
        // A bearer token, not the word: long and with a digit in it.
        (#"(?i)\b(bearer)\s+(?=[a-z0-9._~+/=-]*[0-9])[a-z0-9._~+/=-]{12,}"#, "$1 <redacted>"),
        (#"\beyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]*"#, "<jwt>"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        // Device codes (ABCD-EFGH) on their own, not the middle of a UUID.
        (#"(?<![A-Za-z0-9-])[A-Z0-9]{4}-[A-Z0-9]{4}(?![A-Za-z0-9-])"#, "<code>"),
        // AWS secret access keys: 40 base64 characters, mixed case with a digit ('/' allowed).
        (#"(?<![A-Za-z0-9+/])(?=[A-Za-z0-9+/]{0,39}[0-9])(?=[A-Za-z0-9+/]{0,39}[a-z])(?=[A-Za-z0-9+/]{0,39}[A-Z])[A-Za-z0-9+/]{40}(?![A-Za-z0-9+/=])"#, "<redacted>"),
        (#"(?<![A-Za-z0-9/._-])[A-Za-z0-9+_-]{40,}={0,2}"#, "<redacted>"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Unit tests log to the unified log only.
    private static let testing = NSClassFromString("XCTestCase") != nil

    /// Runs on `queue`.
    private static func append(_ line: String, at date: Date) {
        guard !testing else { return }
        let stamp = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime])
        let data = Data("\(stamp) \(line)\n".utf8)
        let fm = FileManager.default
        // Keep it small: past 2 MB start over, keeping the previous file as .old.log.
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 2 << 20 {
            try? fm.removeItem(at: oldFileURL)
            try? fm.moveItem(at: fileURL, to: oldFileURL)
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    }
}
