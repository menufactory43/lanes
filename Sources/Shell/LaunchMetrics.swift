import Foundation
import os

/// Horodatage des phases depuis le démarrage réel du processus (pas depuis
/// `main`), via `sysctl` KERN_PROCARGS… ou plus simplement `proc_pidinfo`.
/// Émet des signposts (visibles dans Instruments) et, si `LANES_MEASURE=1`,
/// imprime un rapport sur stderr à la phase `.warm`.
public enum LaunchMetrics {
    private static let log = OSLog(subsystem: "app.lanes", category: .pointsOfInterest)
    private static let signposter = OSSignposter(logHandle: log)
    private static let processStart: Date = processStartDate()
    private static let lock = OSAllocatedUnfairLock(initialState: [LaunchPhase: TimeInterval]())

    public static var isMeasuring: Bool { ProcessInfo.processInfo.environment["LANES_MEASURE"] == "1" }

    /// À appeler dès l'entrée de `main` pour fixer la référence.
    public static func prime() { _ = processStart }

    public static func mark(_ phase: LaunchPhase) {
        let elapsed = Date().timeIntervalSince(processStart)
        lock.withLock { $0[phase] = elapsed }
        signposter.emitEvent("LaunchPhase", "\(phase.rawValue, privacy: .public) \(elapsed, privacy: .public)")
        if isMeasuring {
            FileHandle.standardError.write(Data("[lanes] \(phase) at \(Self.format(elapsed))\n".utf8))
        }
    }

    /// Repère libre, imprimé seulement en mode mesure. Pour diagnostiquer.
    public static func note(_ label: @autoclosure () -> String) {
        guard isMeasuring else { return }
        let elapsed = Date().timeIntervalSince(processStart)
        FileHandle.standardError.write(Data("[lanes]   · \(label()) at \(format(elapsed))\n".utf8))
    }

    public static func elapsed(_ phase: LaunchPhase) -> TimeInterval? {
        lock.withLock { $0[phase] }
    }

    public static func report() -> String {
        let marks = lock.withLock { $0 }
        return LaunchPhase.allCases.compactMap { phase in
            marks[phase].map { "\(phase): \(format($0))" }
        }.joined(separator: "\n")
    }

    private static func format(_ t: TimeInterval) -> String {
        String(format: "%.0f ms", t * 1000)
    }

    /// Heure de création du processus, lue dans le noyau. Précision microseconde.
    private static func processStartDate() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return Date() }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
