import XCTest
@testable import AWSAutoConnect

@MainActor
final class CLILoginTests: XCTestCase {
    func testPrefilledLinkOpensRightAway() {
        var opened: URL?
        let picker = LoginURLPicker { opened = $0 }
        picker.consume("Attempting to automatically open the SSO authorization page")
        picker.consume("  https://myorg.awsapps.com/start/#/device?user_code=ABCD-EFGH  ")
        XCTAssertEqual(opened?.absoluteString, "https://myorg.awsapps.com/start/#/device?user_code=ABCD-EFGH")
    }

    func testBaseURLPlusCode() async throws {
        var opened: URL?
        let picker = LoginURLPicker { opened = $0 }
        picker.consume("https://device.sso.eu-central-1.amazonaws.com/")
        picker.consume("ABCD-EFGH")
        XCTAssertNil(opened, "waits briefly for a pre-filled link")
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertEqual(opened?.absoluteString, "https://device.sso.eu-central-1.amazonaws.com/?user_code=ABCD-EFGH")
    }

    func testOpenedURLWins() {
        var opened: [URL] = []
        let picker = LoginURLPicker { opened.append($0) }
        picker.offer("https://myorg.grafana.net/cli/login?code=1")
        picker.consume("https://myorg.awsapps.com/start/#/device?user_code=ABCD-EFGH")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://myorg.grafana.net/cli/login?code=1"])
    }

    /// A CLI that calls `open <url>` (or $BROWSER) hands the URL to us instead of the default browser.
    func testOpenShimCatchesURL() async throws {
        let shim = try OpenShim()
        defer { shim.remove() }
        let env = shim.environment(Shell.environment)
        let r = await StreamingProcess("/bin/sh", ["-c", "open https://example.com/a && \"$BROWSER\" https://example.com/b && open /tmp"],
                                       environment: env).run(timeout: 10)
        XCTAssertEqual(r.status, 0)
        var urls: [String] = []
        for await url in shim.urls() {
            urls.append(url)
            if urls.count == 2 { break }
        }
        XCTAssertEqual(urls, ["https://example.com/a", "https://example.com/b"])
    }
}

final class ShellTests: XCTestCase {
    /// A command that can't start returns an error instead of waiting forever on its output pipe.
    func testMissingExecutableReturns() async {
        let r = await StreamingProcess("/nonexistent/tool", []).run(timeout: 5)
        XCTAssertEqual(r.status, -1)
        XCTAssertTrue(r.output.contains("couldn't start /nonexistent/tool"), r.output)
    }
}

@MainActor
final class BrowserTurnTests: XCTestCase {
    /// Flows take turns: a second one starts only after the first is done.
    func testExclusiveRunsOneAtATime() async {
        let browser = HeadlessBrowser()
        var events: [String] = []
        async let first: Void = browser.exclusive {
            events.append("first start")
            try? await Task.sleep(for: .milliseconds(200))
            events.append("first end")
        }
        try? await Task.sleep(for: .milliseconds(50))
        await browser.exclusive { events.append("second") }
        await first
        XCTAssertEqual(events, ["first start", "first end", "second"])
    }
}
