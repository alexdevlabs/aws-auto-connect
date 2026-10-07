import XCTest
@testable import AWSAutoConnect

final class ParsingTests: XCTestCase {
    @MainActor
    func testVPNChallenge() throws {
        let line = "AUTH_FAILED,CRV1:R:instance-1/abc/def:b'Tj9B':https://portal.sso.eu-central-1.amazonaws.com/saml?x=1"
        let (sid, url) = try XCTUnwrap(AWSVPNConnector.parseChallenge(line))
        XCTAssertEqual(sid, "instance-1/abc/def")
        XCTAssertEqual(url.host, "portal.sso.eu-central-1.amazonaws.com")
        XCTAssertNil(AWSVPNConnector.parseChallenge("AUTH_FAILED"))
    }

    func testFormPost() {
        let body = "RelayState=x&SAMLResponse=PHNhbWw%2BCg%3D%3D+more"
        XCTAssertEqual(FormPostListener.formValue("SAMLResponse", in: body), "PHNhbWw+Cg== more")
        XCTAssertNil(FormPostListener.formValue("Missing", in: body))

        let request = Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        XCTAssertEqual(FormPostListener.completeBody(request), Data("hello".utf8))
        XCTAssertNil(FormPostListener.completeBody(Data("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\nhello".utf8)))
    }

    func testAWSConfig() {
        let text = """
        [default]
        sso_session = work
        # comment
        [sso-session work]
        sso_start_url = https://example.awsapps.com/start
        sso_region = eu-central-1

        [profile dev]
        sso_session = other
        [sso-session broken]
        sso_region = us-east-1
        """
        let sections = AWSConfig.sections(in: text)
        let sessions = AWSConfig.ssoSessions(sections)
        XCTAssertEqual(sessions, [SSOSession(name: "work", startURL: "https://example.awsapps.com/start", region: "eu-central-1")])
        XCTAssertEqual(AWSConfig.profile(using: "work", in: sections), "default")
        XCTAssertEqual(AWSConfig.profile(using: "other", in: sections), "dev")
        XCTAssertNil(AWSConfig.profile(using: "none", in: sections))
    }

    func testSSOCacheDates() {
        XCTAssertNotNil(SSOCache.parseDate("2026-10-04T08:11:07Z"))
        XCTAssertNotNil(SSOCache.parseDate("2026-10-04T08:11:07.123Z"))
        XCTAssertNotNil(SSOCache.parseDate("2026-10-04T08:11:07UTC"))
        XCTAssertNil(SSOCache.parseDate("yesterday"))
    }

    @MainActor
    func testParentDomain() {
        XCTAssertEqual(VPNDomains.parent(of: "api.svc.corp.com"), "svc.corp.com")
        XCTAssertNil(VPNDomains.parent(of: "corp.com"))
    }

    @MainActor
    func testSubdomainWildcards() {
        let names = ["api.svc.corp.com", "web.svc.corp.com", "corp.com", "db.eu.internal.corp.com",
                     "x.eu.internal.corp.com", "Grafana.Tools.Example.net"]
        XCTAssertEqual(VPNDomains.subdomainWildcards(for: names),
                       ["corp.com", "tools.example.net"])
        // corp.com covers svc.corp.com and eu.internal.corp.com, so only the roots are left.
        XCTAssertEqual(VPNDomains.subdomainWildcards(for: ["api.svc.corp.com", "db.eu.internal.corp.com"]),
                       ["eu.internal.corp.com", "svc.corp.com"])
        XCTAssertEqual(VPNDomains.subdomainWildcards(for: []), [])
    }

    @MainActor
    func testDisallow() {
        let list = ["corp.example", "git.other.example", "vault.other.example"]
        // A name allowed through its parent takes the parent out.
        XCTAssertEqual(VPNDomains.allowlist(list, without: ["api.svc.corp.example"]), ["git.other.example", "vault.other.example"])
        XCTAssertEqual(VPNDomains.allowlist(list, without: ["GIT.other.example", "nothing.example"]),
                       ["corp.example", "vault.other.example"])
    }

