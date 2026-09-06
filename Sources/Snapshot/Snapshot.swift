import Foundation

public enum SnapshotError: Error, Equatable {
    case cannotOpen(String)
    case tooSmall
    case badMagic
    case unsupportedVersion(UInt32)
    case corruptTOC
    case missingSection(SectionKind)
    case sectionOutOfBounds(SectionKind)
}

/// Un snapshot ouvert : le fichier est mappé en mémoire, rien n'est copié.
/// Immuable après ouverture, donc partageable entre acteurs sans verrou.
/// Le mapping est libéré à la désallocation.
public final class Snapshot: @unchecked Sendable {
    public let url: URL
    private let base: UnsafeRawPointer
    private let length: Int
    private let sections: [SectionKind: Range<Int>]

    public let meta: MetaView
    public let strings: StringsView
    public let commits: CommitsView
    public let parents: ParentsView
    public let edges: EdgesView
    public let authors: AuthorsView
    public let refs: RefsView
    public let files: FilesView
    public let changes: ChangesView
    public let health: HealthView
    public let status: StatusView

    public init(contentsOf url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw SnapshotError.cannotOpen(String(cString: strerror(errno))) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw SnapshotError.cannotOpen("fstat") }
        let size = Int(st.st_size)
        guard size >= Format.headerSize else { throw SnapshotError.tooSmall }
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else {
            throw SnapshotError.cannotOpen("mmap")
        }
        base = UnsafeRawPointer(p)
        length = size

        let header = UnsafeRawBufferPointer(start: base, count: size)
        guard Array(header[0..<8]) == Format.magic else { munmap(p, size); throw SnapshotError.badMagic }
        let version = header.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        guard version == Format.version else { munmap(p, size); throw SnapshotError.unsupportedVersion(version) }
        let count = Int(header.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        guard count <= 64, Format.headerSize + count * Format.tocEntrySize <= size else {
            munmap(p, size); throw SnapshotError.corruptTOC
        }
        var map: [SectionKind: Range<Int>] = [:]
        for i in 0..<count {
            let o = Format.headerSize + i * Format.tocEntrySize
            let raw = header.loadUnaligned(fromByteOffset: o, as: UInt32.self)
            let off = Int(header.loadUnaligned(fromByteOffset: o + 8, as: UInt64.self))
            let len = Int(header.loadUnaligned(fromByteOffset: o + 16, as: UInt64.self))
            guard let kind = SectionKind(rawValue: raw) else { continue } // section inconnue : ignorée (compat avant)
            guard off >= 0, len >= 0, off <= size, size - off >= len else {
                munmap(p, size); throw SnapshotError.sectionOutOfBounds(kind)
            }
            map[kind] = off..<(off + len)
        }
        sections = map

        let basePtr = UnsafeRawPointer(p)
        func section(_ kind: SectionKind, required: Bool = false) throws -> UnsafeRawBufferPointer {
            guard let r = map[kind] else {
                if required { throw SnapshotError.missingSection(kind) }
                return UnsafeRawBufferPointer(start: nil, count: 0)
            }
            return UnsafeRawBufferPointer(start: basePtr + r.lowerBound, count: r.count)
        }
        do {
            let strings = StringsView(try section(.strings, required: true))
            self.strings = strings
            meta = MetaView(try section(.meta, required: true), strings: strings)
            commits = CommitsView(try section(.commits, required: true))
            parents = ParentsView(try section(.parents))
            edges = EdgesView(index: try section(.edgeIndex), data: try section(.edges))
            authors = AuthorsView(try section(.authors), strings: strings)
            refs = RefsView(try section(.refs), strings: strings)
            files = FilesView(try section(.files), strings: strings)
            changes = ChangesView(try section(.changes))
            health = HealthView(try section(.health))
            status = StatusView(try section(.status), strings: strings)
        } catch {
            munmap(p, size)
            throw error
        }
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), length) }

    public var fileSize: Int { length }
}

// MARK: - Vues

/// Vue sur un tableau de records de taille fixe. Zéro copie.
public struct RecordsView: @unchecked Sendable {
    public let buffer: UnsafeRawBufferPointer
    public let stride: Int
    public var count: Int { stride == 0 ? 0 : buffer.count / stride }

