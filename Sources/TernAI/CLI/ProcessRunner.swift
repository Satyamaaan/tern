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

/// The real runner. Each CLI runs in a process group of its own, so stopping it (a time-out, a cancelled
/// task) reaches the helpers it started too, and the call only returns once they are gone.
public struct SystemProcessRunner: ProcessRunner {
    /// Seconds between SIGTERM and SIGKILL when stopping a process group.
    public var killGrace: TimeInterval = 2
    /// Longest wait after SIGKILL for the group to go; the caller is answered then even if it hasn't.
    public var killWait: TimeInterval = 2

    public init() {}

    public func run(_ invocation: ProcessInvocation, timeout: TimeInterval) async throws -> ProcessResult {
        let run = Run(invocation: invocation, killGrace: killGrace, killWait: killWait)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            run.stop(reason: .cancelled)
        }
    }
}

/// One launch: owns the child's process group, its pipes, and the continuation it resumes exactly once.
private final class Run: @unchecked Sendable {
    enum StopReason { case timedOut, cancelled }

    private let invocation: ProcessInvocation
    private let killGrace: TimeInterval
    private let killWait: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var answered = false
    private var stopReason: StopReason?
    /// The child's pid, which is also its process group id; 0 until it is launched.
    private var pid: pid_t = 0
    private var exitCode: Int32 = 0
    /// While a stopped group winds down: the timer that checks it, and whether SIGKILL went out.
    private var teardownTimer: DispatchSourceTimer?
    private var killSent = false
    private var stdoutData = Data()
    private var stderrData = Data()

    init(invocation: ProcessInvocation, killGrace: TimeInterval, killWait: TimeInterval) {
        self.invocation = invocation
        self.killGrace = killGrace
        self.killWait = killWait
    }

    func start(timeout: TimeInterval, continuation: CheckedContinuation<ProcessResult, Error>) {
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        lock.lock()
        self.continuation = continuation
        if let stoppedEarly = stopReason {
            lock.unlock()
            finish(.failure(Self.error(for: stoppedEarly)))
            return
        }
        // Launched under the lock, so `stop` finds either no child (and none is launched) or its pid.
        let launched = Result {
            try Self.spawn(
                invocation, stdin: stdin.fileHandleForReading.fileDescriptor,
                stdout: stdout.fileHandleForWriting.fileDescriptor, stderr: stderr.fileHandleForWriting.fileDescriptor)
        }
        if case .success(let pid) = launched { self.pid = pid }
        lock.unlock()
        // The child has its own copies of these ends; closing ours lets the reads end with the child.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let pid: pid_t
        switch launched {
        case .success(let value):
            pid = value
        case .failure(let error):
            let name = URL(fileURLWithPath: invocation.executable).lastPathComponent
            finish(.failure(AIError.failed("Couldn't launch \(name): \(error.localizedDescription)")))
            return
        }

        let group = DispatchGroup()
        group.enter()
        // Reaped on a thread of its own: a busy shared queue mustn't keep the exit waiting.
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            lock.withLock { exitCode = Self.exitCode(status) }
            group.leave()
        }
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
            let result = ProcessResult(exitCode: exitCode, stdout: stdoutData, stderr: stderrData)
            let stopped = stopReason != nil
            lock.unlock()
            // A stopped run is answered by its teardown, once the group is gone.
            if !stopped { finish(.success(result)) }
        }
    }

    /// Stops the child's whole process group, then answers.
    func stop(reason: StopReason) {
        lock.lock()
        guard stopReason == nil, !answered else { lock.unlock(); return }
        stopReason = reason
        let pid = pid
        lock.unlock()
        guard pid > 0 else {
            // Not launched, and now it won't be.
            finish(.failure(Self.error(for: reason)))
            return
        }
        tearDown(pid, reason)
    }

    /// SIGTERM to the group, SIGKILL after the grace period, and the answer once nothing of the group is
    /// left, or after `killWait` more (logged): the caller's CLI slot isn't free before then. Checked on a
    /// timer, so no thread is held while the group winds down.
    private func tearDown(_ group: pid_t, _ reason: StopReason) {
        kill(-group, SIGTERM)
        let started = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        lock.withLock { teardownTimer = timer }
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(20))
        timer.setEventHandler { [self] in
            let elapsed = Date().timeIntervalSince(started)
            if !ProcessGroup.isGone(group) {
                let sendKill = lock.withLock { () -> Bool in
                    guard elapsed >= killGrace, !killSent else { return false }
                    killSent = true
                    return true
                }
                if sendKill { kill(-group, SIGKILL) }
                guard elapsed >= killGrace + killWait else { return }
                aiLog.error("a stopped CLI's processes were still running \(self.killWait, format: .fixed(precision: 1))s after SIGKILL")
            }
            timer.cancel()
            lock.withLock { teardownTimer = nil }
            finish(.failure(Self.error(for: reason)))
        }
        timer.resume()
    }

    private func finish(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        if continuation != nil { answered = true }
        lock.unlock()
        continuation?.resume(with: result)
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

    /// Launches the child in a new process group (its pid is the group id), with default signal handling,
    /// no open descriptors but the three pipe ends, and the invocation's environment, directory and
    /// scheduling class. `Process` can't make a group before the child runs; `setpgid` after launch would
    /// race the helpers it starts.
    private static func spawn(_ invocation: ProcessInvocation, stdin: Int32, stdout: Int32, stderr: Int32) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        if let qos = qosClass(invocation.qualityOfService) { posix_spawnattr_set_qos_class_np(&attributes, qos) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let directory = invocation.currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, directory) }

        let argv = ([invocation.executable] + invocation.arguments).map { strdup($0) } + [nil]
        let envp = invocation.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, invocation.executable, &actions, &attributes, argv, envp)
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EPERM) }
        return pid
    }

    private static func qosClass(_ quality: QualityOfService) -> qos_class_t? {
        switch quality {
        case .userInteractive: QOS_CLASS_USER_INTERACTIVE
        case .userInitiated: QOS_CLASS_USER_INITIATED
        case .utility: QOS_CLASS_UTILITY
        case .background: QOS_CLASS_BACKGROUND
        default: nil
        }
    }

    /// The exit status, or the signal's number for a child killed by one (as `Process` reports it).
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    private static func error(for reason: StopReason) -> Error {
        switch reason {
        case .timedOut: AIError.timedOut
        case .cancelled: CancellationError()
        }
    }
}

/// Members of a process group, as the runner sees them when it stops one.
enum ProcessGroup {
    /// True when no live process is left in `group`. A zombie doesn't count: it holds nothing but its pid
    /// until it is reaped, which for an orphaned helper is up to launchd.
    static func isGone(_ group: pid_t) -> Bool {
        if kill(-group, 0) == -1, errno == ESRCH { return true }
        var pids = [pid_t](repeating: 0, count: 512)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return false }
        return !pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).contains { $0 > 0 && isAlive($0) }
    }

    /// True for a process that exists and isn't a zombie.
    static func isAlive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size == Int32(MemoryLayout<proc_bsdinfo>.size) && info.pbi_status != SZOMB
    }
}