    @MainActor
    func testDomainGroups() {
        XCTAssertEqual(VPNDomains.group(of: "grafana.tools.corp.example"), "corp.example")
        XCTAssertEqual(VPNDomains.group(of: "Git.Corp.Example"), "corp.example")
        XCTAssertEqual(VPNDomains.group(of: "corp.example"), "corp.example")
        XCTAssertEqual(VPNDomains.group(of: "localhost"), "localhost")
        // Shared domains group by the name's parent, never *.amazonaws.com or *.co.uk.
        XCTAssertEqual(VPNDomains.group(of: "db.cluster-c1.eu-west-1.rds.amazonaws.com"),
                       "cluster-c1.eu-west-1.rds.amazonaws.com")
        XCTAssertEqual(VPNDomains.group(of: "api.corp.co.uk"), "corp.co.uk")
        XCTAssertEqual(VPNDomains.group(of: "corp.co.uk"), "corp.co.uk")
    }

    func testImportable() {
        let pasted = """
        # work
        git.corp.example
        *.Svc.Corp.Example., wiki.corp.example  wiki.corp.example
        localhost   not a host!   a..b   .docs.example
        """
        XCTAssertEqual(VPNDomains.importable(pasted),
                       ["git.corp.example", "svc.corp.example", "wiki.corp.example", "docs.example"])
        XCTAssertNil(VPNDomains.normalized("localhost"))
        XCTAssertEqual(VPNDomains.normalized(" *.Foo.com. "), "foo.com")
        // A parent replaces the names it covers, and covered names aren't added.
        XCTAssertEqual(VPNDomains.allowlist(["a.corp.example", "x.org"], adding: ["corp.example", "b.corp.example", "y.org"]),
                       ["corp.example", "x.org", "y.org"])
    }

    func testStatusSummary() {
        func row(_ short: String, _ health: ConnectorStatus.Health, _ summary: String, tunnel: Bool = false) -> StatusSummary.Row {
            .init(name: "AWS \(short)", short: short, status: .init(health: health, summary: summary), isTunnel: tunnel)
        }
        let sso = row("SSO", .ok, "Valid · 2h left")
        XCTAssertNil(StatusSummary.make([], signInProvider: nil))
        XCTAssertEqual(StatusSummary.make([sso, row("VPN", .ok, "Connected", tunnel: true)], signInProvider: nil),
                       .init(health: .ok, title: "All connected"))
        XCTAssertEqual(StatusSummary.make([sso, row("VPN", .idle, "Disconnected", tunnel: true)], signInProvider: nil),
                       .init(health: .idle, title: "VPN off"))
        XCTAssertEqual(StatusSummary.make([sso, row("VPN", .busy, "Connecting…", tunnel: true)], signInProvider: nil),
                       .init(health: .busy, title: "Connecting…"))
        // Needs you beats working, and points at the connector's first action.
        XCTAssertEqual(StatusSummary.make([row("SSO", .busy, "Refreshing…"), row("VPN", .attention, "Helper is not installed", tunnel: true)],
                                          signInProvider: nil),
                       .init(health: .attention, title: "Helper is not installed", detail: "AWS VPN", fix: .action(1)))
        XCTAssertEqual(StatusSummary.make([sso], signInProvider: "Google")?.fix, .signIn)
        // A notice beats "All connected" and "VPN off", and offers its own action.
        var vpn = row("VPN", .ok, "Connected", tunnel: true)
        vpn.notice = "Helper update available"
        XCTAssertEqual(StatusSummary.make([sso, vpn], signInProvider: nil),
                       .init(health: .busy, title: "Helper update available", detail: "AWS VPN", fix: .notice(1)))
    }