    init(_ buffer: UnsafeRawBufferPointer, stride: Int) {
        self.buffer = buffer; self.stride = stride
    }

    @inline(__always) func u8(_ i: Int, _ f: Int) -> UInt8 { buffer[i * stride + f] }
    @inline(__always) func u16(_ i: Int, _ f: Int) -> UInt16 { buffer.loadUnaligned(fromByteOffset: i * stride + f, as: UInt16.self) }
    @inline(__always) func u32(_ i: Int, _ f: Int) -> UInt32 { buffer.loadUnaligned(fromByteOffset: i * stride + f, as: UInt32.self) }
    @inline(__always) func u64(_ i: Int, _ f: Int) -> UInt64 { buffer.loadUnaligned(fromByteOffset: i * stride + f, as: UInt64.self) }
    @inline(__always) func i64(_ i: Int, _ f: Int) -> Int64 { buffer.loadUnaligned(fromByteOffset: i * stride + f, as: Int64.self) }
    @inline(__always) func bytes(_ i: Int, _ f: Int, _ n: Int) -> [UInt8] { Array(buffer[(i * stride + f)..<(i * stride + f + n)]) }
}

public struct StringsView: @unchecked Sendable {
    let buffer: UnsafeRawBufferPointer
    init(_ b: UnsafeRawBufferPointer) { buffer = b }

    public func string(offset: UInt32, length: UInt16) -> String {
        let o = Int(offset), n = Int(length)
        guard o >= 0, n >= 0, o + n <= buffer.count else { return "" }
        let slice = UnsafeRawBufferPointer(rebasing: buffer[o..<(o + n)])
        return String(decoding: slice, as: UTF8.self)
    }
}

public struct MetaView: @unchecked Sendable {
    let r: RecordsView
    let strings: StringsView
    init(_ b: UnsafeRawBufferPointer, strings: StringsView) { r = RecordsView(b, stride: Layout.Meta.stride); self.strings = strings }

    public var isEmpty: Bool { r.count == 0 }
    public var repoPath: String { str(Layout.Meta.repoPathOff, Layout.Meta.repoPathLen) }
    public var repoName: String { str(Layout.Meta.repoNameOff, Layout.Meta.repoNameLen) }
    public var head: String { str(Layout.Meta.headOff, Layout.Meta.headLen) }
    public var fingerprint: String { str(Layout.Meta.fingerprintOff, Layout.Meta.fingerprintLen) }
    public var builtAt: Date { Date(timeIntervalSince1970: TimeInterval(r.count > 0 ? r.i64(0, Layout.Meta.builtAt) : 0)) }
    public var headCommit: Int? { let v = r.count > 0 ? r.u32(0, Layout.Meta.headCommit) : noIndex; return v == noIndex ? nil : Int(v) }

    private func str(_ o: Int, _ l: Int) -> String {
        guard r.count > 0 else { return "" }
        return strings.string(offset: r.u32(0, o), length: r.u16(0, l))
    }
}

public struct CommitsView: @unchecked Sendable {
    let r: RecordsView
    init(_ b: UnsafeRawBufferPointer) { r = RecordsView(b, stride: Layout.Commit.stride) }

    public var count: Int { r.count }
    public func timestamp(_ i: Int) -> Int64 { r.i64(i, Layout.Commit.timestamp) }
    public func date(_ i: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(timestamp(i))) }
    public func oid(_ i: Int) -> [UInt8] { r.bytes(i, Layout.Commit.oid, 20) }
    public func shortHash(_ i: Int) -> String { oid(i).prefix(4).map { String(format: "%02x", $0) }.joined() }
    public func fullHash(_ i: Int) -> String { oid(i).map { String(format: "%02x", $0) }.joined() }
    public func author(_ i: Int) -> Int { Int(r.u32(i, Layout.Commit.author)) }
    public func messageRef(_ i: Int) -> (UInt32, UInt16) { (r.u32(i, Layout.Commit.messageOff), r.u16(i, Layout.Commit.messageLen)) }
    public func parentCount(_ i: Int) -> Int { Int(r.u8(i, Layout.Commit.parentCount)) }
    public func parentStart(_ i: Int) -> Int { Int(r.u32(i, Layout.Commit.parentStart)) }
    public func lane(_ i: Int) -> Int { Int(r.u8(i, Layout.Commit.lane)) }
    public func flags(_ i: Int) -> UInt32 { r.u32(i, Layout.Commit.flags) }
    public func isMerge(_ i: Int) -> Bool { flags(i) & CommitFlags.merge != 0 }
}

