import Foundation

/// Runs a CLI login that wants a browser (`aws sso login`, `gcx auth login`, …) and lets the hidden
/// browser do the clicking. The URL is taken from the command's output, or caught when the command
/// tries to open it: `open` and `$BROWSER` point at a stand-in script that hands it to us instead of
/// your default browser.
@MainActor
struct CLILogin {
    let browser: HeadlessBrowser
    /// Shown in errors, e.g. "SSO".
    let name: String
    let executable: String
    let arguments: [String]
    /// Builds the browser job for the URL the command asks for.
    let job: (URL) -> BrowserJob
    /// Give up after this long unless you're busy signing in (then after 10 minutes).
    var timeout: Int = 120
    /// Give up if the command hasn't given a sign-in URL by then: it's usually stuck retrying a
    /// network that isn't there (e.g. just after waking up).
    var urlTimeout: Int = 30

    private let log = AppLog("login")

    init(browser: HeadlessBrowser, name: String, executable: String, arguments: [String],
         timeout: Int = 120, job: @escaping (URL) -> BrowserJob) {
        self.browser = browser
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.job = job
    }

    /// The arguments with flag values left out ("sso login --sso-session … --no-browser"): extra login
    /// arguments are free text and may hold a token.
    nonisolated static func describe(_ arguments: [String]) -> String {
        var out: [String] = []
        var afterFlag = false
        for arg in arguments {
            if arg.hasPrefix("-") {
                let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
                out.append(arg.contains("=") ? name + "=…" : name)
                afterFlag = !arg.contains("=")
            } else {
                out.append(afterFlag ? "…" : arg)
                afterFlag = false
            }
        }
        return out.joined(separator: " ")
    }

    /// Takes the browser for itself (see `HeadlessBrowser.exclusive`) and returns once the command
    /// succeeds; throws with its last output line otherwise.
    func run() async throws {
        try await browser.exclusive { try await runExclusive() }
    }

    private func runExclusive() async throws {
        let shim = try OpenShim()
        defer { shim.remove() }
        let tool = (executable as NSString).lastPathComponent
        log.info("running \(executable) \(Self.describe(arguments))")
        let started = Date()

        let proc = StreamingProcess(executable, arguments, environment: shim.environment(Shell.environment))
        let picker = LoginURLPicker { [browser, job, log] url in
            log.info("opening \(url.host ?? "?")\(url.path) in the hidden browser")
            browser.automate(job(url))
        }
        proc.onLine = { [log] line in
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { log.info("\(tool)| \(line.prefix(500))") }
            picker.consume(line)
        }
        let opened = Task { [log] in
            for await url in shim.urls() {
                log.info("\(tool) asked to open a URL")
                picker.offer(url)
            }
        }

        let watchdog = Task { [browser, timeout, urlTimeout] in
            var waited = 0
            while waited < 600 {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                waited += 5
                if waited >= urlTimeout, !picker.fired {
                    log.error("\(tool) gave no sign-in URL in \(waited)s, giving up")
                    proc.terminate()
                    return
                }
                if waited >= timeout, !browser.needsUser { break }
            }
            log.error("\(tool) still running after \(waited)s, giving up")
            await browser.logStuckPage()
            proc.terminate()
        }
        let result = await proc.run(timeout: 0)
        watchdog.cancel()
        opened.cancel()
        picker.cancel()
        let seconds = Int(Date().timeIntervalSince(started))
        if result.status == 0 {
            log.info("\(tool) finished in \(seconds)s")
        } else {
            log.error("\(tool) exited with \(result.status) after \(seconds)s\(picker.fired ? "" : ", before giving a sign-in URL")")
            // Unless the watchdog already did, record where the browser got to.
            if result.status != 15, picker.fired { await browser.logStuckPage() }
        }
        browser.stop()

        guard result.status == 0 else {
            if result.status == 15, !picker.fired { throw AppError("\(name) sign-in didn't start. Is the network up?") }
            throw AppError(result.status == 15 ? "\(name) approval timed out" : "\(name) login failed: \(result.summary)")
        }
    }
}

/// Picks the best approval URL from a login command's output: the pre-filled `?user_code=` link if
/// printed, else the base URL plus the code. A URL the command tried to open wins straight away.
@MainActor
final class LoginURLPicker {
    private var urls: [String] = []
    private var code: String?
    private var opened = false
    private var pending: Task<Void, Never>?
    private let open: (URL) -> Void

    init(open: @escaping (URL) -> Void) { self.open = open }

    func consume(_ line: String) {
        guard !opened else { return }
        let text = line.trimmingCharacters(in: .whitespaces)
        if let r = text.range(of: #"https://\S+"#, options: .regularExpression) {
            urls.append(String(text[r]))
        } else if text.range(of: #"^[A-Z0-9]{4}-[A-Z0-9]{4}$"#, options: .regularExpression) != nil {
            code = text
        }
        if let filled = urls.first(where: { $0.contains("user_code=") }) {
            fire(filled)
        } else if !urls.isEmpty {
            // Wait briefly in case the pre-filled link follows.
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let base = self.urls.first else { return }
                if let code = self.code, var comps = URLComponents(string: base) {
                    comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "user_code", value: code)]
                    self.fire(comps.string ?? base)
                } else {
                    self.fire(base)
                }
            }
        }
    }

    /// A URL the command asked to open.
    func offer(_ url: String) { fire(url) }

    func cancel() { pending?.cancel() }

    /// A URL went to the browser.
    var fired: Bool { opened }

    private func fire(_ string: String) {
        guard !opened, let url = URL(string: string) else { return }
        opened = true
        pending?.cancel()
        open(url)
    }
}

/// A temporary folder with an `open` stand-in, put first on the command's PATH and set as $BROWSER.
/// It appends any http(s) argument to a file that `urls()` watches, and opens nothing.
struct OpenShim {
    let dir: URL
    var urlFile: URL { dir.appendingPathComponent("urls") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aws-autoconnect-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: urlFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let script = """
        #!/bin/sh
        # Stands in for `open` and $BROWSER during a CLI login: hands URLs to AWS AutoConnect.
        for a in "$@"; do
          case "$a" in http://*|https://*) printf '%s\\n' "$a" >> '\(urlFile.path)' ;; esac
        done
        exit 0
        """
        let exe = dir.appendingPathComponent("open")
        try Data(script.utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)
    }

    func environment(_ base: [String: String]) -> [String: String] {
        var env = base
        env["PATH"] = dir.path + ":" + (base["PATH"] ?? Shell.searchPath)
        env["BROWSER"] = dir.appendingPathComponent("open").path
        return env
    }

    /// URLs as they're written, until cancelled.
    func urls() -> AsyncStream<String> {
        let file = urlFile
        return AsyncStream { cont in
            let task = Task {
                var seen = 0
                while !Task.isCancelled {
                    let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
                    for line in lines.dropFirst(seen) { cont.yield(String(line)) }
                    seen = max(seen, lines.count)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}
