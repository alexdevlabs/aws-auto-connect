import Foundation

/// The log files on disk: how much room they take, clearing them, and packing them into a zip for a
/// bug report. Runs on `AppLog.queue`, so nothing is written to a file while it's moved or removed.
enum LogFiles {
    static let folder = AppLog.fileURL.deletingLastPathComponent()
    /// Written by the root helper; they start over on every connect and only the helper can remove them.
    static let helperLogs = [("tunnel.log", "/var/log/aws-autoconnect.log"), ("dns.log", "/var/log/aws-autoconnect-dns.log")]

    /// The app's own files: the log, the previous one and sign-in snapshots.
    static func appFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("AWSAutoConnect") && ($0.hasSuffix(".log") || $0.hasSuffix(".png")) }
            .sorted().map { folder.appendingPathComponent($0) }
    }

    /// Bytes used by `appFiles()`.
    static func size() async -> Int {
        await onQueue {
            appFiles().reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? Int) ?? 0) }
        }
    }

    static func clear() async {
        await onQueue { for file in appFiles() { try? FileManager.default.removeItem(at: file) } }
        AppLog("app").info("logs cleared")
    }

    /// Zips the logs (masked again, for lines written by older versions) and the helper's logs into
    /// ~/Downloads and returns the zip. Snapshots stay out: a sign-in page can show your name and
    /// email, which masking can't reach in a picture.
    @MainActor static func archive() async throws -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            .replacingOccurrences(of: "T", with: "-")
        let name = "AWSAutoConnect-logs-\(stamp)"
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let staging = work.appendingPathComponent(name)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        await onQueue {
            for file in appFiles() where file.pathExtension == "log" {
                copy(file, to: staging.appendingPathComponent(file.lastPathComponent))
            }
            for (name, path) in helperLogs where FileManager.default.isReadableFile(atPath: path) {
                copy(URL(fileURLWithPath: path), to: staging.appendingPathComponent(name))
            }
        }
        try Data(about().utf8).write(to: staging.appendingPathComponent("about.txt"))

        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        let zip = downloads.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: zip)
        let r = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", staging.path, zip.path], timeout: 60)
        guard r.status == 0 else { throw AppError("Couldn't make the zip: \(r.summary)") }
        AppLog("app").info("logs saved to \(zip.lastPathComponent)")
        return zip
    }

    /// A masked copy of a text file.
    private static func copy(_ source: URL, to target: URL) {
        guard let data = try? Data(contentsOf: source) else { return }
        try? Data(AppLog.redact(String(decoding: data, as: UTF8.self)).utf8).write(to: target)
    }

    @MainActor private static func about() -> String {
        let helper = (try? String(contentsOfFile: VPNHelper.versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            AWS AutoConnect v\(Updater.current)
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            Helper version \(helper ?? "not installed")
            Saved \(Date().formatted(date: .complete, time: .standard))

            """
    }

    private static func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in AppLog.queue.async { cont.resume(returning: work()) } }
    }
}
