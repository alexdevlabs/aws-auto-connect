import AppKit
import WebKit

/// A hidden WebKit browser with a persistent cookie store. It holds the Google
/// session, clicks through the AWS approval and Google account-picker pages,
/// and only shows itself when Google asks you to sign in.
@MainActor
final class HeadlessBrowser: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private enum PageState: String { case wait, login, done, clicked }

    // Google refuses sign-in from browsers it doesn't recognise, so present as Safari.
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let log = AppLog("browser")
    private let webView: WKWebView
    private let window: NSWindow
    private var pollTask: Task<Void, Never>?
    /// Manual "Sign in to Google…": close the window once we're back on the AWS portal.
    private var manualSignIn = false
    private var sawGoogle = false
    /// SSO refresh and VPN sign-in take turns: each one's `stop()` would cut off the other's clicking.
    private var inUse = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// True while the window is up waiting for the user to sign in.
    private(set) var needsUser = false {
        didSet { if needsUser != oldValue { onNeedsUserChange?(needsUser) } }
    }
    /// Called when a page starts or stops needing the user (e.g. a Google sign-in form).
    var onNeedsUserChange: ((Bool) -> Void)?
    /// Called after a manual sign-in lands back on the AWS portal (true if Google was visited).
    var onSignedIn: ((Bool) -> Void)?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Keep timers and scripts running while the window is hidden.
        config.preferences.inactiveSchedulingPolicy = .none
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 680), configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.isInspectable = true  // Safari ▸ Develop menu can attach for debugging
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AWS AutoConnect – Sign in"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.delegate = self
    }

    /// Runs `body` with the browser to itself, after any flow already using it finishes.
    func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        if inUse { await withCheckedContinuation { waiting.append($0) } }
        inUse = true
        defer {
            if waiting.isEmpty { inUse = false } else { waiting.removeFirst().resume() }  // hand over directly
        }
        return try await body()
    }

    /// Loads `url` out of sight and keeps clicking known approval buttons until `stop()`.
    func automate(_ url: URL) {
        stop()
        log.info("automating \(url.host ?? "?")")
        webView.load(URLRequest(url: url))
        pollTask = Task { [weak self] in
            var loginStreak = 0
            var offPageStreak = 0
            var reopened = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self, !Task.isCancelled else { return }
                let state = await self.step()
                loginStreak = state == .login ? loginStreak + 1 : 0
                // When the portal session has expired, AWS signs in again via Google but then lands on the
                // portal's home page and forgets the approval page (its #/device?user_code=… fragment).
                // Go back to it.
                offPageStreak = state == .wait && self.lostPage(of: url) ? offPageStreak + 1 : 0
                if offPageStreak == 3, reopened < 3 {
                    reopened += 1
                    offPageStreak = 0
                    self.log.info("signed in again, reopening the approval page")
                    self.webView.load(URLRequest(url: url))
                }
                if loginStreak == 2, !self.needsUser {
                    // Don't jump in front: the app shows a notification and a red dot instead.
                    self.needsUser = true
                    self.log.info("needs user sign-in on \(self.webView.url?.host ?? "?")")
                } else if state != .login, self.needsUser, !self.isOnGoogle {
                    // Signed in; go back to being invisible.
                    self.needsUser = false
                    self.window.orderOut(nil)
                }
            }
        }
    }

    /// On the same AWS host as `url` but no longer on its #fragment page (e.g. the portal's home).
    private func lostPage(of url: URL) -> Bool {
        guard let wanted = url.fragment, !wanted.isEmpty, let now = webView.url, !webView.isLoading,
              now.host == url.host else { return false }
        let page = { (f: String) in f.split(separator: "?").first.map(String.init) ?? f }
        return page(now.fragment ?? "") != page(wanted)
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if needsUser {
            needsUser = false
            window.orderOut(nil)
        }
    }

    /// Opens the browser on `url` so you can sign in to Google by hand.
    func showSignIn(_ url: URL) {
        stop()
        manualSignIn = true
        sawGoogle = false
        webView.load(URLRequest(url: url))
        present()
    }

    func clearSession() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private var isOnGoogle: Bool { webView.url?.host == "accounts.google.com" }

    /// Logs what the page shows (and saves a snapshot next to the log) when a flow gives up on it.
    func logStuckPage() async {
        let probe = """
        JSON.stringify({title: document.title,
          buttons: [...document.querySelectorAll('button, input[type=submit], [role=button]')]
            .map(b => (b.innerText || b.value || '').trim() + (b.disabled || b.getAttribute('aria-disabled') === 'true' ? ' (disabled)' : '')).filter(s => s),
          text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 400)})
        """
        let info = (try? await webView.evaluateJavaScript(probe) as? String) ?? "probe failed"
        log.info("stuck on \(Self.short(webView.url)): \(info)")
        if let image = try? await webView.takeSnapshot(configuration: nil),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: AppLog.fileURL.deletingLastPathComponent().appendingPathComponent("AWSAutoConnect-stuck.png"))
        }
    }

    /// Shows the page the current flow is stuck on (e.g. Google sign-in).
    func reveal() {
        present()
    }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func step() async -> PageState {
        guard let result = try? await webView.evaluateJavaScript(Self.script) as? String else { return .wait }
        if result.hasPrefix("clicked") {
            log.info("\(result)")
            return .clicked
        }
        return PageState(rawValue: result) ?? .wait
    }

    /// Runs on every poll. Only clicks on Google's account picker and on AWS pages.
    private static let script = #"""
    (() => {
      const visible = el => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && !el.disabled && el.getAttribute('aria-disabled') !== 'true';
      };
      const host = location.hostname;
      if (host === 'accounts.google.com') {
        if (document.querySelector('input[type=password]:not([aria-hidden=true]), input[type=email]')) return 'login';
        const accounts = [...document.querySelectorAll('[data-identifier]')].filter(visible);
        if (accounts.length === 1) { accounts[0].click(); return 'clicked:google-account'; }
        if (accounts.length > 1) return 'login';
        // Anything else that sits on Google (2-step prompt, passkey, "Verify it's you", consent) needs
        // you too. Pass-through pages like the SAML post leave within a poll or two, before the streak counts.
        return /\/o\/saml2\//.test(location.pathname) ? 'wait' : 'login';
      }
      if (!/(\.|^)(amazonaws\.com|awsapps\.com|aws\.amazon\.com|signin\.aws)$/.test(host)) return 'wait';
      const text = (document.body && document.body.innerText) || '';
      if (/request approved|you can close this|access granted/i.test(text)) return 'done';
      const wanted = /^(confirm and continue|allow access|allow|approve|confirm)$/i;
      const buttons = [...document.querySelectorAll('button, input[type=submit], [role=button]')].filter(visible);
      const b = buttons.find(b => wanted.test((b.innerText || b.value || '').trim()));
      if (b) { b.click(); return 'clicked:' + (b.innerText || b.value).trim(); }
      return 'wait';
    })()
    """#

    // MARK: WKNavigationDelegate – log the redirect chain for debugging.

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log.info("load \(Self.short(webView.url))")
        window.title = "Loading \(webView.url?.host ?? "")…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.info("done \(Self.short(webView.url))")
        window.title = webView.title?.isEmpty == false ? webView.title! : "AWS AutoConnect – Sign in"
        let host = webView.url?.host ?? ""
        if host == "accounts.google.com" { sawGoogle = true }
        if manualSignIn, host.hasSuffix(".awsapps.com"), webView.url?.path.hasPrefix("/start") == true {
            // Either already signed in, or just came back from Google.
            manualSignIn = false
            log.info(sawGoogle ? "signed in to Google" : "already signed in")
            onSignedIn?(sawGoogle)
            Task { [window] in
                try? await Task.sleep(for: .seconds(1.5))
                window.orderOut(nil)
            }
        }
        guard ProcessInfo.processInfo.arguments.contains("--debug-browser") else { return }
        Task { [log] in
            try? await Task.sleep(for: .seconds(3))
            let probe = "JSON.stringify({title: document.title, inputs: document.querySelectorAll('input').length, text: (document.body ? document.body.innerText : '').slice(0, 300), size: [innerWidth, innerHeight]})"
            let info = (try? await webView.evaluateJavaScript(probe) as? String) ?? "probe failed"
            log.info("page \(info)")
            if let image = try? await webView.takeSnapshot(configuration: nil),
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: AppLog.fileURL.deletingLastPathComponent().appendingPathComponent("AWSAutoConnect-snapshot.png"))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("fail \(Self.short(webView.url)): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.error("fail (provisional) \(Self.short(webView.url)): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            log.error("HTTP \(http.statusCode) \(Self.short(http.url))")
        }
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("web content process crashed, reloading")
        webView.reload()
    }

    /// Host and path only; query strings carry SAML data.
    private static func short(_ url: URL?) -> String {
        guard let url else { return "?" }
        return (url.host ?? "") + url.path
    }

    // MARK: WKUIDelegate – open target=_blank links in the same view.

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: NSWindowDelegate – closing just hides.

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