public struct ParentsView: @unchecked Sendable {
    let buffer: UnsafeRawBufferPointer
    init(_ b: UnsafeRawBufferPointer) { buffer = b }
    public var count: Int { buffer.count / 4 }
    /// Index du commit parent dans la section commits, ou nil s'il est hors snapshot.
    public func parent(at i: Int) -> Int? {
        guard i >= 0, (i + 1) * 4 <= buffer.count else { return nil }
        let v = buffer.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
        return v == noIndex ? nil : Int(v)
    }
}

public struct GraphEdge: Sendable, Equatable {
    public let from: Int, to: Int, kind: EdgeKind
    public init(from: Int, to: Int, kind: EdgeKind) { self.from = from; self.to = to; self.kind = kind }
}

public struct EdgesView: @unchecked Sendable {
    let index: UnsafeRawBufferPointer
    let data: UnsafeRawBufferPointer
    init(index: UnsafeRawBufferPointer, data: UnsafeRawBufferPointer) { self.index = index; self.data = data }

    public var rows: Int { max(0, index.count / 4 - 1) }

    /// Arêtes entre la ligne `row` et la ligne `row + 1`.
    public func edges(row: Int) -> [GraphEdge] {
        guard row >= 0, row < rows else { return [] }
        let start = Int(index.loadUnaligned(fromByteOffset: row * 4, as: UInt32.self))
        let end = Int(index.loadUnaligned(fromByteOffset: (row + 1) * 4, as: UInt32.self))
        guard start <= end, end * Layout.Edge.stride <= data.count else { return [] }
        var out: [GraphEdge] = []
        out.reserveCapacity(end - start)
        for e in start..<end {
            let o = e * Layout.Edge.stride
            out.append(GraphEdge(from: Int(data[o]), to: Int(data[o + 1]), kind: EdgeKind(rawValue: data[o + 2]) ?? .pass))
        }
        return out
    }
}

public struct AuthorsView: @unchecked Sendable {
    let r: RecordsView
    let strings: StringsView
    init(_ b: UnsafeRawBufferPointer, strings: StringsView) { r = RecordsView(b, stride: Layout.Author.stride); self.strings = strings }

    public var count: Int { r.count }
    public func name(_ i: Int) -> String { strings.string(offset: r.u32(i, Layout.Author.nameOff), length: r.u16(i, Layout.Author.nameLen)) }
    public func email(_ i: Int) -> String { strings.string(offset: r.u32(i, Layout.Author.emailOff), length: r.u16(i, Layout.Author.emailLen)) }
    public func commits(_ i: Int) -> Int { Int(r.u32(i, Layout.Author.commits)) }
    public func firstTimestamp(_ i: Int) -> Int64 { r.i64(i, Layout.Author.firstTs) }
    public func lastTimestamp(_ i: Int) -> Int64 { firstTimestamp(i) + Int64(r.u32(i, Layout.Author.lastTs)) }
}

public struct RefsView: @unchecked Sendable {
    let r: RecordsView
    let strings: StringsView
    init(_ b: UnsafeRawBufferPointer, strings: StringsView) { r = RecordsView(b, stride: Layout.Ref.stride); self.strings = strings }

    public var count: Int { r.count }
    public func name(_ i: Int) -> String { strings.string(offset: r.u32(i, Layout.Ref.nameOff), length: r.u16(i, Layout.Ref.nameLen)) }
    public func kind(_ i: Int) -> RefKind { RefKind(rawValue: r.u8(i, Layout.Ref.kind)) ?? .other }
    public func flags(_ i: Int) -> UInt8 { r.u8(i, Layout.Ref.flags) }
    public func commit(_ i: Int) -> Int? { let v = r.u32(i, Layout.Ref.commit); return v == noIndex ? nil : Int(v) }
}

