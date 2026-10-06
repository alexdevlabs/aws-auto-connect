import AppKit
import Foundation
import Observation

/// Connects AWS Client VPN with SAML using the patched openvpn:
/// 1. openvpn (as you) gets an AUTH_FAILED,CRV1 challenge with the SAML URL,
/// 2. the hidden browser signs in and the provider posts the assertion to 127.0.0.1:35001,
/// 3. the root helper starts openvpn again with `CRV1::<sid>::<assertion>` as the password.
/// Also owns DNS learning and the allowlist (`VPNDomains`), which the root helper's relay uses.
@MainActor
@Observable
final class AWSVPNConnector: TunnelConnector {
    static let type = "aws-vpn"
    static let displayName = "AWS Client VPN"
    static let enabledByDefault = true

    enum State: Equatable {
        case disconnected
        case connecting(String)
        case connected
        case failed(String)
    }

    var config: ConnectorConfig { didSet { context.store.save(config) } }
    private(set) var state: State = .disconnected
    /// Whether you asked to be connected; drives reconnects.
    private(set) var wantsConnection = false
    /// The connect in progress; Disconnect cancels it.
    @ObservationIgnored private var connecting: Task<Void, Never>?
    /// The disconnect in progress; a Connect clicked meanwhile starts after it.
    @ObservationIgnored private var disconnecting: Task<Void, Never>?
    /// Whether the root helper is installed. Kept here (not read from disk in views) so the panel
    /// updates when it changes; refreshed every tick and after installing or uninstalling.
    private(set) var helperInstalled = VPNHelper.isInstalled
    private(set) var installingHelper = false
    let domains: VPNDomains

    @ObservationIgnored private let context: ConnectorContext
    private var browser: HeadlessBrowser { context.browser }
    @ObservationIgnored private let log = AppLog("vpn")

    init(config: ConnectorConfig, context: ConnectorContext) {
        self.config = config
        self.context = context
        domains = VPNDomains(allowlistOn: config.bool("allowlistOn", default: false),
                             allowlist: config.string("allowlist").split(separator: "\n").map(String.init))
        domains.onChange = { [weak self] on, list in
            self?.config.set("allowlistOn", on)
            self?.config.set("allowlist", list.joined(separator: "\n"))
        }
        if VPNHelper.isTunnelRunning {
            state = .connected
            wantsConnection = true
        }
    }

    // MARK: Settings

    /// AWS VPN Client profile the helper is installed for.
    var profileName: String {
        get { config.string("profile") }
        set { config.set("profile", newValue) }
    }
    var connectAtLaunch: Bool {
        get { config.bool("connectAtLaunch", default: false) }
        set { config.set("connectAtLaunch", newValue) }
    }
    var reconnect: Bool {
        get { config.bool("reconnect", default: false) }
        set { config.set("reconnect", newValue) }
    }

    // MARK: Connector

    let title = "VPN"
    let symbol = "network"
    var isConnected: Bool { state == .connected }
    var isBusy: Bool { if case .connecting = state { return true } else { return false } }

    var status: ConnectorStatus {
        if installingHelper { return .init(health: .busy, summary: "Installing helper…") }
        switch state {
        case .disconnected where !helperInstalled:
            return .init(health: .idle, summary: Self.setup(hasProfiles: !VPNProfile.all().isEmpty).summary)
        case .disconnected: return .init(health: .idle, summary: "Disconnected")
        case .connecting(let step): return .init(health: .busy, summary: "Connecting – \(step)…")
        case .connected:
            return .init(health: .ok, summary: "Connected" + (VPNHelper.installedProfileName.map { " (\($0))" } ?? ""))
        case .failed(let msg): return .init(health: .attention, summary: msg)
        }
    }

    var actions: [ConnectorAction] {
        if state == .connected || isBusy {
            return [ConnectorAction(title: "Disconnect") { [weak self] in await self?.disconnect() }]
        }
        guard helperInstalled else {
            let setup = Self.setup(hasProfiles: !VPNProfile.all().isEmpty)
            return [ConnectorAction(title: setup.action, enabled: setup.enabled && !installingHelper) { [weak self] in
                await self?.installFromStatus()
            }]
        }
        return [ConnectorAction(title: "Connect") { [weak self] in await self?.connect() }]
    }

    /// What the Status row says and offers while the helper isn't installed.
    static func setup(hasProfiles: Bool) -> (summary: String, action: String, enabled: Bool) {
        hasProfiles
            ? ("Helper is not installed", "Install Helper…", true)
            : ("Add a profile in AWS VPN Client first", "Install Helper…", false)
    }