    func testGrafanaCheck() {
        XCTAssertEqual(GrafanaConnector.classify(status: 0, output: "{}"), .ok)
        XCTAssertEqual(GrafanaConnector.classify(status: 1, output: "Error: request failed: 401 Unauthorized"), .signedOut)
        XCTAssertEqual(GrafanaConnector.classify(status: 1, output: "the access token has expired"), .signedOut)
        XCTAssertEqual(GrafanaConnector.classify(status: 1, output: "dial tcp: lookup myorg.grafana.net: no such host"), .error)
        XCTAssertEqual(GrafanaConnector.errorSummary(#"{"error":{"summary":"Invalid configuration","exitCode":1}}"#), "Invalid configuration")
        XCTAssertNil(GrafanaConnector.errorSummary("plain text"))
    }

    @MainActor
    func testPageResults() {
        XCTAssertEqual(HeadlessBrowser.parse("login:Google"), .login(provider: "Google"))
        XCTAssertEqual(HeadlessBrowser.parse("clicked:Allow access"), .clicked)
        XCTAssertEqual(HeadlessBrowser.parse("done"), .done)
        XCTAssertEqual(HeadlessBrowser.parse("wait"), .wait)
    }
}

final class ShellPathTests: XCTestCase {
    func testParsesPathBetweenMarkers() {
        let m = Shell.pathMarker
        let out = "Welcome!\n\(m)/Users/me/.local/share/mise/installs/aws-cli/2.17/bin:/usr/bin\(m)\nbye"
        XCTAssertEqual(Shell.parseShellPath(out), ["/Users/me/.local/share/mise/installs/aws-cli/2.17/bin", "/usr/bin"])
        XCTAssertEqual(Shell.parseShellPath("no markers"), [])
        XCTAssertEqual(Shell.parseShellPath("\(m)/usr/bin"), [])
    }

    func testMergeKeepsOrderDropsDuplicatesAndRelative() {
        XCTAssertEqual(Shell.merge(["/a", ".", "/b"], ["/b", "/c", ""]), "/a:/b:/c")
        XCTAssertEqual(Shell.merge([], ["/usr/bin"]), "/usr/bin")
    }

    func testOutputDoesNotWaitForBackgroundChildren() {
        // Like an rc file starting an agent that keeps stdout open after the shell exits.
        let start = Date()
        let out = Shell.output(of: "/bin/sh", ["-c", "sleep 30 & printf hello"], timeout: 5)
        XCTAssertEqual(out, "hello")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testOutputGivesUpOnAHangingShell() {
        let start = Date()
        XCTAssertEqual(Shell.output(of: "/bin/sh", ["-c", "printf partial; sleep 30"], timeout: 0.5), "partial")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testLoginShellPathFindsSystemDirs() {
        XCTAssertTrue(Shell.loginShellPath().contains("/usr/bin"))
    }

    func testFallbackCoversVersionManagers() {
        XCTAssertTrue(Shell.fallbackPath.contains { $0.hasSuffix("/.local/share/mise/shims") })
        XCTAssertTrue(Shell.fallbackPath.contains("/opt/homebrew/bin"))
    }
}

final class DevBuildTests: XCTestCase {
    /// Only `make dev` passes -DDEV; normal and release builds (and so the tests) must not.
    func testNormalBuildsAreNotDev() {
        XCTAssertFalse(DevBuild.isDev)
    }
}

final class AppInstallerTests: XCTestCase {
    func testHomebrewPath() {
        let cellar = URL(fileURLWithPath: "/opt/homebrew/Cellar/aws-autoconnect/1.0.0/AWS AutoConnect.app")
        XCTAssertEqual(AppInstaller.homebrewApp(for: cellar)?.path, "/opt/homebrew/opt/aws-autoconnect/AWS AutoConnect.app")
        XCTAssertNil(AppInstaller.homebrewApp(for: URL(fileURLWithPath: "/Users/me/Applications/AWS AutoConnect.app")))
        XCTAssertNil(AppInstaller.homebrewApp(for: URL(fileURLWithPath: "/opt/homebrew/Cellar/other/1.0/AWS AutoConnect.app")))
    }
}

@MainActor
final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("v1.10.0", than: "1.9.2"))
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.99.99"))
        XCTAssertFalse(Updater.isNewer("v1.0.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.1.0-beta", than: "1.0.0"))
    }

    func testDecodesGitHubRelease() throws {
        let json = #"{"tag_name":"v1.2.0","html_url":"https://github.com/alexdevlabs/aws-auto-connect/releases/tag/v1.2.0","name":"v1.2.0","draft":false}"#
        let release = try JSONDecoder().decode(Updater.Release.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.htmlURL.lastPathComponent, "v1.2.0")
    }
}

@MainActor
final class UpdaterLinkTests: XCTestCase {
    func testNotesOnlyOpenThisRepo() throws {
        let decode = { (url: String) in
            try JSONDecoder().decode(Updater.Release.self, from: Data(#"{"tag_name":"v2.0.0","html_url":"\#(url)"}"#.utf8))
        }
        let good = try decode("https://github.com/alexdevlabs/aws-auto-connect/releases/tag/v2.0.0")
        XCTAssertEqual(Updater.notesURL(good), good.htmlURL)
        let list = URL(string: "https://github.com/alexdevlabs/aws-auto-connect/releases")!
        XCTAssertEqual(Updater.notesURL(try decode("file:///etc/passwd")), list)
        XCTAssertEqual(Updater.notesURL(try decode("https://evil.example/alexdevlabs/aws-auto-connect/releases/x")), list)
        XCTAssertEqual(Updater.notesURL(try decode("https://github.com/someone/else/releases/tag/v2")), list)
    }

    func testHeadInstallDetected() {
        XCTAssertTrue(AppInstaller.isHead(URL(fileURLWithPath: "/opt/homebrew/Cellar/aws-autoconnect/HEAD-abc1234/AWS AutoConnect.app")))
        XCTAssertFalse(AppInstaller.isHead(URL(fileURLWithPath: "/opt/homebrew/Cellar/aws-autoconnect/1.0.0/AWS AutoConnect.app")))
    }
}

final class AppPlacementTests: XCTestCase {
    private let apps = URL(fileURLWithPath: "/Applications/AWS AutoConnect.app")

    func testTargetPrefersApplications() {
        XCTAssertEqual(AppInstaller.target(applicationsWritable: true), apps)
        XCTAssertEqual(AppInstaller.target(applicationsWritable: false), AppInstaller.home)
    }

    func testOnlyOurOldCopyMoves() {
        let home = AppInstaller.home
        XCTAssertTrue(AppInstaller.shouldMove(running: home, fingerprint: "a", recorded: "a", target: apps))
        // make install / dragged copy: not the one we recorded.
        XCTAssertFalse(AppInstaller.shouldMove(running: home, fingerprint: "a", recorded: "b", target: apps))
        XCTAssertFalse(AppInstaller.shouldMove(running: home, fingerprint: nil, recorded: nil, target: apps))
        // Already in /Applications, or ~/Applications is the place (no write access to /Applications).
        XCTAssertFalse(AppInstaller.shouldMove(running: apps, fingerprint: "a", recorded: "a", target: apps))
        XCTAssertFalse(AppInstaller.shouldMove(running: home, fingerprint: "a", recorded: "a", target: home))
    }
}

final class PrefsMigrationTests: XCTestCase {
    func testCopiesOldSettingsOnce() throws {
        let new = "aac-test-new-\(UUID().uuidString)", old = "aac-test-old-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: new))
        defer { d.removePersistentDomain(forName: new); d.removePersistentDomain(forName: old) }
        d.setPersistentDomain(["vpnProfile": "Work", "signInProvider": "okta"], forName: old)
        d.set("google", forKey: "signInProvider")  // already set here: kept

        Prefs.migrateOldDomain(into: d, from: old)
        XCTAssertEqual(d.string(forKey: "vpnProfile"), "Work")
        XCTAssertEqual(d.string(forKey: "signInProvider"), "google")

        d.removeObject(forKey: "vpnProfile")
        Prefs.migrateOldDomain(into: d, from: old)  // second run does nothing
        XCTAssertNil(d.string(forKey: "vpnProfile"))
    }
}

@MainActor
final class VPNSetupTests: XCTestCase {
    func testOffersHelperInstall() {
        let ready = AWSVPNConnector.setup(hasProfiles: true)
        XCTAssertEqual(ready.summary, "Helper is not installed")
        XCTAssertEqual(ready.action, "Install Helper…")
        XCTAssertTrue(ready.enabled)
        let none = AWSVPNConnector.setup(hasProfiles: false)
        XCTAssertFalse(none.enabled)
        XCTAssertEqual(none.summary, "Add a profile in AWS VPN Client first")
    }
}
