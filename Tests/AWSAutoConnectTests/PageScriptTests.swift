import WebKit
import XCTest
@testable import AWSAutoConnect

/// Runs the hidden browser's page script against small stand-ins for real pages. A new provider should
/// come with tests like these (save the page's HTML, trim it to the parts the rules look at).
@MainActor
final class PageScriptTests: XCTestCase {
    private let google = IdentityProvider.google
    private let aws = AWSSSOConnector.approvals

    func testGoogleEmailPage() async throws {
        let r = try await run("<input type=email>", at: "https://accounts.google.com/v3/signin/identifier")
        XCTAssertEqual(r, "login:Google")
    }

    func testGoogleHiddenPasswordIsNotLogin() async throws {
        let html = "<input type=password aria-hidden=true><div data-identifier='a@b.com'>a@b.com</div>"
        let r = try await run(html, at: "https://accounts.google.com/v3/signin/accountchooser")
        XCTAssertEqual(r, "clicked:Google account", "one account in the picker is clicked")
    }

    func testGoogleSeveralAccounts() async throws {
        let html = "<div data-identifier='a@b.com'>a</div><div data-identifier='c@d.com'>c</div>"
        let r = try await run(html, at: "https://accounts.google.com/v3/signin/accountchooser")
        XCTAssertEqual(r, "login:Google")
    }

    func testGoogleSAMLPostPassesThrough() async throws {
        let r = try await run("<p>Redirecting…</p>", at: "https://accounts.google.com/o/saml2/idp?idpid=x")
        XCTAssertEqual(r, "wait")
    }

    func testGoogleTwoStepNeedsUser() async throws {
        let r = try await run("<h1>2-Step Verification</h1><p>Check your phone</p>",
                              at: "https://accounts.google.com/v3/signin/challenge/dp")
        XCTAssertEqual(r, "login:Google")
    }

    func testAWSApprovalButton() async throws {
        let html = "<button>Cancel</button><button>Allow access</button>"
        let r = try await run(html, at: "https://myorg.awsapps.com/start/#/device")
        XCTAssertEqual(r, "clicked:Allow access")
    }

    func testAWSDone() async throws {
        let r = try await run("<h1>Request approved</h1>", at: "https://myorg.awsapps.com/start/#/device")
        XCTAssertEqual(r, "done")
    }

    func testDisabledButtonIsNotClicked() async throws {
        let r = try await run("<button disabled>Allow access</button>", at: "https://myorg.awsapps.com/start/")
        XCTAssertEqual(r, "wait")
    }

    func testGenericFallbackOnUnknownProvider() async throws {
        let r = try await run("<form><input name=u><input type=password></form>", at: "https://login.example-idp.com/")
        XCTAssertEqual(r, "login:\(IdentityProvider.generic.name)")
        let none = try await run("<p>Loading</p>", at: "https://login.example-idp.com/")
        XCTAssertEqual(none, "wait")
    }

    func testServiceLoginButtonForProvider() async throws {
        let grafana = ApprovalRules(hosts: ["grafana.net"], buttons: "^(ok)$", done: nil)
        let html = "<a role=button>Sign in with GitHub</a><button>Sign in with Google</button>"
        let r = try await run(html, at: "https://myorg.grafana.net/login", approvals: [grafana])
        XCTAssertEqual(r, "clicked:Sign in with Google")
    }

    func testServiceLoginLinkForProvider() async throws {
        // Grafana Cloud's login page, after the session expired: the provider buttons are links.
        let html = """
        <h1>Welcome to Grafana Cloud</h1>
        <a href="login/google"><svg width="16" height="16"></svg><span>Sign in with Google</span></a>
        <a href="login/grafana_com"><span>Sign in with Grafana.com</span></a>
        """
        let r = try await run(html, at: "https://myorg.grafana.net/login", approvals: [GrafanaConnector.approvalRules(stackHost: "")])
        XCTAssertEqual(r, "clicked:Sign in with Google")
    }

    func testApprovalWordsOnPlainLinksAreNotClicked() async throws {
        let html = "<a href=\"/elsewhere\">Continue</a><a href=\"/x\">OK</a>"
        let r = try await run(html, at: "https://myorg.grafana.net/a/app", approvals: [GrafanaConnector.approvalRules(stackHost: "")])
        XCTAssertEqual(r, "wait")
    }

    func testCustomProviderRules() async throws {
        let okta = IdentityProvider(id: "okta", name: "Okta", hosts: ["okta.com"], signInURL: nil,
                                    needsUser: ["input[name=identifier]"], otherPagesNeedUser: false)
        let login = try await run("<input name=identifier>", at: "https://corp.okta.com/signin", providers: [okta])
        XCTAssertEqual(login, "login:Okta")
        let other = try await run("<p>Redirecting</p>", at: "https://corp.okta.com/app/sso/saml", providers: [okta])
        XCTAssertEqual(other, "wait")
    }

    // MARK: Helpers

    private func run(_ body: String, at url: String, providers: [IdentityProvider]? = nil,
                     approvals: [ApprovalRules]? = nil) async throws -> String {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 680))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        let base = try XCTUnwrap(URL(string: url))
        web.loadHTMLString("<html><body>\(body)</body></html>", baseURL: base)
        try await loaded.wait()
        let job = BrowserJob(url: base, providers: providers ?? [google], approvals: approvals ?? [aws])
        let result = try await web.evaluateJavaScript(HeadlessBrowser.script(for: job))
        return try XCTUnwrap(result as? String)
    }
}

@MainActor
private final class Loaded: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
