import CryptoKit
import Foundation

struct SSOSession: Hashable, Identifiable {
    let name: String
    let startURL: String
    let region: String
    var id: String { name }
}

/// Minimal reader for ~/.aws/config.
enum AWSConfig {
    struct Section {
        let name: String
        var values: [String: String]
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/config")
    }

    static func sections() -> [Section] {
        sections(in: (try? String(contentsOf: configURL, encoding: .utf8)) ?? "")
    }

    static func sections(in text: String) -> [Section] {
        var out: [Section] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                out.append(Section(name: name, values: [:]))
                continue
            }
            guard !out.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            out[out.count - 1].values[key] = value
        }
        return out
    }

    static func ssoSessions(_ sections: [Section] = AWSConfig.sections()) -> [SSOSession] {
        sections.compactMap { s in
            guard s.name.hasPrefix("sso-session "),
                  let url = s.values["sso_start_url"],
                  let region = s.values["sso_region"] else { return nil }
            let name = String(s.name.dropFirst("sso-session ".count)).trimmingCharacters(in: .whitespaces)
            return SSOSession(name: name, startURL: url, region: region)
        }
    }

    /// Any profile that uses the given sso-session; used to trigger a silent token refresh.
    static func profile(using session: String, in sections: [Section] = AWSConfig.sections()) -> String? {
        for s in sections where s.values["sso_session"] == session {
            if s.name == "default" { return "default" }
            if s.name.hasPrefix("profile ") {
                return String(s.name.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

struct SSOToken {
    let expiresAt: Date
}

/// Reads the token the AWS CLI caches in ~/.aws/sso/cache/<sha1(session name)>.json.
enum SSOCache {
    static func url(for session: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(session.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/sso/cache/\(name).json")
    }

    static func token(for session: String) -> SSOToken? {
        guard let data = try? Data(contentsOf: url(for: session)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["expiresAt"] as? String,
              let date = parseDate(raw) else { return nil }
        return SSOToken(expiresAt: date)
    }

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.replacingOccurrences(of: "UTC", with: "Z")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
