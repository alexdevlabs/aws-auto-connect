import Foundation
import os

/// Logs to the unified log and to ~/Library/Logs/AWSAutoConnect.log.
struct AppLog: Sendable {
    let category: String
    private let logger: Logger

    init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: "aws-autoconnect", category: category)
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AWSAutoConnect.log")
    private static let queue = DispatchQueue(label: "aws-autoconnect.log")

    func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        Self.append("[\(category)] \(message)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Self.append("[\(category)] ERROR \(message)")
    }

    /// Unit tests log to the unified log only.
    private static let testing = NSClassFromString("XCTestCase") != nil

    private static func append(_ line: String) {
        guard !testing else { return }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let data = Data("\(stamp) \(line)\n".utf8)
        queue.async {
            let fm = FileManager.default
            // Keep it small: start over past 1 MB.
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 1 << 20 {
                try? fm.removeItem(at: fileURL)
            }
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    }
}
