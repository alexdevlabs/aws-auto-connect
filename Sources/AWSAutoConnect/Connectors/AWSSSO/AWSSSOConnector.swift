import Foundation
import Observation

/// Keeps an AWS CLI sso-session fresh: silently via the cached refresh token when possible, otherwise
/// by running `aws sso login` and approving it in the hidden browser.
@MainActor
@Observable
final class AWSSSOConnector: Connector {
    static let type = "aws-sso"
    static let displayName = "AWS SSO"
    static let enabledByDefault = true

    /// The AWS access portal's device-approval pages.
    static let approvals = ApprovalRules(
        hosts: ["amazonaws.com", "awsapps.com", "aws.amazon.com", "signin.aws"],
        buttons: "^(confirm and continue|allow access|allow|approve|confirm)$",
        done: "request approved|you can close this|access granted"
    )

    enum State: Equatable {
        case unknown
        case noSession
        case valid(until: Date)
        case expired
        case refreshing
        case failed(String)
    }

    var config: ConnectorConfig { didSet { context.store.save(config) } }
    private(set) var state: State = .unknown
    @ObservationIgnored private let context: ConnectorContext
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private let log = AppLog("sso")

    init(config: ConnectorConfig, context: ConnectorContext) {
        self.config = config
        self.context = context
    }

    // MARK: Settings

    var autoRefresh: Bool {
        get { config.bool("autoRefresh", default: true) }
        set { config.set("autoRefresh", newValue) }
    }
    /// sso-session name in ~/.aws/config; empty uses the first one.
    var sessionName: String {
        get { config.string("session") }
        set { config.set("session", newValue) }
    }
    var leadMinutes: Int {
        get { config.int("leadMinutes", default: 10) }
        set { config.set("leadMinutes", newValue) }
    }

    var session: SSOSession? {
        let all = AWSConfig.ssoSessions()
        return all.first(where: { $0.name == sessionName }) ?? all.first
    }

    // MARK: Connector

    let title = "SSO"
    let symbol = "key.fill"

    var status: ConnectorStatus {
        switch state {
        case .unknown: return .init(health: .idle, summary: "Checking…")
        case .noSession: return .init(health: .idle, summary: "No sso-session in ~/.aws/config")
        case .valid(let until): return .init(health: .ok, summary: "Valid · \(Self.remaining(until)) left")
        case .expired: return .init(health: .attention, summary: "Expired")
        case .refreshing:
            let who = context.browser.waitingProvider.map { "\($0) " } ?? ""
            return .init(health: .busy, summary: context.browser.needsUser ? "Waiting for \(who)sign-in…" : "Refreshing…")
        case .failed(let msg): return .init(health: .attention, summary: msg)
        }
    }

    var actions: [ConnectorAction] {
        [ConnectorAction(title: "Refresh", enabled: state != .refreshing) { [weak self] in await self?.refresh() }]
    }

    var settingsTabs: [SettingsTab] {
        [SettingsTab("SSO", height: 360) { AWSSSOSettings(connector: self, context: context) }]
    }

    var signInPage: SignInPage? {
        guard let url = session.flatMap({ URL(string: $0.startURL) }) else { return nil }
        // Back on the portal: either already signed in, or just came back from the provider.
        return SignInPage(url: url) { $0.host?.hasSuffix(".awsapps.com") == true && $0.path.hasPrefix("/start") }
    }

    func tick(afterWake: Bool) {
        guard state != .refreshing else { return }
        read()
        if autoRefresh, !context.isQuiet, needsRefresh, (retryAfter ?? .distantPast) < Date() {
            log.info("auto refresh: \(status.summary)")
            Task { await refresh() }
        }
    }

    static func remaining(_ date: Date) -> String {
        let mins = max(0, Int(date.timeIntervalSinceNow / 60))
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    }

    // MARK: Refresh

    private var needsRefresh: Bool {
        switch state {
        case .expired, .unknown: return true
        case .valid(let until): return until.timeIntervalSinceNow < Double(leadMinutes * 60)
        default: return false
        }
    }

    private func read() {
        guard let session else { state = .noSession; return }
        if case .failed = state, retryAfter.map({ $0 > Date() }) == true { return }
        guard let token = SSOCache.token(for: session.name) else { state = .expired; return }
        state = token.expiresAt > Date() ? .valid(until: token.expiresAt) : .expired
    }

    func refresh() async {
        guard let session else { state = .noSession; return }
        guard state != .refreshing else { return }
        state = .refreshing
        do {
            try await refresh(session)
            retryAfter = nil
            state = .unknown
            read()
        } catch {
            log.error("sso refresh failed: \(error.localizedDescription)")
            retryAfter = Date().addingTimeInterval(5 * 60)
            state = .failed(error.localizedDescription)
            context.notify("SSO refresh failed", error.localizedDescription)
        }
    }

    private func refresh(_ session: SSOSession) async throws {
        guard let aws = Shell.find("aws") else {
            log.error("aws not found in \(Shell.searchPath)")
            throw AppError("AWS CLI not found")
        }
        let before = SSOCache.token(for: session.name)?.expiresAt

        // The CLI refreshes the access token itself once it is close to expiring.
        if let profile = AWSConfig.profile(using: session.name) {
            let r = await Shell.run(aws, ["configure", "export-credentials", "--profile", profile, "--format", "process"], timeout: 45)
            if r.status == 0, let after = SSOCache.token(for: session.name)?.expiresAt,
               after > (before ?? .distantPast), after.timeIntervalSinceNow > 300 {
                log.info("silent refresh ok")
                return
            }
        }
        log.info("silent refresh not possible, using browser approval")
        let provider = context.provider(for: config)
        try await CLILogin(browser: context.browser, name: "SSO", executable: aws,
                           arguments: ["sso", "login", "--sso-session", session.name, "--no-browser"]) { url in
            BrowserJob(url: url, providers: [provider], approvals: [Self.approvals], reopenIfFragmentLost: true)
        }.run()
        log.info("aws sso login ok")
    }
}
