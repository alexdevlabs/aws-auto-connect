import Foundation
import Observation

/// Keeps the Grafana CLI (`gcx`) signed in. Every few minutes it checks the login with
/// `gcx api /api/user`; when that's rejected it runs `gcx auth login` and the hidden browser presses OK
/// on Grafana's page (signing in with your provider on the way if needed).
@MainActor
@Observable
final class GrafanaConnector: Connector {
    static let type = "grafana"
    static let displayName = "Grafana (gcx)"
    static let enabledByDefault = false

    enum State: Equatable {
        case unknown
        case valid(checked: Date)
        case expired
        case refreshing
        case waitingForVPN
        case checkFailed(String)
        case failed(String)
    }

    var config: ConnectorConfig { didSet { context.store.save(config) } }
    private(set) var state: State = .unknown
    @ObservationIgnored private let context: ConnectorContext
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private let log = AppLog("grafana")

    init(config: ConnectorConfig, context: ConnectorContext) {
        self.config = config
        self.context = context
    }

    // MARK: Settings

    var autoRefresh: Bool {
        get { config.bool("autoRefresh", default: true) }
        set { config.set("autoRefresh", newValue) }
    }
    /// gcx context name; empty uses gcx's current context.
    var contextName: String {
        get { config.string("context") }
        set { config.set("context", newValue) }
    }
    /// Your stack's host (e.g. "myorg.grafana.net"), so its pages count as Grafana's.
    var stackHost: String {
        get { config.string("stackHost") }
        set { config.set("stackHost", newValue) }
    }
    /// Extra arguments for `gcx auth login`, separated by spaces.
    var loginArguments: String {
        get { config.string("loginArguments") }
        set { config.set("loginArguments", newValue) }
    }
    var checkMinutes: Int {
        get { config.int("checkMinutes", default: 5) }
        set { config.set("checkMinutes", newValue) }
    }
    /// Only check and sign in while a VPN connector is connected (for stacks behind the VPN).
    var onlyWithVPN: Bool {
        get { config.bool("onlyWithVPN", default: false) }
        set { config.set("onlyWithVPN", newValue) }
    }

    var approvals: ApprovalRules {
        let host = stackHost.trimmingCharacters(in: .whitespaces).lowercased()
        return ApprovalRules(
            hosts: ["grafana.net", "grafana.com"] + (host.isEmpty ? [] : [host]),
            buttons: "^(ok|authorize|approve|allow|allow access|confirm|continue)$",
            done: "you can close|login successful|logged in successfully|authentication complete"
        )
    }

    // MARK: Connector

    let title = "Grafana"
    let symbol = "chart.xyaxis.line"

    var status: ConnectorStatus {
        switch state {
        case .unknown: return .init(health: .idle, summary: "Not checked yet")
        case .valid(let checked):
            return .init(health: .ok, summary: "Signed in · checked \(checked.formatted(date: .omitted, time: .shortened))")
        case .expired: return .init(health: .attention, summary: "Signed out")
        case .refreshing:
            return .init(health: .busy, summary: context.browser.needsUser ? "Waiting for sign-in…" : "Signing in…")
        case .waitingForVPN: return .init(health: .idle, summary: "Waiting for the VPN")
        case .checkFailed(let msg): return .init(health: .idle, summary: "Couldn't check: \(msg)")
        case .failed(let msg): return .init(health: .attention, summary: msg)
        }
    }

    var actions: [ConnectorAction] {
        [ConnectorAction(title: "Sign In", enabled: state != .refreshing) { [weak self] in await self?.signIn() }]
    }

    var settingsTabs: [SettingsTab] {
        [SettingsTab("Grafana", height: 360) { GrafanaSettings(connector: self) }]
    }

    func tick(afterWake: Bool) {
        guard state != .refreshing, !checking else { return }
        if onlyWithVPN, !context.tunnelUp() {
            state = .waitingForVPN
            return
        }
        let due = afterWake || state == .waitingForVPN
            || (lastCheck ?? .distantPast).addingTimeInterval(Double(max(1, checkMinutes) * 60)) < Date()
        guard due else { return }
        Task { await check(autoSignIn: autoRefresh && !context.isQuiet) }
    }

    // MARK: Check & sign in

    private var gcx: String? { Self.gcxPath }
    private static var gcxPath: String? { Shell.find("gcx") ?? goBin }
    /// Only offered when gcx is installed.
    static var isAvailable: Bool { gcxPath != nil }

    /// `go install` puts it in ~/go/bin, which isn't on a GUI app's PATH.
    private static var goBin: String? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("go/bin/gcx").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private var contextArgs: [String] {
        let c = contextName.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? [] : ["--context", c]
    }

    func check(autoSignIn: Bool) async {
        guard let gcx else { state = .checkFailed("gcx not found"); return }
        checking = true
        defer { checking = false }
        lastCheck = Date()
        let r = await Shell.run(gcx, contextArgs + ["api", "/api/user"], timeout: 30)
        switch Self.classify(status: r.status, output: r.output) {
        case .ok:
            retryAfter = nil
            state = .valid(checked: Date())
        case .signedOut:
            state = .expired
            if autoSignIn, (retryAfter ?? .distantPast) < Date() {
                log.info("signed out, signing in")
                await signIn()
            }
        case .error:
            state = .checkFailed(Self.errorSummary(r.output) ?? (r.lastLine.isEmpty ? "exit \(r.status)" : r.lastLine))
        }
    }

    enum CheckResult: Equatable { case ok, signedOut, error }

    /// What a `gcx api /api/user` run means.
    nonisolated static func classify(status: Int32, output: String) -> CheckResult {
        if status == 0 { return .ok }
        let signedOut = #"\b401\b|unauthori[sz]ed|token.{0,40}(expired|invalid)|(expired|invalid).{0,40}token|not (logged|signed) in|auth login|login required|no credentials"#
        return output.range(of: signedOut, options: [.regularExpression, .caseInsensitive]) != nil ? .signedOut : .error
    }

    /// gcx prints errors as {"error": {"summary": …}} in agent mode.
    nonisolated static func errorSummary(_ output: String) -> String? {
        guard let start = output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["summary"] as? String
    }

    func signIn() async {
        guard let gcx else { state = .checkFailed("gcx not found"); return }
        guard state != .refreshing else { return }
        state = .refreshing
        let provider = context.provider(for: config)
        let rules = approvals
        let extra = loginArguments.split(whereSeparator: \.isWhitespace).map(String.init)
        do {
            try await CLILogin(browser: context.browser, name: "Grafana", executable: gcx,
                               arguments: contextArgs + ["auth", "login"] + extra) { url in
                BrowserJob(url: url, providers: [provider], approvals: [rules])
            }.run()
            log.info("gcx auth login ok")
            retryAfter = nil
            state = .unknown
            await check(autoSignIn: false)
        } catch {
            log.error("grafana sign-in failed: \(error.localizedDescription)")
            retryAfter = Date().addingTimeInterval(5 * 60)
            state = .failed(error.localizedDescription)
            context.notify("Grafana sign-in failed", error.localizedDescription)
        }
    }
}