public struct FilesView: @unchecked Sendable {
    let r: RecordsView
    let strings: StringsView
    init(_ b: UnsafeRawBufferPointer, strings: StringsView) { r = RecordsView(b, stride: Layout.File.stride); self.strings = strings }

    public var count: Int { r.count }
    public func path(_ i: Int) -> String { strings.string(offset: r.u32(i, Layout.File.pathOff), length: r.u16(i, Layout.File.pathLen)) }
    public func changes(_ i: Int) -> Int { Int(r.u32(i, Layout.File.changes)) }
    public func topAuthor(_ i: Int) -> Int? { let v = r.u32(i, Layout.File.topAuthor); return v == noIndex ? nil : Int(v) }
    public func lastTimestamp(_ i: Int) -> Int64 { r.i64(i, Layout.File.lastTs) }
    public func size(_ i: Int) -> UInt64 { r.u64(i, Layout.File.size) }
}

public struct ChangesView: @unchecked Sendable {
    let r: RecordsView
    init(_ b: UnsafeRawBufferPointer) { r = RecordsView(b, stride: Layout.Change.stride) }

    public var count: Int { r.count }
    public func file(_ i: Int) -> Int { Int(r.u32(i, Layout.Change.file)) }
    public func author(_ i: Int) -> Int { Int(r.u32(i, Layout.Change.author)) }
    public func timestamp(_ i: Int) -> Int64 { r.i64(i, Layout.Change.timestamp) }
    public func commit(_ i: Int) -> Int { Int(r.u32(i, Layout.Change.commit)) }
}

public struct HealthView: @unchecked Sendable {
    let r: RecordsView
    init(_ b: UnsafeRawBufferPointer) { r = RecordsView(b, stride: Layout.Health.stride) }

    public var isEmpty: Bool { r.count == 0 }
    private func u32(_ f: Int) -> Int { r.count > 0 ? Int(r.u32(0, f)) : 0 }
    public var sizeBytes: UInt64 { r.count > 0 ? r.u64(0, Layout.Health.sizeBytes) : 0 }
    public var looseObjects: Int { u32(Layout.Health.looseObjects) }
    public var packs: Int { u32(Layout.Health.packs) }
    public var staleBranches: Int { u32(Layout.Health.staleBranches) }
    public var trackedFiles: Int { u32(Layout.Health.trackedFiles) }
    public var modified: Int { u32(Layout.Health.modified) }
    public var staged: Int { u32(Layout.Health.staged) }
    public var untracked: Int { u32(Layout.Health.untracked) }
    public var localBranches: Int { u32(Layout.Health.localBranches) }
    public var remoteBranches: Int { u32(Layout.Health.remoteBranches) }
    public var tags: Int { u32(Layout.Health.tags) }
}

public struct StatusView: @unchecked Sendable {
    let r: RecordsView
    let strings: StringsView
    init(_ b: UnsafeRawBufferPointer, strings: StringsView) { r = RecordsView(b, stride: Layout.Status.stride); self.strings = strings }

    public var count: Int { r.count }
    public func path(_ i: Int) -> String { strings.string(offset: r.u32(i, Layout.Status.pathOff), length: r.u16(i, Layout.Status.pathLen)) }
    public func code(_ i: Int) -> Character { Character(UnicodeScalar(r.u8(i, Layout.Status.code))) }
    public func isStaged(_ i: Int) -> Bool { r.u8(i, Layout.Status.staged) == 1 }
}

// MARK: - Commodités

extension Snapshot {
    public func message(_ i: Int) -> String {
        let (o, l) = commits.messageRef(i)
        return strings.string(offset: o, length: l)
    }
    public func parentIndices(_ i: Int) -> [Int?] {
        let s = commits.parentStart(i), n = commits.parentCount(i)
        return (0..<n).map { parents.parent(at: s + $0) }
    }
    /// Emplacement conventionnel du snapshot d'un dépôt.
    public static func url(forRepo path: String, in directory: URL) -> URL {
        directory.appendingPathComponent(Self.key(forRepo: path)).appendingPathExtension("lanes")
    }
    public static func key(forRepo path: String) -> String {
        // FNV-1a 64 bits, stable et sans dépendance crypto.
        var h: UInt64 = 0xcbf29ce484222325
        for b in path.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
