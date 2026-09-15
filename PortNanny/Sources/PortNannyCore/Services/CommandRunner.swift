import Foundation

/// Runs a command-line tool with a hard timeout, capturing stdout.
///
/// Every external tool the app shells out to (lsof, ps, pgrep, docker, pm2,
/// launchctl) goes through here so a hung subprocess can never freeze a
/// refresh: on timeout the child is SIGKILLed and an error is thrown.
///
/// Only the direct child is killed. A tool that leaves a background process
/// behind keeps it: pm2 starts its long-running daemon exactly that way on
/// first use, and taking down the whole process group on a slow `pm2 jlist`
/// would kill the daemon the person relies on.
public enum CommandRunner {

    public enum CommandError: Error, LocalizedError, Equatable {
        case timedOut(String)
        /// `detail` is the tool's own last line on stderr: "No such container:
        /// web" tells a person something "docker failed (exit 1)" never did.
        case failed(command: String, exitCode: Int32, detail: String?)
        case notUTF8(String)
        case couldNotStart(command: String, reason: String)
        case outputTooLarge(String)

        public var errorDescription: String? {
            switch self {
            case .timedOut(let command):
                return "\(command) timed out"
            case .failed(let command, let exitCode, let detail):
                guard let detail else { return "\(command) failed (exit \(exitCode))" }
                return "\(command) failed (exit \(exitCode)): \(detail)"
            case .notUTF8(let command):
                return "\(command) produced unreadable output"
            case .couldNotStart(let command, let reason):
                return "could not run \(command): \(reason)"
            case .outputTooLarge(let command):
                return "\(command) produced more output than PortNanny will read"
            }
        }
    }

    /// No tool PortNanny calls comes near this: `ps` for ~700 processes with
    /// full command lines is a few megabytes. It exists so a broken or hostile
    /// tool on PATH cannot exhaust memory; 64 MB used to be read in full.
    public static let maxOutputBytes = 32 * 1024 * 1024

    /// Enough for a tool's error message, not enough to matter if it floods.
    static let maxErrorBytes = 64 * 1024

    /// Some tools use non-zero exits for "no results" (lsof/pgrep exit 1 when
    /// nothing matches), so callers can widen `allowedExitCodes` for those.
    public static func run(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval = 5.0,
        allowedExitCodes: Set<Int32> = [0]
    ) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }

        // Output arrives through readability handlers instead of blocking
        // reads on worker threads: nothing ever parks inside read(2), so the
        // handles can always be closed, timeout included. A blocking design
        // leaked one fd and one dispatch thread every time a child hung.
        // Both pipes are drained, so a tool that fills stderr cannot block on
        // a full pipe that nobody reads.
        let output = OutputCollector(limit: maxOutputBytes)
        let errors = OutputCollector(limit: maxErrorBytes)
        let outputReader = stdout.fileHandleForReading
        let errorReader = stderr.fileHandleForReading
        outputReader.readabilityHandler = { handle in output.read(from: handle) }
        errorReader.readabilityHandler = { handle in errors.read(from: handle) }
        defer {
            output.close(outputReader)
            errors.close(errorReader)
        }

        let commandName = (path as NSString).lastPathComponent
        do {
            try task.run()
        } catch {
            throw CommandError.couldNotStart(command: commandName, reason: error.localizedDescription)
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // terminate() is guarded by Foundation against a reaped pid, unlike
            // a raw kill(2) after a racing exit.
            if task.isRunning {
                task.terminate()
                kill(task.processIdentifier, SIGKILL)
            }
            _ = exited.wait(timeout: .now() + 1.0)
            throw CommandError.timedOut(commandName)
        }

        // The child has exited; its output must be complete before it is
        // parsed. A pipe still held open by a grandchild counts as a hang.
        guard output.waitForEOF(timeout: max(1.0, timeout)) else {
            throw CommandError.timedOut(commandName)
        }
        guard !output.overflowed else {
            throw CommandError.outputTooLarge(commandName)
        }

        guard allowedExitCodes.contains(task.terminationStatus) else {
            // stderr is only worth a short wait: the exit status is already
            // known, and the message is a courtesy.
            _ = errors.waitForEOF(timeout: 0.5)
            throw CommandError.failed(command: commandName, exitCode: task.terminationStatus, detail: lastLine(of: errors.data))
        }
        guard let text = String(data: output.data, encoding: .utf8) else {
            throw CommandError.notUTF8(commandName)
        }
        return text
    }

    /// The last non-empty line of a tool's stderr, trimmed and kept short.
    static func lastLine(of data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last(where: { !$0.isEmpty }) else { return nil }
        return AgentSignatures.cleanedLabel(String(last.prefix(300)))
    }

    /// Accumulates pipe output and owns the handle's lifetime: reads and the
    /// close take one lock, so the fd is never closed under a read in flight
    /// (which raises an uncatchable ObjC exception).
    private final class OutputCollector {
        private let lock = NSLock()
        private let eof = DispatchSemaphore(value: 0)
        private let limit: Int
        private var buffer = Data()
        private var closed = false
        private var exceeded = false

        init(limit: Int) {
            self.limit = limit
        }

        func read(from handle: FileHandle) {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                eof.signal()
                return
            }
            // Past the limit the output is still read, so the child can finish
            // writing and exit, but none of it is kept.
            guard buffer.count + chunk.count <= limit else {
                exceeded = true
                return
            }
            buffer.append(chunk)
        }

        func close(_ handle: FileHandle) {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            handle.readabilityHandler = nil
            try? handle.close()
        }

        func waitForEOF(timeout: TimeInterval) -> Bool {
            eof.wait(timeout: .now() + timeout) == .success
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }

        var overflowed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exceeded
        }
    }
}
