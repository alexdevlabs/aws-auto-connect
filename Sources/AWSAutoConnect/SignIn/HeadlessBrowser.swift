import AppKit
import WebKit

/// What the hidden browser should do with a page: the sign-in providers it may pass through and the
/// connector's own pages it may click on.
struct BrowserJob {
    var url: URL
    /// The chosen provider first; `IdentityProvider.generic` is always added as the last fallback.
    var providers: [IdentityProvider]
    var approvals: [ApprovalRules]
    /// If a sign-in on the way drops the #fragment page (e.g. AWS's #/device?user_code=…) and lands on
    /// the same host's home page instead, load `url` again.
    var reopenIfFragmentLost = false
}

/// A connector's own pages, where the hidden browser clicks through approval prompts.
struct ApprovalRules: Codable, Equatable {
    /// Hosts (each also matches its subdomains).
    var hosts: [String]
    /// Regex for the whole button label, case-insensitive, e.g. "^(allow access|confirm)$".
    var buttons: String
    /// Regex on the page text that means the flow is finished.
    var done: String?
}

/// A hidden WebKit browser with a persistent cookie store. It holds the sign-in provider's session,
/// clicks through the approval and account-picker pages a `BrowserJob` allows, and only shows itself
/// when the provider asks you to sign in.
@MainActor
final class HeadlessBrowser: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum PageState: Equatable { case wait, done, clicked, login(provider: String) }

    // Google refuses sign-in from browsers it doesn't recognise, so present as Safari.
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let log = AppLog("browser")
    let webView: WKWebView
    private let window: NSWindow
    private var pollTask: Task<Void, Never>?
    private var job: BrowserJob?
    /// Manual "Sign in to …": closes the window once `signInFinished` says so.
    private var signInFinished: ((URL) -> Bool)?
    private var sawProvider = false
    /// Connectors take turns: each one's `stop()` would cut off another's clicking.
    private var inUse = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// True while the window is up waiting for the user to sign in.
    private(set) var needsUser = false {
        didSet { if needsUser != oldValue { onNeedsUserChange?(needsUser) } }
    }
    /// Name of the provider whose sign-in page is waiting for you.
    private(set) var waitingProvider: String?
    /// Called when a page starts or stops needing the user (e.g. a sign-in form).
    var onNeedsUserChange: ((Bool) -> Void)?
    /// Called after a manual sign-in finishes (true if a provider page was visited on the way).
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

    /// Loads the job's URL out of sight and keeps clicking what it allows until `stop()`.
    func automate(_ job: BrowserJob) {
        stop()
        let script = Self.script(for: job)
        self.job = job
        log.info("automating \(job.url.host ?? "?")")
        webView.load(URLRequest(url: job.url))
        pollTask = Task { [weak self] in
            var loginStreak = 0
            var offPageStreak = 0
            var reopened = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1200))
                guard let self, !Task.isCancelled else { return }
                let state = await self.step(script)
                var provider: String?
                if case .login(let name) = state { provider = name }
                loginStreak = provider != nil ? loginStreak + 1 : 0
                // When the service's session has expired, it may send you through the provider and then
                // land on its home page, forgetting the page you came for. Go back to it.
                offPageStreak = job.reopenIfFragmentLost && state == .wait && self.lostPage(of: job.url) ? offPageStreak + 1 : 0
                if offPageStreak == 3, reopened < 3 {
                    reopened += 1
                    offPageStreak = 0
                    self.log.info("signed in again, reopening \(job.url.host ?? "?")")
                    self.webView.load(URLRequest(url: job.url))
                }
                if loginStreak == 2, !self.needsUser {
                    // Don't jump in front: the app shows a notification and a red dot instead.
                    self.waitingProvider = provider
                    self.needsUser = true
                    self.log.info("needs user sign-in on \(self.webView.url?.host ?? "?")")
                } else if provider == nil, self.needsUser, !self.onProviderPage {
                    // Signed in; go back to being invisible.
                    self.needsUser = false
                    self.window.orderOut(nil)
                }
            }
        }
    }

    /// On the same host as `url` but no longer on its #fragment page (e.g. the site's home).
    private func lostPage(of url: URL) -> Bool {
        guard let wanted = url.fragment, !wanted.isEmpty, let now = webView.url, !webView.isLoading,
              now.host == url.host else { return false }
        let page = { (f: String) in f.split(separator: "?").first.map(String.init) ?? f }
        return page(now.fragment ?? "") != page(wanted)
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        job = nil
        if needsUser {
            needsUser = false
            window.orderOut(nil)
        }
    }

    /// Opens the browser on `url` so you can sign in by hand. The window closes by itself once
    /// `finished` returns true for a loaded page; with nil you close it.
    func showSignIn(_ url: URL, providers: [IdentityProvider], finished: ((URL) -> Bool)?) {
        stop()
        signInProviders = providers
        signInFinished = finished
        sawProvider = false
        webView.load(URLRequest(url: url))
        present()
    }

    private var signInProviders: [IdentityProvider] = []

    func clearSession() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// On a page of one of the job's providers (not counting the catch-all generic one).
    private var onProviderPage: Bool {
        guard let host = webView.url?.host else { return false }
        let providers = job?.providers ?? signInProviders
        return providers.contains { !$0.hosts.contains("*") && $0.matches(host: host) }
    }

    /// Shows the page the current flow is stuck on (e.g. a sign-in form).
    func reveal() {
        present()
    }

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

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func step(_ script: String) async -> PageState {
        guard let result = try? await webView.evaluateJavaScript(script) as? String else { return .wait }
        return Self.parse(result, log: log)
    }

    static func parse(_ result: String, log: AppLog? = nil) -> PageState {
        if result.hasPrefix("clicked:") {
            log?.info(result)
            return .clicked
        }
        if result.hasPrefix("login:") { return .login(provider: String(result.dropFirst("login:".count))) }
        return result == "done" ? .done : .wait
    }

    // MARK: Page script

    /// The rules as JSON, handed to `pageScript`. Providers with real hosts come before the connector's
    /// pages, catch-all ("*") ones after.
    static func script(for job: BrowserJob) -> String {
        var providers = job.providers
        if !providers.contains(where: { $0.id == IdentityProvider.generic.id }) { providers.append(.generic) }
        let specific = providers.filter { !$0.hosts.contains("*") }
        let catchAll = providers.filter { $0.hosts.contains("*") }
        struct Rules: Encodable {
            let first: [IdentityProvider]
            let approvals: [ApprovalRules]
            let last: [IdentityProvider]
            let serviceButtons: [String]
        }
        let rules = Rules(first: specific, approvals: job.approvals, last: catchAll,
                          serviceButtons: providers.prefix(1).compactMap(\.serviceButton))
        let json = (try? String(decoding: JSONEncoder().encode(rules), as: UTF8.self)) ?? "{}"
        return "(\(pageScript))(\(json))"
    }

    /// Runs on every poll and returns "wait", "done", "login:<provider>" or "clicked:<label>".
    /// Only clicks on provider pickers and on the connector's pages.
    static let pageScript = #"""
    (R) => {
      const visible = el => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && !el.disabled && el.getAttribute('aria-disabled') !== 'true';
      };
      const all = sel => { try { return [...document.querySelectorAll(sel)].filter(visible); } catch (e) { return []; } };
      const host = location.hostname;
      const on = hosts => hosts.some(h => h === '*' || host === h || host.endsWith('.' + h));
      const label = b => (b.innerText || b.value || '').trim();
      const buttons = () => all('button, input[type=submit], [role=button], a[role=button]');

      const provider = p => {
        if (p.needsUser.some(s => all(s).length > 0)) return 'login:' + p.name;
        for (const s of (p.pick || [])) {
          const found = all(s);
          if (found.length === 1) { found[0].click(); return 'clicked:' + p.name + ' account'; }
          if (found.length > 1) return 'login:' + p.name;
        }
        const path = location.pathname;
        if ((p.passThrough || []).some(re => new RegExp(re).test(path))) return 'wait';
        return p.otherPagesNeedUser ? 'login:' + p.name : null;
      };

      for (const p of R.first) if (on(p.hosts)) return provider(p) || 'wait';

      for (const a of R.approvals) {
        if (!on(a.hosts)) continue;
        const text = (document.body && document.body.innerText) || '';
        if (a.done && new RegExp(a.done, 'i').test(text)) return 'done';
        const wanted = [a.buttons, ...R.serviceButtons].map(re => new RegExp(re, 'i'));
        const b = buttons().find(b => wanted.some(re => re.test(label(b))));
        if (b) { const l = label(b); b.click(); return 'clicked:' + l; }
        break;
      }

      for (const p of R.last) if (on(p.hosts)) { const s = provider(p); if (s) return s; }
      return 'wait';
    }
    """#

    // MARK: WKNavigationDelegate – log the redirect chain for debugging.

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log.info("load \(Self.short(webView.url))")
        window.title = "Loading \(webView.url?.host ?? "")…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.info("done \(Self.short(webView.url))")
        window.title = webView.title?.isEmpty == false ? webView.title! : "AWS AutoConnect – Sign in"
        if onProviderPage { sawProvider = true }
        if let finished = signInFinished, let url = webView.url, finished(url) {
            // Either already signed in, or just came back from the provider.
            signInFinished = nil
            log.info(sawProvider ? "signed in" : "already signed in")
            onSignedIn?(sawProvider)
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
