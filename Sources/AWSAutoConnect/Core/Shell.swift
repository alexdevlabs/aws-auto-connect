import Foundation

struct ProcResult {
    var status: Int32
    var output: String

    var lastLine: String {
        output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Shell {
    /// GUI apps start with a minimal PATH, so use the login shell's PATH (mise, asdf, pyenv, nix…
    /// set it up there), then the places Homebrew, the AWS installer and version managers use.
    /// Worked out once, in the background at launch (see `warmUp`).
    static let searchPath = merge(loginShellPath(), fallbackPath)

    static let fallbackPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                "\(home)/.local/share/mise/shims", "\(home)/.asdf/shims", "\(home)/.local/bin",
                "\(home)/.nix-profile/bin", "/nix/var/nix/profiles/default/bin", "/run/current-system/sw/bin",
                "/opt/local/bin"]
    }()

    /// Starts the login shell lookup so the first `find` doesn't wait for it.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = searchPath }
    }

    /// Absolute directories, first occurrence wins.
    static func merge(_ lists: [String]...) -> String {
        var seen = Set<String>()
        return lists.joined().filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
    }

    static let pathMarker = "__AWS_AUTOCONNECT_PATH__"

    /// The user's shell: $SHELL, else the account's login shell, else zsh.
    static var userShell: String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty { return s }
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell { return String(cString: s) }
        return "/bin/zsh"
    }

    /// PATH as an interactive login shell sets it (`.zprofile` and `.zshrc`, where `mise activate`
    /// usually goes). Empty if the shell fails, doesn't print it, or takes over 5 s.
    static func loginShellPath() -> [String] {
        parseShellPath(output(of: userShell, ["-ilc", "printf '\(pathMarker)%s\(pathMarker)' \"$PATH\""], timeout: 5))
    }

    /// stdout of a command, collected until it exits or `timeout` passes. Doesn't wait for the
    /// pipe to close: rc files can start agents that inherit stdout and outlive the shell.
    static func output(of exe: String, _ args: [String], timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let lock = NSLock()
        var data = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.withLock { data.append(chunk) }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        guard (try? p.run()) != nil else {
            out.fileHandleForReading.readabilityHandler = nil
            return ""
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut { p.terminate() }
        // Pick up anything written just before exit.
        Thread.sleep(forTimeInterval: 0.05)
        out.fileHandleForReading.readabilityHandler = nil
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }

    /// The PATH between the markers; rc files may print other things around it.
    static func parseShellPath(_ output: String) -> [String] {
        let parts = output.components(separatedBy: pathMarker)
        guard parts.count >= 3 else { return [] }
        return parts[1].split(separator: ":").map(String.init)
    }

    static func find(_ name: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        return env
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 60) async -> ProcResult {
        await StreamingProcess(exe, args).run(timeout: timeout)
    }
}

/// A child process whose combined stdout/stderr is collected and also delivered
/// line by line on the main queue while it runs.
final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var collected = Data()
    private var partial = ""

    var onLine: (@MainActor (String) -> Void)?

    init(_ exe: String, _ args: [String], environment: [String: String] = Shell.environment) {
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func run(timeout: TimeInterval) async -> ProcResult {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if !data.isEmpty { self?.ingest(data) }
        }
        var launchError: Error?
        let status = await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                launchError = error
                cont.resume(returning: -1)
                return
            }
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.terminate()
                }
            }
        }
        handle.readabilityHandler = nil
        // Never started: our copy of the pipe's write end is still open, so reading to the end
        // would wait forever.
        if let launchError {
            let name = process.executableURL?.path ?? "process"
            return ProcResult(status: -1, output: "couldn't start \(name): \(launchError.localizedDescription)")
        }
        if let rest = try? handle.readToEnd(), !rest.isEmpty { ingest(rest) }
        flushPartial()

        let output = lock.withLock { String(decoding: collected, as: UTF8.self) }
        return ProcResult(status: status, output: output)
    }

    private func ingest(_ data: Data) {
        lock.lock()
        collected.append(data)
        partial += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let nl = partial.firstIndex(of: "\n") {
            lines.append(String(partial[..<nl]))
            partial = String(partial[partial.index(after: nl)...])
        }
        lock.unlock()
        emit(lines)
    }

    private func flushPartial() {
        lock.lock()
        let rest = partial
        partial = ""
        lock.unlock()
        if !rest.isEmpty { emit([rest]) }
    }

    private func emit(_ lines: [String]) {
        guard let onLine, !lines.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for line in lines { onLine(line) }
            }
        }
    }
}
