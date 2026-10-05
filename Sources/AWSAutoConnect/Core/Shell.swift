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
    /// GUI apps start with a minimal PATH, so look where Homebrew and the AWS installer put things.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

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
