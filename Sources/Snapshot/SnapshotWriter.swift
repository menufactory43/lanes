import Foundation

/// Construit un fichier snapshot section par section. Les sections sont des
/// `Data` accumulées puis écrites avec alignement. Le writer ne connaît pas
/// Git : il ne fait que sérialiser des records selon `Layout`.
public struct SnapshotWriter {
    public private(set) var strings = StringTable()
    private var sections: [SectionKind: Data] = [:]

    public init() {}

    public mutating func intern(_ s: String) -> (offset: UInt32, length: UInt16) {
        strings.intern(s)
    }

    public mutating func set(_ kind: SectionKind, _ data: Data) {
        precondition(kind != .strings, "la table de chaînes est gérée par le writer")
        sections[kind] = data
    }

    public mutating func append(_ kind: SectionKind, _ data: Data) {
        sections[kind, default: Data()].append(data)
    }

    /// Sérialise en mémoire. Layout : header, TOC, sections alignées.
    public func serialize() -> Data {
        var all = sections
        all[.strings] = strings.blob
        let kinds = all.keys.sorted { $0.rawValue < $1.rawValue }

        var out = Data(capacity: all.values.reduce(0) { $0 + $1.count } + 4096)
        out.append(contentsOf: Format.magic)
        out.appendLE(Format.version)
        out.appendLE(UInt32(kinds.count))
        out.appendLE(UInt64(0)) // réservé

        var cursor = Format.headerSize + kinds.count * Format.tocEntrySize
        cursor = align(cursor)
        var toc = Data()
        var payload = Data()
        for kind in kinds {
            let data = all[kind]!
            let padded = align(cursor) - cursor
            if padded > 0 { payload.append(Data(count: padded)); cursor += padded }
            toc.appendLE(kind.rawValue)
            toc.appendLE(UInt32(0))
            toc.appendLE(UInt64(cursor))
            toc.appendLE(UInt64(data.count))
            payload.append(data)
            cursor += data.count
        }
        out.append(toc)
        let headerEnd = Format.headerSize + kinds.count * Format.tocEntrySize
        let pad = align(headerEnd) - headerEnd
        if pad > 0 { out.append(Data(count: pad)) }
        out.append(payload)
        return out
    }

    /// Écriture atomique : fichier temporaire puis `rename`.
    public func write(to url: URL) throws {
        let data = serialize()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private func align(_ n: Int) -> Int {
        (n + Format.alignment - 1) / Format.alignment * Format.alignment
    }
}

/// Table de chaînes internée : une chaîne identique n'est stockée qu'une fois.
public struct StringTable {
    public private(set) var blob = Data()
    private var index: [String: (UInt32, UInt16)] = [:]

    public init() {}

    public mutating func intern(_ s: String) -> (offset: UInt32, length: UInt16) {
        if let hit = index[s] { return hit }
        var utf8 = Array(s.utf8)
        if utf8.count > Int(UInt16.max) { utf8 = Array(utf8.prefix(Int(UInt16.max))) }
        let entry = (UInt32(blob.count), UInt16(utf8.count))
        blob.append(contentsOf: utf8)
        index[s] = entry
        return entry
    }
}

/// Aide à la construction de records : écrit des champs à des offsets fixes.
public struct RecordBuilder {
    public var bytes: [UInt8]
    public init(stride: Int) { bytes = [UInt8](repeating: 0, count: stride) }

    public mutating func put(_ v: UInt8, at o: Int) { bytes[o] = v }
    public mutating func put(_ v: UInt16, at o: Int) { putLE(UInt64(v), width: 2, at: o) }
    public mutating func put(_ v: UInt32, at o: Int) { putLE(UInt64(v), width: 4, at: o) }
    public mutating func put(_ v: UInt64, at o: Int) { putLE(v, width: 8, at: o) }
    public mutating func put(_ v: Int64, at o: Int) { putLE(UInt64(bitPattern: v), width: 8, at: o) }
    public mutating func put(_ v: [UInt8], at o: Int) { bytes.replaceSubrange(o..<(o + v.count), with: v) }

    private mutating func putLE(_ v: UInt64, width: Int, at o: Int) {
        for i in 0..<width { bytes[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
    }
}

public extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
