import AppKit
import Foundation
import Observation

/// A profile from the official AWS VPN Client (~/.config/AWSVPNClient/ConnectionProfiles).
struct VPNProfile: Hashable, Identifiable {
    let name: String
    let configPath: String
    var id: String { name }

    static func all() -> [VPNProfile] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/AWSVPNClient/ConnectionProfiles")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["ConnectionProfiles"] as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let name = p["ProfileName"] as? String, let path = p["OvpnConfigFilePath"] as? String else { return nil }
            return VPNProfile(name: name, configPath: path)
        }
    }
}

/// The root-owned pieces installed by helper/install-helper.sh.
enum VPNHelper {
    static let dir = "/usr/local/libexec/aws-autoconnect"
    static let helper = dir + "/vpn-helper"
    static let openvpn = dir + "/openvpn"
    static let etc = "/usr/local/etc/aws-autoconnect"
    static let profile = etc + "/profile.ovpn"
    static let sudoers = "/etc/sudoers.d/aws-autoconnect"
    static let pidFile = "/var/run/aws-autoconnect/openvpn.pid"
    static let logFile = "/var/log/aws-autoconnect.log"

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helper) && FileManager.default.fileExists(atPath: sudoers)
    }

    /// helper/helper-version, stamped into `dir` by the installer. Bump it whenever anything the
    /// installer puts in place changes (the relay, dns.sh, vpn-helper), so installs ask to be updated.
    static let versionFile = dir + "/version"
    static var bundledVersion: String? { Bundle.main.path(forResource: "helper-version", ofType: nil).flatMap(readVersion) }

    /// Installed, but from an older app: its files predate the ones this app ships.
    static var isOutdated: Bool {
        guard isInstalled, let bundled = bundledVersion else { return false }
        return readVersion(versionFile) != bundled
    }

    private static func readVersion(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var installedProfileName: String? {
        guard isInstalled else { return nil }
        return (try? String(contentsOfFile: etc + "/profile.name", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// (host, port, proto) of the installed profile.
    static func endpoint() throws -> (host: String, port: String, proto: String) {
        let raw = (try? String(contentsOfFile: etc + "/endpoint", encoding: .utf8)) ?? ""
        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 3 else { throw AppError("VPN helper not installed – open Settings ▸ VPN") }
        return (parts[0], parts[1], parts[2])
    }

    static var isTunnelRunning: Bool {
        guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        // The tunnel runs as root, so EPERM still means "alive".
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func install(_ profile: VPNProfile) async throws {
        guard let res = Bundle.main.resourcePath else { throw AppError("Missing app resources") }
        try await runAsAdmin(script: res + "/install-helper.sh", args: [res, profile.configPath, profile.name, NSUserName()])
    }

    static func uninstall() async throws {
        guard let res = Bundle.main.resourcePath else { throw AppError("Missing app resources") }
        try await runAsAdmin(script: res + "/uninstall-helper.sh", args: [])
    }

    /// Shows the standard macOS admin password prompt (naming this app) and runs a bundled script as
    /// root. Cancelling the prompt throws `CancellationError`. NSAppleScript belongs on the main thread,
    /// so the app waits a moment first to let the panel show that it's working.
    @MainActor
    private static func runAsAdmin(script: String, args: [String]) async throws {
        func quoted(_ s: String) -> String {
            "quoted form of \"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let command = ([quoted("/bin/bash"), quoted(script)] + args.map(quoted)).joined(separator: " & \" \" & ")
        let source = "do shell script \(command) with administrator privileges"
        try? await Task.sleep(for: .milliseconds(150))
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return }
        if error[NSAppleScript.errorNumber] as? Int == -128 { throw CancellationError() }
        throw AppError(error[NSAppleScript.errorMessage] as? String ?? "Admin script failed")
    }
}
