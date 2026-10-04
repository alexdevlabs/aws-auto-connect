import Foundation

/// Refreshes an AWS CLI sso-session: silently via the cached refresh token when
/// possible, otherwise by running `aws sso login` and approving it in the hidden browser.
@MainActor
struct SSORefresher {
    let browser: HeadlessBrowser
    private let log = AppLog("sso")

    func refresh(_ session: SSOSession) async throws {
        guard let aws = Shell.find("aws") else { throw AppError("AWS CLI not found") }
        let before = SSOCache.token(for: session.name)?.expiresAt

        // The CLI refreshes the access token itself once it is close to expiring.
        if let profile = AWSConfig.profile(using: session.name) {
            let r = await Shell.run(aws, ["configure", "export-credentials", "--profile", profile, "--format", "process"], timeout: 45)
            if r.status == 0, let after = SSOCache.token(for: session.name)?.expiresAt,
               after > (before ?? .distantPast), after.timeIntervalSinceNow > 300 {
                log.info("silent refresh ok")
                return
            }
        }
        log.info("silent refresh not possible, using browser approval")
        try await browser.exclusive { try await interactiveLogin(aws: aws, session: session) }
    }

    private func interactiveLogin(aws: String, session: SSOSession) async throws {
        log.info("starting aws sso login")
        let proc = StreamingProcess(aws, ["sso", "login", "--sso-session", session.name, "--no-browser"])
        let picker = LoginURLPicker { [browser] url in browser.automate(url) }
        proc.onLine = { line in picker.consume(line) }

        // Give up after 2 minutes unless the user is busy signing in to Google.
        let watchdog = Task { [browser] in
            var waited = 0
            while waited < 600 {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                waited += 5
                if waited >= 120, !browser.needsUser { break }
            }
            await browser.logStuckPage()
            proc.terminate()
        }
        let result = await proc.run(timeout: 0)
        watchdog.cancel()
        picker.cancel()
        browser.stop()

        guard result.status == 0 else {
            throw AppError(result.status == 15 ? "SSO approval timed out" : "aws sso login failed: \(result.lastLine)")
        }
        log.info("aws sso login ok")
    }
}

/// Picks the best approval URL from `aws sso login --no-browser` output: the
/// pre-filled `?user_code=` link if printed, else the base URL plus the code.
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

    func cancel() { pending?.cancel() }

    private func fire(_ string: String) {
        guard !opened, let url = URL(string: string) else { return }
        opened = true
        pending?.cancel()
        open(url)
    }
}
