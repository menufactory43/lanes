import Foundation
import CoreServices

/// Surveille un dépôt avec FSEvents (le `.git` et l'arbre de travail) et
/// signale, avec un délai de regroupement, qu'il faut revérifier l'empreinte.
/// Ne décide rien : la décision de reconstruire appartient au coordinateur.
public final class RepoWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "app.lanes.watcher", qos: .utility)

    public init(paths: [String], debounce: TimeInterval = 1.2, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            // Ignorer les fichiers de verrou et les journaux transitoires de git.
            let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self)
            var relevant = false
            for i in 0..<count {
                guard let p = cfPaths[i] as? String else { continue }
                if p.hasSuffix(".lock") || p.contains("/.git/objects/tmp_") || p.contains("/.git/logs/") { continue }
                relevant = true
                break
            }
            if relevant { watcher.scheduleNotify() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.8, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    private func scheduleNotify() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        pending?.cancel()
    }

    deinit { stop() }
}
