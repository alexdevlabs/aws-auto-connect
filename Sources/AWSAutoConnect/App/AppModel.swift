import AppKit
import Observation
import UserNotifications

/// Owns the browser and the connectors, and runs the schedule.
@MainActor
@Observable
final class AppModel {
    /// A flow is stuck on a sign-in page.
    private(set) var signInNeeded = false
    /// Enabled connectors, in registry order.
    private(set) var connectors: [any Connector] = []

    @ObservationIgnored let browser = HeadlessBrowser()
    @ObservationIgnored let providers = ProviderRegistry()
    @ObservationIgnored let store: ConnectorStore
    @ObservationIgnored let context: ConnectorContext
    /// Called when the menu bar icon or tooltip may need redrawing.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var instances: [UUID: any Connector] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let log = AppLog("app")

    init() {
        Prefs.register()
        store = ConnectorStore(types: ConnectorRegistry.types)
        context = ConnectorContext(browser: browser, providers: providers, store: store) { _, _ in }
        context.notify = { [weak self] title, body in self?.post(title, body) }
        context.tunnelUp = { [weak self] in
            self?.connectors.contains { ($0 as? any TunnelConnector)?.isConnected == true } ?? false
        }
        context.showSignIn = { [weak self] in self?.showSignIn() }
        rebuild()
    }

    func start() {
        browser.onNeedsUserChange = { [weak self] needed in
            guard let self else { return }
            signInNeeded = needed
            if needed {
                let who = browser.waitingProvider ?? "Your sign-in provider"
                post("Sign-in needed", "\(who) wants you to sign in again. Click to open the sign-in window.")
            }
        }
        browser.onSignedIn = { [weak self] _ in
            self?.post("Signed in", "Sign-in saved. Refreshes will now run in the background.")
        }
        // --show-panel is a debug aid; don't ask for notification permission there.
        if Bundle.main.bundleIdentifier != nil, !CommandLine.arguments.contains("--show-panel") {
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
        observe()
        tick()
        connectors.forEach { $0.start() }
    }

    // MARK: Connectors

    func isEnabled(_ type: any Connector.Type) -> Bool {
        store.configs.contains { $0.type == type.type && $0.enabled }
    }

    func setEnabled(_ type: any Connector.Type, _ on: Bool) {
        guard var config = store.configs.first(where: { $0.type == type.type }) else { return }
        config.enabled = on
        store.save(config)
        rebuild()
        if on, let added = instances[config.id] {
            added.start()
            added.tick(afterWake: false)
        }
    }

    /// The first enabled connector of a type (the panel shows one per type).
    func connector<T: Connector>(_ type: T.Type) -> T? {
        connectors.lazy.compactMap { $0 as? T }.first
    }

    private func rebuild() {
        var list: [any Connector] = []
        for type in ConnectorRegistry.types {
            for config in store.configs where config.type == type.type && config.enabled {
                if instances[config.id] == nil { instances[config.id] = type.init(config: config, context: context) }
                list.append(instances[config.id]!)
            }
        }
        connectors = list
    }

    /// Stops every connector (including ones turned off while running), e.g. closes the VPN.
    func shutdown() async {
        timer?.invalidate()
        for connector in instances.values { await connector.stop() }
    }

    // MARK: Status

    var health: ConnectorStatus.Health {
        if signInNeeded { return .attention }
        return connectors.map(\.status.health).max() ?? .idle
    }

    var tooltip: String {
        connectors.map { "\($0.title): \($0.status.summary)" }.joined(separator: "\n")
    }

    /// Calls `onChange` whenever something the icon shows changes.
    private func observe() {
        withObservationTracking {
            _ = health
            _ = tooltip
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.onChange?()
                self?.observe()
            }
        }
    }

    // MARK: Schedule

    func tick(afterWake: Bool = false) {
        for c in connectors { c.tick(afterWake: afterWake) }
    }

    // MARK: Actions

    func showSignIn() {
        if signInNeeded {
            browser.reveal()
            return
        }
        let provider = providers.provider(id: Prefs.signInProvider)
        if let page = connectors.lazy.compactMap(\.signInPage).first {
            browser.showSignIn(page.url, providers: [provider], finished: page.finished)
        } else {
            browser.showSignIn(provider.signInURL ?? IdentityProvider.google.signInURL!, providers: [provider], finished: nil)
        }
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
}
