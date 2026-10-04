import SwiftUI

/// Something the app keeps signed in or connected: an AWS SSO session, an AWS Client VPN tunnel, a Grafana
/// login. Each type lives in Connectors/<Name>/ and is listed in `ConnectorRegistry.types`.
///
/// Connectors are @Observable classes; the app reads `status`, `actions` and `settingsTabs` from SwiftUI,
/// so changes to their stored properties show up without extra plumbing.
@MainActor
protocol Connector: AnyObject {
    /// Stable id used in the saved settings, e.g. "aws-sso". Never change it once released.
    static var type: String { get }
    /// Shown in General ▸ Connectors.
    static var displayName: String { get }
    /// Whether a fresh install starts with this connector turned on.
    static var enabledByDefault: Bool { get }

    init(config: ConnectorConfig, context: ConnectorContext)

    var config: ConnectorConfig { get }
    /// Status tab row title, e.g. "SSO".
    var title: String { get }
    /// SF Symbol for the status row.
    var symbol: String { get }
    var status: ConnectorStatus { get }
    /// Buttons on the status row, in order.
    var actions: [ConnectorAction] { get }
    /// Tabs this connector adds to the panel, between Status and General.
    var settingsTabs: [SettingsTab] { get }
    /// A page that goes through the sign-in provider and back (e.g. the AWS access portal), used by
    /// "Sign in to …" so the provider's cookies end up in the hidden browser. Nil if there's none.
    var signInPage: SignInPage? { get }

    /// Called once after launch.
    func start()
    /// Called every minute and shortly after the Mac wakes.
    func tick(afterWake: Bool)
}

extension Connector {
    var signInPage: SignInPage? { nil }
    func start() {}
}

/// A connector that holds a tunnel; the app tells the others whether one is up.
@MainActor
protocol TunnelConnector: Connector {
    var isConnected: Bool { get }
}

struct SignInPage {
    let url: URL
    /// True once a loaded page shows you're signed in (the sign-in window then closes itself).
    let finished: (URL) -> Bool
}

struct ConnectorStatus: Equatable {
    enum Health: Int, Comparable {
        case idle, ok, busy, attention
        static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
    }

    var health: Health
    var summary: String
}

struct ConnectorAction: Identifiable {
    let title: String
    var enabled = true
    let run: @MainActor () async -> Void
    var id: String { title }
}

struct SettingsTab: Identifiable {
    let title: String
    /// Fixed height of the tab's content in the panel.
    let height: CGFloat
    let view: AnyView
    var id: String { title }

    init(_ title: String, height: CGFloat, @ViewBuilder _ view: () -> some View) {
        self.title = title
        self.height = height
        self.view = AnyView(view())
    }
}

/// What the app gives every connector.
@MainActor
final class ConnectorContext {
    let browser: HeadlessBrowser
    let providers: ProviderRegistry
    let store: ConnectorStore
    /// Posts a user notification (if enabled in General).
    var notify: (_ title: String, _ body: String) -> Void
    /// Set by the app: whether any tunnel connector is connected.
    var tunnelUp: () -> Bool = { false }
    /// Set by the app: opens the sign-in window (or the page a flow is waiting on).
    var showSignIn: () -> Void = {}

    init(browser: HeadlessBrowser, providers: ProviderRegistry, store: ConnectorStore,
         notify: @escaping (_ title: String, _ body: String) -> Void) {
        self.browser = browser
        self.providers = providers
        self.store = store
        self.notify = notify
    }

    /// Quiet hours: no automatic refreshes or reconnects.
    var isQuiet: Bool { Prefs.isQuiet() }

    /// The sign-in provider a connector should expect: its own choice, else the app default.
    func provider(for config: ConnectorConfig) -> IdentityProvider {
        providers.provider(id: config.provider ?? Prefs.signInProvider)
    }
}
