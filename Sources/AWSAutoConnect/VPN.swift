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

    static func install(_ profile: VPNProfile) throws {
        guard let res = Bundle.main.resourcePath else { throw AppError("Missing app resources") }
        try runAsAdmin(script: res + "/install-helper.sh", args: [res, profile.configPath, profile.name, NSUserName()])
    }

    static func uninstall() throws {
        guard let res = Bundle.main.resourcePath else { throw AppError("Missing app resources") }
        try runAsAdmin(script: res + "/uninstall-helper.sh", args: [])
    }

    /// Shows the standard macOS admin password prompt and runs a bundled script as root.
    private static func runAsAdmin(script: String, args: [String]) throws {
        func quoted(_ s: String) -> String {
            "quoted form of \"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let command = ([quoted("/bin/bash"), quoted(script)] + args.map(quoted)).joined(separator: " & \" \" & ")
        let source = "do shell script \(command) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            throw AppError(error[NSAppleScript.errorMessage] as? String ?? "Admin script failed")
        }
    }
}

/// Connects AWS Client VPN with SAML using the patched openvpn:
/// 1. openvpn (as you) gets an AUTH_FAILED,CRV1 challenge with the SAML URL,
/// 2. the hidden browser signs in and Google posts the assertion to 127.0.0.1:35001,
/// 3. the root helper starts openvpn again with `CRV1::<sid>::<assertion>` as the password.
@MainActor
@Observable
final class VPNController {
    enum State: Equatable {
        case disconnected
        case connecting(String)
        case connected
        case failed(String)
    }

    private(set) var state: State = .disconnected { didSet { onChange?() } }
    /// Whether you asked to be connected; drives reconnects.
    private(set) var wantsConnection = false

    @ObservationIgnored var onChange: (() -> Void)?
    /// Runs right before the root helper starts the tunnel (sends the DNS allowlist).
    @ObservationIgnored var beforeTunnel: (() async -> Void)?
    @ObservationIgnored private let browser: HeadlessBrowser
    @ObservationIgnored private let log = AppLog("vpn")

    init(browser: HeadlessBrowser) {
        self.browser = browser
        if VPNHelper.isTunnelRunning {
            state = .connected
            wantsConnection = true
        }
    }

    var isBusy: Bool { if case .connecting = state { return true } else { return false } }

