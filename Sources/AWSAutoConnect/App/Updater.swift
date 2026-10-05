import AppKit
import Observation

/// Checks GitHub for a newer release and, for Homebrew installs, updates with `brew upgrade`.
/// After the upgrade it starts Homebrew's build, which quits this copy (closing the VPN), replaces it
/// in /Applications and starts it again (see `AppInstaller`); the VPN then reconnects if it was up.
@MainActor
@Observable
final class Updater {
    static let repo = "alexdevlabs/aws-auto-connect"

    struct Release: Equatable, Decodable {
        let tagName: String
        let htmlURL: URL
        var version: String { Updater.trimmed(tagName) }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case updating(Release, String)
        case failed(Release?, String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored var notify: ((String, String) -> Void)?
    /// Whether a tunnel is up, so an automatic update can wait for it to close.
    @ObservationIgnored var tunnelUp: () -> Bool = { false }
    /// Whether the VPN was up and should be reconnected after the update restarts the app.
    @ObservationIgnored var vpnConnected: () -> Bool = { false }
    @ObservationIgnored private let log = AppLog("update")
    /// Failed checks retry after an hour instead of waiting a day.
    @ObservationIgnored private var lastAttempt = Date.distantPast
    /// Tells a brew run's late output lines apart from the current state.
    @ObservationIgnored private var runID = UUID()

    private static let lastCheckKey = "updateLastCheck"
    private static let notifiedKey = "updateNotifiedVersion"
    private static let reconnectKey = "updateReconnectVPN"

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The release to offer, if any.
    var release: Release? {
        switch state {
        case .available(let r), .updating(let r, _): return r
        case .failed(let r, _): return r
        default: return nil
        }
    }

    var isUpdating: Bool { if case .updating = state { return true } else { return false } }

    /// Homebrew's build, if this app is the copy `AppInstaller` made from it. Only then can it update itself.
    var homebrewApp: URL? { AppInstaller.homebrewSource }

    /// How to update by hand, for installs the app can't update itself.
    var manualHint: String {
        if let opt = UserDefaults.standard.string(forKey: "homebrewApp"), AppInstaller.isHead(URL(fileURLWithPath: opt)) {
            return "brew upgrade --fetch-HEAD aws-autoconnect"
        }
        return "brew upgrade aws-autoconnect"
    }

    // MARK: Checking

    /// Called every minute: checks once a day, and installs on its own if that's turned on.
    func tick() {
        guard Prefs.checkForUpdates, !isUpdating, state != .checking else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if last.addingTimeInterval(24 * 3600) < Date(), lastAttempt.addingTimeInterval(3600) < Date() {
            Task { await check() }
        } else if case .available(let r) = state, autoInstallAllowed {
            Task { await install(r, automatic: true) }
        }
    }

    private var autoInstallAllowed: Bool {
        Prefs.autoInstallUpdates && homebrewApp != nil && !tunnelUp() && !Prefs.isQuiet()
    }

    func check() async {
        guard !isUpdating, state != .checking else { return }
        let previous = state
        state = .checking
        lastAttempt = Date()
        do {
            let found = try await Self.fetchLatest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard let latest = found, Self.isNewer(latest.version, than: Self.current) else {
                state = .upToDate
                return
            }
            log.info("v\(latest.version) is available (running v\(Self.current))")
            state = .available(latest)
            if UserDefaults.standard.string(forKey: Self.notifiedKey) != latest.version {
                UserDefaults.standard.set(latest.version, forKey: Self.notifiedKey)
                notify?("Update available", "AWS AutoConnect v\(latest.version) is out. Update from the Status tab.")
            }
        } catch {
            log.error("update check failed: \(error.localizedDescription)")
            // Keep offering an update that was already found.
            if case .available = previous { state = previous } else { state = .failed(nil, "Couldn't check for updates") }
        }
    }

    /// Latest published release, or nil if there is none yet.
    static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AWSAutoConnect/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw AppError("GitHub answered HTTP \(status)") }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// "v1.10.0" > "1.9.2"; missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) in trimmed(s).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    nonisolated static func trimmed(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    func openNotes() {
        guard let release else { return }
        NSWorkspace.shared.open(Self.notesURL(release))
    }

    /// The release page, only if it's on this repo's GitHub; otherwise the releases list.
    static func notesURL(_ release: Release) -> URL {
        let releases = URL(string: "https://github.com/\(repo)/releases")!
        let url = release.htmlURL
        guard url.scheme == "https", url.host == "github.com", url.path.hasPrefix("/\(repo)/releases/") else { return releases }
        return url
    }

    // MARK: Installing

    /// `automatic`: started by the daily auto-install, so it won't restart if the VPN came up meanwhile.
    func install(_ release: Release, automatic: Bool = false) async {
        guard !isUpdating, let app = homebrewApp else { return }
        guard let brew = Shell.find("brew") else { return fail(release, "Homebrew not found") }
        log.info("updating to v\(release.version)")
        state = .updating(release, "Updating Homebrew")
        // A broken unrelated tap makes this fail; the upgrade below can still work.
        let update = await run(brew, ["update", "--quiet"], release: release, timeout: 300)
        if update.status != 0 { log.error("brew update failed, upgrading anyway: \(update.lastLine)") }

        state = .updating(release, "Building v\(release.version)")
        let upgrade = await run(brew, ["upgrade", "aws-autoconnect"], release: release, timeout: 1800)
        guard upgrade.status == 0 else { return fail(release, "brew upgrade failed: \(upgrade.lastLine)") }

        guard let built = AppInstaller.version(of: app), Self.isNewer(built, than: Self.current) else {
            return fail(release, "Homebrew doesn't have v\(release.version) yet. Try again later.")
        }
        if automatic, !autoInstallAllowed {
            // Installed, but you're using the VPN now: restart on a later tick, when it's off again.
            log.info("v\(built) is built; waiting for the VPN to be off to restart")
            state = .available(release)
            return
        }
        state = .updating(release, "Restarting")
        UserDefaults.standard.set(vpnConnected(), forKey: Self.reconnectKey)
        // Homebrew's build quits this copy, replaces it and starts the new one.
        let started = await Task.detached { AppInstaller.launch(app) }.value
        guard started else {
            UserDefaults.standard.removeObject(forKey: Self.reconnectKey)
            return fail(release, "Couldn't start v\(built)")
        }
        try? await Task.sleep(for: .seconds(90))
        // Still here: the new build didn't take over.
        UserDefaults.standard.removeObject(forKey: Self.reconnectKey)
        fail(release, "v\(built) didn't start. Quit and open the app again.")
    }

    private func run(_ exe: String, _ args: [String], release: Release, timeout: TimeInterval) async -> ProcResult {
        var env = Shell.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        let id = UUID()
        runID = id
        let proc = StreamingProcess(exe, args, environment: env)
        proc.onLine = { [weak self] line in
            guard let self, self.runID == id, case .updating = self.state, line.hasPrefix("==> ") else { return }
            self.state = .updating(release, String(line.dropFirst(4)))
        }
        let result = await proc.run(timeout: timeout)
        runID = UUID()  // ignore lines still on their way
        return result
    }

    private func fail(_ release: Release, _ message: String) {
        log.error(message)
        state = .failed(release, message)
    }

    /// True once after an update restarted the app with the VPN up.
    static func takeReconnectFlag() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: reconnectKey) }
        return UserDefaults.standard.bool(forKey: reconnectKey)
    }
}