    /// Same as the VPN tab's Install Helper…, for the selected profile (or the first one).
    private func installFromStatus() async {
        let profiles = VPNProfile.all()
        guard let profile = profiles.first(where: { $0.name == profileName }) ?? profiles.first else { return }
        do {
            try await installHelper(profile)
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Installs the root helper for `profile` (admin password prompt).
    func installHelper(_ profile: VPNProfile) async throws {
        guard !installingHelper else { return }
        installingHelper = true
        defer { installingHelper = false; refreshHelper() }
        try await VPNHelper.install(profile)
        profileName = profile.name
        if case .failed = state { state = .disconnected }
        log.info("helper installed for \(profile.name)")
    }

    func uninstallHelper() async throws {
        guard !installingHelper else { return }
        installingHelper = true
        defer { installingHelper = false; refreshHelper() }
        try await VPNHelper.uninstall()
        log.info("helper uninstalled")
    }

    private func refreshHelper() {
        let now = VPNHelper.isInstalled
        if now != helperInstalled { helperInstalled = now }
    }

    var settingsPages: [SettingsPage] {
        let toReview = domains.learned.filter { !domains.isAllowed($0.name) }.count
        return [
            SettingsPage("vpn", title: title, height: 380) { VPNSettings(connector: self) },
            SettingsPage("dns", title: "DNS", height: 440, badge: toReview > 0 ? "\(toReview)" : nil) {
                DNSSettings(connector: self)
            },
        ]
    }

    func start() {
        if connectAtLaunch, !context.isQuiet, !VPNHelper.isTunnelRunning {
            Task { await connect() }
        }
    }

    func tick(afterWake: Bool) {
        refreshHelper()
        domains.ingest()
        let dropped = checkTunnel()
        let shouldReconnect = reconnect && !context.isQuiet && wantsConnection && !isBusy
        if dropped || (afterWake && !VPNHelper.isTunnelRunning && wantsConnection) {
            if shouldReconnect {
                log.info("reconnecting VPN")
                Task { await connect() }
            } else if dropped {
                context.notify("VPN disconnected", "The tunnel dropped. Reconnect from the menu bar.")
            }
        }
    }

    // MARK: Connect

    func connect() async {
        if let disconnecting { await disconnecting.value }
        if let connecting, !connecting.isCancelled { return await connecting.value }
        wantsConnection = true
        let task = Task { await runConnect() }
        connecting = task
        await task.value
        if connecting == task { connecting = nil }
    }

    private func runConnect() async {
        do {
            guard VPNHelper.isInstalled else { throw AppError("VPN helper not installed – open the VPN tab") }
            if VPNHelper.isTunnelRunning {
                state = .connected
                return
            }
            let ep = try VPNHelper.endpoint()

            state = .connecting("resolving")
            // remote-random-hostname: both openvpn runs must hit the same server IP.
            let prefix = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            let ip = try await Self.resolveIPv4("\(prefix).\(ep.host)")

            let server = FormPostListener(port: 35001, field: "SAMLResponse",
                                          busyHint: " (is the AWS VPN Client connecting?)",
                                          thanks: "VPN sign-in received. You can close this.")
            try server.start()
            defer { server.stop() }

            // Wait for another connector using the browser first: the challenge below expires.
            let provider = context.provider(for: config)
            let (sid, saml) = try await browser.exclusive {
                try Task.checkCancellation()
                state = .connecting("requesting sign-in")
                let (sid, url) = try await requestChallenge(ip: ip, port: ep.port, proto: ep.proto)

                state = .connecting("signing in")
                browser.automate(BrowserJob(url: url, providers: [provider], approvals: []))
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
                let saml = try await withTaskCancellationHandler {
                    try await server.response()
                } onCancel: {
                    server.fail(CancellationError())
                }
                return (sid, saml)
            }
            try Task.checkCancellation()

            state = .connecting("starting tunnel")
            await domains.sync()
            let auth = FileManager.default.temporaryDirectory.appendingPathComponent("aws-autoconnect-\(UUID().uuidString)")
            try Self.writePrivate("N/A\nCRV1::\(sid)::\(saml)\n", to: auth)
            defer { try? FileManager.default.removeItem(at: auth) }

            let r = await Shell.run("/usr/bin/sudo", ["-n", VPNHelper.helper, "connect", ip, ep.port, ep.proto, auth.path], timeout: 30)
            guard r.status == 0 else { throw AppError("Helper failed: \(r.lastLine)") }
            try await waitForTunnel()  // Disconnect, which cancelled us, stops the tunnel after this
            state = .connected
            log.info("connected")
        } catch is CancellationError {
            log.info("connect cancelled")
        } catch {
            log.error("connect failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        wantsConnection = false
        if let disconnecting { return await disconnecting.value }
        let task = Task {
            if let connecting {
                connecting.cancel()
                await connecting.value  // so the tunnel can't come up after the disconnect below
            }
            if VPNHelper.isInstalled {
                _ = await Shell.run("/usr/bin/sudo", ["-n", VPNHelper.helper, "disconnect"], timeout: 15)
            }
            state = .disconnected
        }
        disconnecting = task
        await task.value
        if disconnecting == task { disconnecting = nil }
    }

    /// Whether quitting has to wait for `stop()`.
    var needsStop: Bool { VPNHelper.isTunnelRunning || connecting != nil }

    /// The tunnel goes down with the app, including one that's still coming up.
    func stop() async {
        wantsConnection = false
        guard needsStop else { return }
        log.info("app quitting, disconnecting")
        await disconnect()
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
