import AppKit
import Observation
import UserNotifications

/// Owns the browser, SSO refresh and VPN controller, and runs the schedule.
@MainActor
@Observable
final class AppModel {
    enum SSOState: Equatable {
        case unknown
        case noSession
        case valid(until: Date)
        case expired
        case refreshing
        case failed(String)
    }

    enum Health { case idle, ok, busy, attention }

    private(set) var sso: SSOState = .unknown { didSet { notify() } }
    /// A flow is stuck on a Google sign-in page.
    private(set) var signInNeeded = false
    @ObservationIgnored let browser = HeadlessBrowser()
    let vpn: VPNController
    let domains: VPNDomains

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var retryAfter: Date?
    @ObservationIgnored private let log = AppLog("app")

    init() {
        Prefs.register()
        vpn = VPNController(browser: browser)
        domains = VPNDomains()
    }

    func start() {
        vpn.onChange = { [weak self] in self?.notify() }
        vpn.beforeTunnel = { [weak self] in await self?.domains.sync() }
        browser.onNeedsUserChange = { [weak self] needed in
            guard let self else { return }
            signInNeeded = needed
            if needed { post("Sign-in needed", "Google wants you to sign in again. Click to open the sign-in window.") }
            notify()
        }
        browser.onSignedIn = { [weak self] _ in
            self?.post("Signed in", "Google sign-in saved. Refreshes will now run in the background.")
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give Wi-Fi a moment to come back before checking.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                self?.tick(afterWake: true)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        if Prefs.vpnConnectAtLaunch, !Prefs.isQuiet(), !VPNHelper.isTunnelRunning {
            Task { await vpn.connect() }
        }
    }

    // MARK: Status

    var session: SSOSession? {
        let all = AWSConfig.ssoSessions()
        return all.first(where: { $0.name == Prefs.ssoSession }) ?? all.first
    }

    var health: Health {
        if case .failed = vpn.state { return .attention }
        switch sso {
        case .failed, .expired: return .attention
        case .refreshing: return .busy
        default: break
        }
        if signInNeeded { return .attention }
        if vpn.isBusy { return .busy }
        if case .valid = sso { return .ok }
        if vpn.state == .connected { return .ok }
        return .idle
    }

    var ssoSummary: String {
        switch sso {
        case .unknown: return "Checking…"
        case .noSession: return "No sso-session in ~/.aws/config"
        case .valid(let until): return "Valid · \(Self.remaining(until)) left"
        case .expired: return "Expired"
        case .refreshing: return signInNeeded ? "Waiting for Google sign-in…" : "Refreshing…"
        case .failed(let msg): return msg
        }
    }

    static func remaining(_ date: Date) -> String {
        let mins = max(0, Int(date.timeIntervalSinceNow / 60))
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    }

    // MARK: Schedule

    func tick(afterWake: Bool = false) {
        let quiet = Prefs.isQuiet()

        if sso != .refreshing {
            readSSO()
            if Prefs.autoRefreshSSO, !quiet, needsRefresh, (retryAfter ?? .distantPast) < Date() {
                log.info("auto refresh: \(ssoSummary)")
                Task { await refreshSSO(manual: false) }
            }
        }

        domains.ingest()
        let dropped = vpn.checkTunnel()
        let shouldReconnect = Prefs.vpnReconnect && !quiet && vpn.wantsConnection && !vpn.isBusy
        if dropped || (afterWake && !VPNHelper.isTunnelRunning && vpn.wantsConnection) {
            if shouldReconnect {
                log.info("reconnecting VPN")
                Task { await vpn.connect() }
            } else if dropped {
                post("VPN disconnected", "The tunnel dropped. Reconnect from the menu bar.")
            }
        }
    }

    private var needsRefresh: Bool {
        switch sso {
        case .expired, .unknown: return true
        case .valid(let until): return until.timeIntervalSinceNow < Double(Prefs.refreshLeadMinutes * 60)
        default: return false
        }
    }

    private func readSSO() {
        guard let session else { sso = .noSession; return }
        if case .failed = sso, retryAfter.map({ $0 > Date() }) == true { return }
        guard let token = SSOCache.token(for: session.name) else { sso = .expired; return }
        sso = token.expiresAt > Date() ? .valid(until: token.expiresAt) : .expired
    }

    func refreshSSO(manual: Bool) async {
        guard let session else { sso = .noSession; return }
        guard sso != .refreshing else { return }
        sso = .refreshing
        do {
            try await SSORefresher(browser: browser).refresh(session)
            retryAfter = nil
            sso = .unknown
            readSSO()
        } catch {
            log.error("sso refresh failed: \(error.localizedDescription)")
            retryAfter = Date().addingTimeInterval(5 * 60)
            sso = .failed(error.localizedDescription)
            post("SSO refresh failed", error.localizedDescription)
        }
    }

    // MARK: Actions

    func showSignIn() {
        if signInNeeded {
            browser.reveal()
            return
        }
        let url = session.flatMap { URL(string: $0.startURL) } ?? URL(string: "https://accounts.google.com/")!
        browser.showSignIn(url)
    }

    func clearBrowserSession() async {
        await browser.clearSession()
    }

    func post(_ title: String, _ body: String) {
        guard Prefs.notifications, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func notify() { onChange?() }
}
