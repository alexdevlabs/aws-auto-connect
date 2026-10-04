import Foundation

/// App-wide UserDefaults keys (@AppStorage in General). Connector settings live in `ConnectorStore`.
enum Prefs {
    enum Key: String {
        case notifications, signInProvider
        case quietEnabled, quietFrom, quietTo, quietWeekends
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
        ])
    }

    static var notifications: Bool { d.bool(forKey: Key.notifications.rawValue) }
    /// Default sign-in provider id for connectors that don't pick their own.
    static var signInProvider: String { d.string(forKey: Key.signInProvider.rawValue) ?? ProviderRegistry.defaultID }

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
