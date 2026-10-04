import XCTest
@testable import AWSAutoConnect

@MainActor
final class ConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "aws-autoconnect-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testMigratesOldSettings() throws {
        defaults.set(false, forKey: "autoRefreshSSO")
        defaults.set("work", forKey: "ssoSession")
        defaults.set(20, forKey: "refreshLeadMinutes")
        defaults.set("Corp VPN", forKey: "vpnProfile")
        defaults.set(true, forKey: "vpnReconnect")
        defaults.set(true, forKey: "dnsAllowlistEnabled")
        defaults.set("corp.example.com\nexample.net", forKey: "dnsAllowlist")

        let store = ConnectorStore(defaults: defaults, types: ConnectorRegistry.types)
        let sso = try XCTUnwrap(store.configs.first { $0.type == "aws-sso" })
        XCTAssertTrue(sso.enabled)
        XCTAssertFalse(sso.bool("autoRefresh", default: true))
        XCTAssertEqual(sso.string("session"), "work")
        XCTAssertEqual(sso.int("leadMinutes", default: 10), 20)

        let vpn = try XCTUnwrap(store.configs.first { $0.type == "aws-vpn" })
        XCTAssertEqual(vpn.string("profile"), "Corp VPN")
        XCTAssertTrue(vpn.bool("reconnect", default: false))
        XCTAssertFalse(vpn.bool("connectAtLaunch", default: false))
        XCTAssertTrue(vpn.bool("allowlistOn", default: false))
        XCTAssertEqual(vpn.string("allowlist"), "corp.example.com\nexample.net")

        // Types without old settings are added, off unless they say otherwise.
        let grafana = try XCTUnwrap(store.configs.first { $0.type == "grafana" })
        XCTAssertFalse(grafana.enabled)

        // An unreadable list starts over from the old keys.
        defaults.set(Data("garbage".utf8), forKey: ConnectorStore.key)
        let recovered = ConnectorStore(defaults: defaults, types: ConnectorRegistry.types)
        XCTAssertEqual(recovered.configs.first { $0.type == "aws-sso" }?.string("session"), "work")
    }

    func testSavesAndReloads() throws {
        let store = ConnectorStore(defaults: defaults, types: ConnectorRegistry.types)
        var grafana = try XCTUnwrap(store.configs.first { $0.type == "grafana" })
        grafana.enabled = true
        grafana.set("context", "prod")
        store.save(grafana)

        let again = ConnectorStore(defaults: defaults, types: ConnectorRegistry.types)
        XCTAssertEqual(again.configs.count, ConnectorRegistry.types.count)
        XCTAssertEqual(again.configs.first { $0.type == "grafana" }, grafana)
    }

    func testProvidersFromFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("providers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("""
        {"id": "okta", "name": "Okta", "hosts": ["okta.com"], "needsUser": ["input[type=password]"],
         "otherPagesNeedUser": true}
        """.utf8).write(to: folder.appendingPathComponent("okta.json"))
        try Data(#"{"id": "google", "name": "Google (custom)", "hosts": ["accounts.google.com"], "needsUser": []}"#.utf8)
            .write(to: folder.appendingPathComponent("google.json"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("broken.json"))

        let registry = ProviderRegistry(folder: folder)
        XCTAssertEqual(registry.provider(id: "okta").name, "Okta")
        XCTAssertTrue(registry.provider(id: "okta").matches(host: "mycorp.okta.com"))
        XCTAssertFalse(registry.provider(id: "okta").matches(host: "notokta.com"))
        XCTAssertEqual(registry.provider(id: "google").name, "Google (custom)", "a file overrides a built-in")
        XCTAssertEqual(registry.provider(id: "unknown").id, "google", "unknown ids fall back to the default")
        XCTAssertEqual(registry.all.count, 3)
    }
}
