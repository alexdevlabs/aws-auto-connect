import Foundation

/// One configured connector. The list allows several of a type (e.g. two AWS organisations); the panel
/// currently shows the first enabled one of each.
struct ConnectorConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var type: String
    var enabled: Bool
    /// Sign-in provider id; nil follows the app default.
    var provider: String?
    /// Connector-specific settings.
    var settings: [String: String]

    init(id: UUID = UUID(), type: String, enabled: Bool = true, provider: String? = nil, settings: [String: String] = [:]) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.provider = provider
        self.settings = settings
    }

    func string(_ key: String, default value: String = "") -> String { settings[key] ?? value }
    func bool(_ key: String, default value: Bool) -> Bool { settings[key].map { $0 == "true" } ?? value }
    func int(_ key: String, default value: Int) -> Int { settings[key].flatMap(Int.init) ?? value }

    mutating func set(_ key: String, _ value: String) { settings[key] = value }
    mutating func set(_ key: String, _ value: Bool) { settings[key] = value ? "true" : "false" }
    mutating func set(_ key: String, _ value: Int) { settings[key] = String(value) }
}

/// The saved connector list (UserDefaults, as JSON).
@MainActor
final class ConnectorStore {
    static let key = "connectors"
    private let defaults: UserDefaults
    private(set) var configs: [ConnectorConfig]

    init(defaults: UserDefaults = .standard, types: [any Connector.Type]) {
        self.defaults = defaults
        let log = AppLog("settings")
        if let data = defaults.data(forKey: Self.key) {
            do {
                configs = try JSONDecoder().decode([ConnectorConfig].self, from: data)
            } catch {
                log.error("saved connectors unreadable, starting over from older settings: \(error.localizedDescription)")
                configs = Self.migrate(defaults)
            }
        } else {
            log.info("no saved connectors, setting up from older settings")
            configs = Self.migrate(defaults)
        }
        // Types added in a later version get a (possibly disabled) entry, so General can list them.
        for t in types where !configs.contains(where: { $0.type == t.type }) {
            configs.append(ConnectorConfig(type: t.type, enabled: t.enabledByDefault))
        }
        write()
    }

    func save(_ config: ConnectorConfig) {
        if let i = configs.firstIndex(where: { $0.id == config.id }) {
            guard configs[i] != config else { return }
            configs[i] = config
        } else {
            configs.append(config)
        }
        write()
    }

    private func write() {
        if let data = try? JSONEncoder().encode(configs) { defaults.set(data, forKey: Self.key) }
    }

    /// Versions before connectors kept the AWS settings as separate UserDefaults keys. They're left in
    /// place, so this can run again if the connector list is ever lost.
    static func migrate(_ d: UserDefaults) -> [ConnectorConfig] {
        func has(_ key: String) -> Bool { d.object(forKey: key) != nil }
        var sso = ConnectorConfig(type: AWSSSOConnector.type)
        if has("autoRefreshSSO") { sso.set("autoRefresh", d.bool(forKey: "autoRefreshSSO")) }
        if let s = d.string(forKey: "ssoSession"), !s.isEmpty { sso.set("session", s) }
        if has("refreshLeadMinutes") { sso.set("leadMinutes", d.integer(forKey: "refreshLeadMinutes")) }

        var vpn = ConnectorConfig(type: AWSVPNConnector.type)
        if let p = d.string(forKey: "vpnProfile"), !p.isEmpty { vpn.set("profile", p) }
        if has("vpnConnectAtLaunch") { vpn.set("connectAtLaunch", d.bool(forKey: "vpnConnectAtLaunch")) }
        if has("vpnReconnect") { vpn.set("reconnect", d.bool(forKey: "vpnReconnect")) }
        if has("dnsAllowlistEnabled") { vpn.set("allowlistOn", d.bool(forKey: "dnsAllowlistEnabled")) }
        if let list = d.string(forKey: "dnsAllowlist"), !list.isEmpty { vpn.set("allowlist", list) }
        return [sso, vpn]
    }
}
