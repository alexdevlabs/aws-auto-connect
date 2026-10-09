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
    private(set) var state: State = .unknown {
        didSet { if Self.kind(state) != Self.kind(oldValue) { log.info("now: \(status.summary)") } }
    }
    @ObservationIgnored private let context: ConnectorContext
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private let log = AppLog("grafana")
    /// The setup last written to the log, so it's logged again only when it changes.
    @ObservationIgnored private var loggedSetup: String?
    /// The last failed check and note written to the log: a check that keeps failing the same way
    /// (every few minutes while signed out) is logged once, not every time.
    @ObservationIgnored private var loggedFailure: String?
    @ObservationIgnored private var loggedNote: String?

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

    var approvals: ApprovalRules { Self.approvalRules(stackHost: stackHost) }

    nonisolated static func approvalRules(stackHost: String) -> ApprovalRules {
        let host = stackHost.trimmingCharacters(in: .whitespaces).lowercased()
        return ApprovalRules(
            hosts: ["grafana.net", "grafana.com"] + (host.isEmpty ? [] : [host]),
            buttons: "^(ok|authorize|approve|allow|allow access|confirm|continue)$",
            done: "you can close|login successful|logged in successfully|authentication complete"
        )
    }

    // MARK: Connector

    let title = "Grafana"
    let symbol = "gauge.with.dots.needle.67percent"

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

    var settingsPages: [SettingsPage] {
        [SettingsPage("grafana", title: title, height: 380) { GrafanaSettings(connector: self) }]
    }

    /// Ignores the check time, so a fresh "Signed in" isn't logged every few minutes.
    private static func kind(_ state: State) -> String {
        if case .valid = state { return "valid" }
        return "\(state)"
    }

    func tick(afterWake: Bool) {
        guard state != .refreshing, !checking, context.isOnline() else { return }
        if onlyWithVPN, !context.tunnelUp() {
            state = .waitingForVPN
            return
        }
        let due = afterWake || state == .waitingForVPN
            || (lastCheck ?? .distantPast).addingTimeInterval(Double(max(1, checkMinutes) * 60)) < Date()
        guard due else { return }
        let then: OnSignedOut = !autoRefresh ? .hold("auto sign-in is off")
            : context.isQuiet ? .hold("quiet hours") : .signIn
        checking = true  // now, so a tick right behind this one doesn't start a second check
        Task { await check(ifSignedOut: then) }
    }

    /// What a check does when it finds you signed out.
    enum OnSignedOut: Equatable {
        case signIn
        /// Don't sign in, for this reason (logged).
        case hold(String)
        /// Right after `gcx auth login`: `signIn()` reports it.
        case report
    }

    // MARK: Check & sign in

    private var gcx: String? { Self.gcxPath }
    private static var gcxPath: String? { Shell.find("gcx") ?? userBin }
    /// Only offered when gcx is installed (or the connector is already turned on). Looked up at most
    /// every 30 s, since SwiftUI asks on every redraw.
    static var isAvailable: Bool {
        if let (found, at) = availability, at.timeIntervalSinceNow > -30 { return found }
        let found = gcxPath != nil
        availability = (found, Date())
        return found
    }
    private static var availability: (Bool, Date)?

    /// `go install`, mise, asdf and friends put it in places that aren't on a GUI app's PATH.
    private static var userBin: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/go/bin", "/usr/local/go/bin", "\(home)/.local/bin", "\(home)/bin",
                    "\(home)/.local/share/mise/shims", "\(home)/.asdf/shims"]
        return dirs.map { "\($0)/gcx" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var contextArgs: [String] {
        let c = contextName.trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? [] : ["--context", c]
    }

    func check(ifSignedOut then: OnSignedOut) async {
        guard let gcx else {
            checking = false
            if state != .checkFailed("gcx not found") { log.error("gcx not found in \(Shell.searchPath)") }
            state = .checkFailed("gcx not found")
            return
        }
        checking = true
        defer { checking = false }
        lastCheck = Date()
        await logSetup(gcx)
        let args = contextArgs + ["api", "/api/user"]
        let r = await Shell.run(gcx, args, timeout: 30)
        let result = Self.classify(status: r.status, output: r.output)
        let failure = "\(result) \(r.status) \(r.output)"
        if result == .ok {
            loggedFailure = nil
            loggedNote = nil
        } else if failure != loggedFailure {
            loggedFailure = failure
            log.info("gcx \(args.joined(separator: " ")) exited with \(r.status)\(r.status == 15 ? " (timed out after 30s)" : ""): \(result)")
            log.output("gcx output", r.output)
        }
        switch result {
        case .ok:
            retryAfter = nil
            state = .valid(checked: Date())
        case .signedOut:
            state = .expired
            switch then {
            case .report:
                break
            case .hold(let reason):
                note("not signing in by itself: \(reason)")
            case .signIn:
                if let retryAfter, retryAfter > Date() {
                    note("last sign-in failed, trying again after \(retryAfter.formatted(date: .omitted, time: .shortened))")
                } else {
                    loggedNote = nil
                    log.info("signed out, signing in")
                    await signIn()
                }
            }
        case .error:
            state = .checkFailed(Self.errorSummary(r.output) ?? (r.summary.isEmpty ? "exit \(r.status)" : r.summary))
        }
    }

    /// Logs `line` unless it's the same as the last note.
    private func note(_ line: String) {
        guard line != loggedNote else { return }
        loggedNote = line
        log.info(line)
    }

    /// Which gcx, its version and the settings in use, whenever any of them changes.
    private func logSetup(_ gcx: String) async {
        let setup = [gcx, contextName, stackHost, loginArguments, "\(onlyWithVPN)", "\(autoRefresh)"].joined(separator: "\u{1}")
        guard setup != loggedSetup else { return }
        loggedSetup = setup
        let version = await Shell.run(gcx, ["--version"], timeout: 10)
        let v = version.status == 0 ? version.lastLine : "unknown (--version exited with \(version.status))"
        let c = contextName.trimmingCharacters(in: .whitespaces)
        let host = stackHost.trimmingCharacters(in: .whitespaces)
        log.info("""
            gcx \(gcx), version \(v); context \(c.isEmpty ? "gcx's current" : c); \
            stack host \(host.isEmpty ? "not set" : host); login arguments \(loginArguments.isEmpty ? "none" : loginArguments); \
            auto sign-in \(autoRefresh ? "on" : "off"); only with VPN \(onlyWithVPN ? "on" : "off")
            """)
        if host.isEmpty {
            log.info("no stack host set: the browser only clicks on grafana.com and grafana.net pages")
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
        log.info("signing in with \(provider.name), clicking on \(rules.hosts.joined(separator: ", "))")
        do {
            try await CLILogin(browser: context.browser, name: "Grafana", executable: gcx,
                               arguments: contextArgs + ["auth", "login"] + extra) { url in
                BrowserJob(url: url, providers: [provider], approvals: [rules], reopenIfPageLost: true)
            }.run()
            log.info("gcx auth login ok, checking again")
            retryAfter = nil
            state = .unknown
            await check(ifSignedOut: .report)
            if state == .expired { log.error("still signed out after gcx auth login: check the context and stack host") }
        } catch {
            log.error("grafana sign-in failed: \(error.localizedDescription)")
            retryAfter = Date().addingTimeInterval(5 * 60)
            state = .failed(error.localizedDescription)
            context.notify("Grafana sign-in failed", error.localizedDescription)
        }
    }
}