    var summary: String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting(let step): return "Connecting – \(step)…"
        case .connected: return "Connected" + (VPNHelper.installedProfileName.map { " (\($0))" } ?? "")
        case .failed(let msg): return msg
        }
    }

    func connect() async {
        guard !isBusy else { return }
        wantsConnection = true
        do {
            guard VPNHelper.isInstalled else { throw AppError("VPN helper not installed – open Settings ▸ VPN") }
            if VPNHelper.isTunnelRunning {
                state = .connected
                return
            }
            let ep = try VPNHelper.endpoint()

            state = .connecting("resolving")
            // remote-random-hostname: both openvpn runs must hit the same server IP.
            let prefix = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let ip = try await Self.resolveIPv4("\(prefix).\(ep.host)")

            let server = SAMLServer()
            try server.start()
            defer { server.stop() }

            // Wait for an SSO refresh using the browser first: the challenge below expires.
            let (sid, saml) = try await browser.exclusive {
                state = .connecting("requesting sign-in")
                let (sid, url) = try await requestChallenge(ip: ip, port: ep.port, proto: ep.proto)

                state = .connecting("signing in")
                browser.automate(url)
                let watchdog = Task { [browser] in
                    var waited = 0
                    while waited < 600 {
                        try? await Task.sleep(for: .seconds(5))
                        if Task.isCancelled { return }
                        waited += 5
                        if waited >= 90, !browser.needsUser { break }
                    }
                    await browser.logStuckPage()
                    server.fail(AppError("VPN sign-in timed out"))
                }
                defer { watchdog.cancel(); browser.stop() }
                return (sid, try await server.response())
            }

            state = .connecting("starting tunnel")
            await beforeTunnel?()
            let auth = FileManager.default.temporaryDirectory.appendingPathComponent("aws-autoconnect-\(UUID().uuidString)")
            try Self.writePrivate("N/A\nCRV1::\(sid)::\(saml)\n", to: auth)
            defer { try? FileManager.default.removeItem(at: auth) }

            let r = await Shell.run("/usr/bin/sudo", ["-n", VPNHelper.helper, "connect", ip, ep.port, ep.proto, auth.path], timeout: 30)
            guard r.status == 0 else { throw AppError("Helper failed: \(r.lastLine)") }
            try await waitForTunnel()
            state = .connected
            log.info("connected")
        } catch {
            log.error("connect failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        wantsConnection = false
        if VPNHelper.isInstalled {
            _ = await Shell.run("/usr/bin/sudo", ["-n", VPNHelper.helper, "disconnect"], timeout: 15)
        }
        state = .disconnected
    }

    /// Syncs state with the tunnel process. Returns true if a live tunnel just died.
    func checkTunnel() -> Bool {
        let running = VPNHelper.isTunnelRunning
        switch state {
        case .connected where !running:
            state = .failed("VPN dropped")
            return true
        case .disconnected where running, .failed where running:
            state = .connected
        default:
            break
        }
        return false
    }

    // MARK: Steps

    private func requestChallenge(ip: String, port: String, proto: String) async throws -> (String, URL) {
        let creds = FileManager.default.temporaryDirectory.appendingPathComponent("aws-autoconnect-challenge")
        try Self.writePrivate("N/A\nACS::35001\n", to: creds)
        defer { try? FileManager.default.removeItem(at: creds) }

        let proc = StreamingProcess(VPNHelper.openvpn, [
            "--config", VPNHelper.profile, "--verb", "3",
            "--proto", proto, "--remote", ip, port,
            "--auth-user-pass", creds.path, "--auth-retry", "none",
        ])
        var challenge: (String, URL)?
        proc.onLine = { line in
            guard challenge == nil, let found = Self.parseChallenge(line) else { return }
            challenge = found
            proc.terminate()
        }
        let result = await proc.run(timeout: 30)
        // Lines are delivered on the main queue; let any last ones land.
        await Task.yield()
        if challenge == nil, let line = result.output.split(separator: "\n").first(where: { $0.contains("CRV1") }) {
            challenge = Self.parseChallenge(String(line))
        }
        guard let challenge else { throw AppError("No SAML challenge from VPN: \(result.lastLine)") }
        return challenge
    }

    /// `AUTH_FAILED,CRV1:R:<sid>:<b64 user>:<url>` → (sid, url)
    static func parseChallenge(_ line: String) -> (String, URL)? {
        guard let r = line.range(of: #"CRV1:[^:]*:([^:]+):[^:]*:(https://\S+)"#, options: .regularExpression) else { return nil }
        let match = String(line[r])
        let parts = match.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5, let url = URL(string: String(parts[4])) else { return nil }
        return (String(parts[2]), url)
    }

    private func waitForTunnel() async throws {
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(750))
            let tail = (try? String(contentsOfFile: VPNHelper.logFile, encoding: .utf8)) ?? ""
            if tail.contains("Initialization Sequence Completed") { return }
            if tail.contains("AUTH_FAILED") { throw AppError("VPN rejected the sign-in (AUTH_FAILED)") }
            if !VPNHelper.isTunnelRunning, tail.contains("Exiting") {
                let last = tail.split(separator: "\n").suffix(1).joined()
                throw AppError("openvpn exited: \(last)")
            }
        }
        throw AppError("Tunnel did not come up within 30s – see \(VPNHelper.logFile)")
    }

    private static func writePrivate(_ text: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try Data(text.utf8).write(to: url)
    }

    nonisolated static func resolveIPv4(_ host: String) async throws -> String {
        try await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
                throw AppError("DNS lookup failed for the VPN endpoint")
            }
            defer { freeaddrinfo(res) }
            var addr = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        }.value
    }
}
