import Foundation
import os

/// Signpost intervals for the speed budget (view them in Instruments → os_signpost, subsystem dev.tern).
enum Timing {
    static let signposter = OSSignposter(subsystem: "dev.tern", category: "speed")

    struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
        let started: UInt64
    }

    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()), started: DispatchTime.now().uptimeNanoseconds)
    }

    /// Ends the interval and returns its length in milliseconds.
    @discardableResult
    static func end(_ interval: Interval) -> Double {
        signposter.endInterval(interval.name, interval.state)
        return Double(DispatchTime.now().uptimeNanoseconds - interval.started) / 1_000_000
    }

    /// Milliseconds since the process started, from the kernel's process start time.
    static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - started) * 1000
    }
}
