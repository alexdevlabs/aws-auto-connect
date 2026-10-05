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
