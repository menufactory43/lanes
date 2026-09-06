import Foundation

/// Emplacement des snapshots sur disque. Un fichier par dépôt, nommé par une
/// empreinte stable du chemin du dépôt.
public struct SnapshotStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/Lanes/snapshots`
    public static var `default`: SnapshotStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return SnapshotStore(directory: base.appendingPathComponent("Lanes/snapshots", isDirectory: true))
    }

    public func url(forRepo path: String) -> URL { Snapshot.url(forRepo: path, in: directory) }

    public func exists(forRepo path: String) -> Bool { FileManager.default.fileExists(atPath: url(forRepo: path).path) }

    public func open(forRepo path: String) throws -> Snapshot { try Snapshot(contentsOf: url(forRepo: path)) }

    public func remove(forRepo path: String) { try? FileManager.default.removeItem(at: url(forRepo: path)) }
}
