import AppKit
import CryptoKit
import ServiceManagement

/// Keeps a Homebrew install in /Applications (or ~/Applications without write access there), so it
/// shows up in Finder, Spotlight and Launchpad and "Launch at login" points at a path that survives
/// `brew upgrade`.
/// - Started from Homebrew's Cellar: copies itself to `target`, starts that copy and quits.
/// - Started from that copy after `brew upgrade`: replaces itself with Homebrew's newer build and
///   restarts. Copies made any other way (`make install`, a dragged app) are left alone.
/// - Started from a copy 1.0.0 put in ~/Applications: moves it to /Applications.
enum AppInstaller {
    private static let name = "AWS AutoConnect.app"
    /// Where 1.0.0 put the copy, and still the fallback.
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(name)")
    /// /Applications if you can write there without a password (admin accounts), else ~/Applications.
    static let target = FileManager.default.isWritableFile(atPath: "/Applications")
        ? URL(fileURLWithPath: "/Applications").appendingPathComponent(name) : home

    private static let log = AppLog("install")
    /// Homebrew's stable path to its build (`<prefix>/opt/aws-autoconnect/AWS AutoConnect.app`).
    private static let sourceKey = "homebrewApp"
    /// Fingerprint of the copy we put in `target`, to tell it apart from other installs.
    private static let copyKey = "homebrewCopy"
    /// Set when a move turned "Launch at login" off, so the copy in its new place turns it back on.
    private static let loginItemKey = "reRegisterLoginItem"
    /// Set when the old copy in ~/Applications was removed; its login item may still point there.
    private static let movedKey = "movedFromHome"

    /// True if another copy was started and this process should quit.
    static func relaunchFromApplicationsIfNeeded() -> Bool {
        guard NSClassFromString("XCTestCase") == nil else { return false }
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let defaults = UserDefaults.standard

        if running.standardizedFileURL == target.standardizedFileURL,
           defaults.bool(forKey: loginItemKey) || defaults.bool(forKey: movedKey) {
            let on = defaults.bool(forKey: loginItemKey) || SMAppService.mainApp.status == .enabled
            defaults.removeObject(forKey: loginItemKey)
            defaults.removeObject(forKey: movedKey)
            log.info("moved here; Launch at login \(on ? "on" : "off")")
            if on {
                try? SMAppService.mainApp.unregister()
                do { try SMAppService.mainApp.register() } catch { log.error("couldn't turn Launch at login back on: \(error.localizedDescription)") }
            }
        }

        if let optApp = homebrewApp(for: running) {
            defaults.set(optApp.path, forKey: sourceKey)
            if isLink(target) || fingerprint(running) != fingerprint(target) {
                quitCopies()
                guard install(from: running) else { return false }
            } else if let copy = runningCopy(at: target) {
                log.info("already running from \(target.path)")
                copy.activate()
                return true
            }
            log.info("started from Homebrew, switching to \(target.path)")
            return launchTarget()
        }

        // The copy 1.0.0 made in ~/Applications, and /Applications is writable now.
        if target != home, running.standardizedFileURL == home.standardizedFileURL,
           let mine = fingerprint(running), mine == defaults.string(forKey: copyKey) {
            log.info("moving to \(target.path)")
            if SMAppService.mainApp.status == .enabled {
                // It points at this copy, which is about to go.
                try? SMAppService.mainApp.unregister()
                defaults.set(true, forKey: loginItemKey)
            }
            guard install(from: running) else {
                if defaults.bool(forKey: loginItemKey) { try? SMAppService.mainApp.register() }
                defaults.removeObject(forKey: loginItemKey)
                return false
            }
            return launchTarget()
        }

        // The copy we made, and Homebrew has a different build now.
        guard running.standardizedFileURL == target.standardizedFileURL,
              let source = defaults.string(forKey: sourceKey).map({ URL(fileURLWithPath: $0) }),
              let mine = fingerprint(running), mine == defaults.string(forKey: copyKey),
              let theirs = fingerprint(source), theirs != mine
        else { return false }
        log.info("Homebrew has a new build, updating \(target.path)")
        return install(from: source.resolvingSymlinksInPath()) && launchTarget()
    }

    /// Homebrew's build, when this is the copy made from a release install of it (so `brew upgrade`
    /// can update it). Not for `make install`/dragged copies or `--HEAD` installs. Worked out once.
    static let homebrewSource: URL? = {
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard running.standardizedFileURL == target.standardizedFileURL,
              let path = UserDefaults.standard.string(forKey: sourceKey),
              FileManager.default.fileExists(atPath: path), !isHead(URL(fileURLWithPath: path)),
              let mine = fingerprint(running), mine == UserDefaults.standard.string(forKey: copyKey)
        else { return nil }
        return URL(fileURLWithPath: path)
    }()

    /// `--HEAD` installs live in `Cellar/aws-autoconnect/HEAD-<sha>`.
    static func isHead(_ optApp: URL) -> Bool {
        optApp.resolvingSymlinksInPath().pathComponents.contains { $0.hasPrefix("HEAD") }
    }

    /// `CFBundleShortVersionString` of an app on disk (read fresh, not through Bundle's cache).
    static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// `<prefix>/Cellar/aws-autoconnect/<version>/AWS AutoConnect.app` → `<prefix>/opt/aws-autoconnect/AWS AutoConnect.app`.
    static func homebrewApp(for bundle: URL) -> URL? {
        let parts = bundle.pathComponents
        guard let cellar = parts.lastIndex(of: "Cellar"), parts.count == cellar + 4,
              parts[cellar + 1] == "aws-autoconnect" else { return nil }
        return NSURL.fileURL(withPathComponents: Array(parts[..<cellar]) + ["opt", "aws-autoconnect", parts[cellar + 3]])
    }

    /// Copies `source` to `target`; also removes our old copy in ~/Applications once it's moved.
    private static func install(from source: URL) -> Bool {
        let fm = FileManager.default
        let previous = UserDefaults.standard.string(forKey: copyKey)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".AWS AutoConnect-\(UUID().uuidString).app")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
            try? fm.removeItem(at: target) // the old copy, or a link from the old install notes
            try fm.moveItem(at: staging, to: target)
            UserDefaults.standard.set(fingerprint(target), forKey: copyKey)
            if target != home, previous != nil, fingerprint(home) == previous {
                try? fm.removeItem(at: home)
                UserDefaults.standard.set(true, forKey: movedKey)
                log.info("removed the old copy in \(home.path)")
            }
            return true
        } catch {
            try? fm.removeItem(at: staging)
            log.error("couldn't copy the app to \(target.path): \(error.localizedDescription)")
            return false
        }
    }

    private static func runningCopy(at app: URL) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0 != .current && $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
    }

    /// An older build still running from `target` (or 1.0.0's place) is replaced, so stop it first.
    private static func quitCopies() {
        for copy in [target, home].compactMap(runningCopy(at:)) {
            copy.terminate()
            let deadline = Date().addingTimeInterval(20) // it closes the VPN first
            while !copy.isTerminated, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func launchTarget() -> Bool { launch(target) }

    /// Starts a new instance of `app`; true if `open` succeeded. Blocks until `open` returns.
    static func launch(_ app: URL) -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", app.path]
        do {
            try open.run()
            open.waitUntilExit()
            return open.terminationStatus == 0
        } catch {
            AppLog("install").error("couldn't start \(app.path): \(error.localizedDescription)")
            return false
        }
    }

    static func fingerprint(_ app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/AWSAutoConnect")) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
