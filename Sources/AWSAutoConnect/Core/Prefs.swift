import Foundation

/// App-wide UserDefaults keys (@AppStorage in General). Connector settings live in `ConnectorStore`.
enum Prefs {
    enum Key: String {
        case notifications, signInProvider
        case quietEnabled, quietFrom, quietTo, quietWeekends
        case checkForUpdates, autoInstallUpdates
    }

    private static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            Key.notifications.rawValue: true,
            Key.signInProvider.rawValue: ProviderRegistry.defaultID,
            Key.quietEnabled.rawValue: false,
            Key.quietFrom.rawValue: 19,
            Key.quietTo.rawValue: 8,
            Key.quietWeekends.rawValue: false,
            Key.checkForUpdates.rawValue: true,
            Key.autoInstallUpdates.rawValue: false,
        ])
    }

    /// Builds before 1.0 used the bundle ID `local.aws-autoconnect`; carry their settings over once.
    static func migrateOldDomain() {
        guard d.object(forKey: "migratedOldDomain") == nil else { return }
        for (k, v) in d.persistentDomain(forName: "local.aws-autoconnect") ?? [:] where d.object(forKey: k) == nil {
            d.set(v, forKey: k)
        }
        d.set(true, forKey: "migratedOldDomain")
    }

    static var notifications: Bool { d.bool(forKey: Key.notifications.rawValue) }
    /// Default sign-in provider id for connectors that don't pick their own.
    static var signInProvider: String { d.string(forKey: Key.signInProvider.rawValue) ?? ProviderRegistry.defaultID }

    static var checkForUpdates: Bool { d.bool(forKey: Key.checkForUpdates.rawValue) }
    /// Install updates on their own while no tunnel is up (Homebrew installs only).
    static var autoInstallUpdates: Bool { d.bool(forKey: Key.autoInstallUpdates.rawValue) }

    /// Quiet hours pause automatic refreshes and reconnects; manual actions still work.
    static func isQuiet(at date: Date = Date()) -> Bool {
        let cal = Calendar.current
        if d.bool(forKey: Key.quietWeekends.rawValue), cal.isDateInWeekend(date) { return true }
        guard d.bool(forKey: Key.quietEnabled.rawValue) else { return false }
        let from = d.integer(forKey: Key.quietFrom.rawValue)
        let to = d.integer(forKey: Key.quietTo.rawValue)
        let hour = cal.component(.hour, from: date)
        if from == to { return false }
        return from < to ? (hour >= from && hour < to) : (hour >= from || hour < to)
    }
}
