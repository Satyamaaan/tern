import Foundation

/// A program to launch. Data goes on `stdin` so mail never shows up in the process list.
public struct ProcessInvocation: Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String?
    public var stdin: Data?
    /// Scheduling class of the child. Background work (triage) runs at `.utility`, so it gives way to
    /// the apps the user is working in.
    public var qualityOfService: QualityOfService

    public init(
        executable: String, arguments: [String], environment: [String: String] = [:],
        currentDirectory: String? = nil, stdin: Data? = nil, qualityOfService: QualityOfService = .default
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.stdin = stdin
        self.qualityOfService = qualityOfService
    }
}

public struct ProcessResult: Hashable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.init(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Launches processes. Tests swap in a fake so no real CLI runs.
public protocol ProcessRunner: Sendable {
    /// Runs to completion. Throws `AIError.timedOut` after `timeout` seconds and `CancellationError`
    /// when the calling task is cancelled; both kill the process.
    func run(_ invocation: ProcessInvocation, timeout: TimeInterval) async throws -> ProcessResult
}

/// The real runner, on Foundation's `Process`.
public struct SystemProcessRunner: ProcessRunner {
    /// Seconds between SIGTERM and SIGKILL when stopping a process.
    public var killGrace: TimeInterval = 2

    public init() {}

    public func run(_ invocation: ProcessInvocation, timeout: TimeInterval) async throws -> ProcessResult {
        let run = Run(invocation: invocation, killGrace: killGrace)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            run.stop(reason: .cancelled)
        }
    }
}

/// One launch: owns the process, its pipes, and the continuation it resumes exactly once.
private final class Run: @unchecked Sendable {
    enum StopReason { case timedOut, cancelled }

    private let invocation: ProcessInvocation
    private let killGrace: TimeInterval
    private let process = Process()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stopReason: StopReason?
    private var started = false
    private var stdoutData = Data()
    private var stderrData = Data()

    init(invocation: ProcessInvocation, killGrace: TimeInterval) {
        self.invocation = invocation
        self.killGrace = killGrace
    }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        self.continuation = continuation
        let stoppedEarly = stopReason
        lock.unlock()
        if let stoppedEarly {
            finish(.failure(Self.error(for: stoppedEarly)))
            return
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        if let directory = invocation.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        process.qualityOfService = invocation.qualityOfService

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            group.leave()
            let name = URL(fileURLWithPath: invocation.executable).lastPathComponent
            finish(.failure(AIError.failed("Couldn't launch \(name): \(error.localizedDescription)")))
            return
        }
        lock.lock()
        started = true
        let stopNow = stopReason != nil
        lock.unlock()
        if stopNow { terminate() }

        read(stdout.fileHandleForReading, into: \.stdoutData, group: group)
        read(stderr.fileHandleForReading, into: \.stderrData, group: group)

        let input = stdin.fileHandleForWriting
        let data = invocation.stdin
        DispatchQueue.global(qos: .utility).async {
            // A child that exits without reading stdin must not raise SIGPIPE in the app.
            _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
            if let data, !data.isEmpty { try? input.write(contentsOf: data) }
            try? input.close()
        }

        let timer = DispatchWorkItem { [weak self] in self?.stop(reason: .timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)

        group.notify(queue: .global(qos: .utility)) { [self] in
            timer.cancel()
            lock.lock()
            let result = ProcessResult(exitCode: process.terminationStatus, stdout: stdoutData, stderr: stderrData)
            let stopped = stopReason
            lock.unlock()
            finish(stopped.map { .failure(Self.error(for: $0)) } ?? .success(result))
        }
    }

    /// Kills the process and answers at once, without waiting for its pipes to close.
    func stop(reason: StopReason) {
        lock.lock()
        guard stopReason == nil else { lock.unlock(); return }
        stopReason = reason
        let running = started
        lock.unlock()
        // Answer before killing, so the exit of the killed process can't be reported as a result.
        finish(.failure(Self.error(for: reason)))
        if running { terminate() }
    }

    private func finish(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGrace) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func read(_ handle: FileHandle, into keyPath: ReferenceWritableKeyPath<Run, Data>, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = (try? handle.readToEnd()) ?? Data()
            lock.lock()
            self[keyPath: keyPath] = data
            lock.unlock()
            group.leave()
        }
    }

    private static func error(for reason: StopReason) -> Error {
        switch reason {
        case .timedOut: AIError.timedOut
        case .cancelled: CancellationError()
        }
    }
}
