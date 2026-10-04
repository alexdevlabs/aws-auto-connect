import Foundation

/// UserDefaults keys shared by the scheduler and the Settings window (@AppStorage).
enum Prefs {
    enum Key: String {
        case autoRefreshSSO, ssoSession, refreshLeadMinutes, notifications
        case vpnProfile, vpnConnectAtLaunch, vpnReconnect
        case quietEnabled, quietFrom, quietTo, quietWeekends
        case dnsAllowlistEnabled, dnsAllowlist
    }

    private static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            Key.autoRefreshSSO.rawValue: true,
            Key.ssoSession.rawValue: "",
            Key.refreshLeadMinutes.rawValue: 10,
            Key.notifications.rawValue: true,
            Key.vpnProfile.rawValue: "",
            Key.vpnConnectAtLaunch.rawValue: false,
            Key.vpnReconnect.rawValue: false,
            Key.quietEnabled.rawValue: false,
            Key.quietFrom.rawValue: 19,
            Key.quietTo.rawValue: 8,
            Key.quietWeekends.rawValue: false,
            Key.dnsAllowlistEnabled.rawValue: false,
            Key.dnsAllowlist.rawValue: "",
        ])
    }

    static var autoRefreshSSO: Bool { d.bool(forKey: Key.autoRefreshSSO.rawValue) }
    static var ssoSession: String { d.string(forKey: Key.ssoSession.rawValue) ?? "" }
    static var refreshLeadMinutes: Int { d.integer(forKey: Key.refreshLeadMinutes.rawValue) }
    static var notifications: Bool { d.bool(forKey: Key.notifications.rawValue) }
    static var vpnProfile: String { d.string(forKey: Key.vpnProfile.rawValue) ?? "" }
    static var vpnConnectAtLaunch: Bool { d.bool(forKey: Key.vpnConnectAtLaunch.rawValue) }
    static var vpnReconnect: Bool { d.bool(forKey: Key.vpnReconnect.rawValue) }
    static var dnsAllowlistEnabled: Bool { d.bool(forKey: Key.dnsAllowlistEnabled.rawValue) }
    /// Newline-separated domains.
    static var dnsAllowlist: [String] {
        (d.string(forKey: Key.dnsAllowlist.rawValue) ?? "").split(separator: "\n").map(String.init)
    }

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
