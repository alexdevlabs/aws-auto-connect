import AppKit
import CryptoKit

/// Keeps a Homebrew install in ~/Applications, so it shows up in Finder, Spotlight and Launchpad and
/// "Launch at login" points at a path that survives `brew upgrade`.
/// - Started from Homebrew's Cellar: copies itself to ~/Applications, starts that copy and quits.
/// - Started from that copy after `brew upgrade`: replaces itself with Homebrew's newer build and
///   restarts. Copies made any other way (`make install`, a dragged app) are left alone.
enum AppInstaller {
    static let target = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/AWS AutoConnect.app")

    private static let log = AppLog("install")
    /// Homebrew's stable path to its build (`<prefix>/opt/aws-autoconnect/AWS AutoConnect.app`).
    private static let sourceKey = "homebrewApp"
    /// Fingerprint of the copy we put in ~/Applications, to tell it apart from other installs.
    private static let copyKey = "homebrewCopy"

    /// True if another copy was started and this process should quit.
    static func relaunchFromApplicationsIfNeeded() -> Bool {
        guard NSClassFromString("XCTestCase") == nil else { return false }
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let defaults = UserDefaults.standard

        if let optApp = homebrewApp(for: running) {
            defaults.set(optApp.path, forKey: sourceKey)
            if isLink(target) || fingerprint(running) != fingerprint(target) {
                quitCopyInApplications()
                guard install(from: running) else { return false }
            } else if let copy = copyInApplications() {
                log.info("already running from \(target.path)")
                copy.activate()
                return true
            }
            log.info("started from Homebrew, switching to \(target.path)")
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

    /// `<prefix>/Cellar/aws-autoconnect/<version>/AWS AutoConnect.app` → `<prefix>/opt/aws-autoconnect/AWS AutoConnect.app`.
    static func homebrewApp(for bundle: URL) -> URL? {
        let parts = bundle.pathComponents
        guard let cellar = parts.lastIndex(of: "Cellar"), parts.count == cellar + 4,
              parts[cellar + 1] == "aws-autoconnect" else { return nil }
        return NSURL.fileURL(withPathComponents: Array(parts[..<cellar]) + ["opt", "aws-autoconnect", parts[cellar + 3]])
    }

    private static func install(from source: URL) -> Bool {
        let fm = FileManager.default
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".AWS AutoConnect-\(UUID().uuidString).app")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
            try? fm.removeItem(at: target) // the old copy, or a link from the old install notes
            try fm.moveItem(at: staging, to: target)
            UserDefaults.standard.set(fingerprint(target), forKey: copyKey)
            return true
        } catch {
            try? fm.removeItem(at: staging)
            log.error("couldn't copy the app to \(target.path): \(error.localizedDescription)")
            return false
        }
    }

    private static func copyInApplications() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0 != .current && $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }
    }

    /// An older build still running from ~/Applications is replaced, so stop it first.
    private static func quitCopyInApplications() {
        guard let copy = copyInApplications() else { return }
        copy.terminate()
        let deadline = Date().addingTimeInterval(5)
        while !copy.isTerminated, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func launchTarget() -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", target.path]
        do {
            try open.run()
            open.waitUntilExit()
            return open.terminationStatus == 0
        } catch {
            log.error("couldn't start \(target.path): \(error.localizedDescription)")
            return false
        }
    }

    private static func fingerprint(_ app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/AWSAutoConnect")) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
