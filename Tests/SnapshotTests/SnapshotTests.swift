import Foundation
import Testing
@testable import Snapshot

@Suite struct SnapshotTests {
    func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lanes-test-\(UUID().uuidString)").appendingPathExtension("lanes")
    }

    func writeSample(to url: URL) throws {
        var w = SnapshotWriter()
        let (po, pl) = w.intern("/tmp/repo")
        let (no, nl) = w.intern("repo")
        let (ho, hl) = w.intern("main")
        let (fo, fl) = w.intern("fp-1")
        var meta = RecordBuilder(stride: Layout.Meta.stride)
        meta.put(po, at: Layout.Meta.repoPathOff); meta.put(pl, at: Layout.Meta.repoPathLen)
        meta.put(no, at: Layout.Meta.repoNameOff); meta.put(nl, at: Layout.Meta.repoNameLen)
        meta.put(ho, at: Layout.Meta.headOff); meta.put(hl, at: Layout.Meta.headLen)
        meta.put(fo, at: Layout.Meta.fingerprintOff); meta.put(fl, at: Layout.Meta.fingerprintLen)
        meta.put(Int64(1_700_000_000), at: Layout.Meta.builtAt)
        meta.put(UInt32(0), at: Layout.Meta.headCommit)
        w.set(.meta, Data(meta.bytes))

        var commits = Data()
        for i in 0..<3 {
            var c = RecordBuilder(stride: Layout.Commit.stride)
            c.put(Int64(1_700_000_000 - i * 3600), at: Layout.Commit.timestamp)
            c.put([UInt8](repeating: UInt8(i + 1), count: 20), at: Layout.Commit.oid)
            c.put(UInt32(i % 2), at: Layout.Commit.author)
            let (mo, ml) = w.intern("commit numéro \(i) — été")
            c.put(mo, at: Layout.Commit.messageOff); c.put(ml, at: Layout.Commit.messageLen)
            c.put(UInt8(i < 2 ? 1 : 0), at: Layout.Commit.parentCount)
            c.put(UInt8(0), at: Layout.Commit.lane)
            c.put(UInt32(i), at: Layout.Commit.parentStart)
            commits.append(contentsOf: c.bytes)
        }
        w.set(.commits, commits)
        var parents = Data()
        parents.appendLE(UInt32(1)); parents.appendLE(UInt32(2))
        w.set(.parents, parents)

        var authors = Data()
        for (name, email) in [("Ada", "ada@x.io"), ("Linus", "l@k.org")] {
            var a = RecordBuilder(stride: Layout.Author.stride)
            let (o, l) = w.intern(name); a.put(o, at: Layout.Author.nameOff); a.put(l, at: Layout.Author.nameLen)
            let (eo, el) = w.intern(email); a.put(eo, at: Layout.Author.emailOff); a.put(el, at: Layout.Author.emailLen)
            a.put(UInt32(2), at: Layout.Author.commits)
            a.put(Int64(1_600_000_000), at: Layout.Author.firstTs)
            a.put(UInt32(100_000_000), at: Layout.Author.lastTs)
            authors.append(contentsOf: a.bytes)
        }
        w.set(.authors, authors)
        try w.write(to: url)
    }

    @Test func roundTrip() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSample(to: url)
        let s = try Snapshot(contentsOf: url)
        #expect(s.meta.repoPath == "/tmp/repo")
        #expect(s.meta.repoName == "repo")
        #expect(s.meta.head == "main")
        #expect(s.meta.fingerprint == "fp-1")
        #expect(s.meta.headCommit == 0)
        #expect(s.commits.count == 3)
        #expect(s.message(1) == "commit numéro 1 — été")
        #expect(s.commits.shortHash(0) == "01010101")
        #expect(s.parentIndices(0) == [1])
        #expect(s.parentIndices(2) == [])
        #expect(s.authors.count == 2)
        #expect(s.authors.name(1) == "Linus")
        #expect(s.authors.lastTimestamp(0) == 1_700_000_000)
        #expect(s.refs.count == 0)          // section absente → vue vide, pas d'erreur
        #expect(s.health.isEmpty)
        #expect(s.edges.rows == 0)
    }

    @Test func rejectsBadMagic() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x41, count: 64).write(to: url)
        #expect(throws: SnapshotError.badMagic) { try Snapshot(contentsOf: url) }
    }

    @Test func rejectsTruncatedFile() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSample(to: url)
        let full = try Data(contentsOf: url)
        try full.prefix(full.count / 2).write(to: url)
        #expect(throws: (any Error).self) { try Snapshot(contentsOf: url) }
    }

    @Test func rejectsOtherVersion() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSample(to: url)
        var d = try Data(contentsOf: url)
        d[8] = 99
        try d.write(to: url)
        #expect(throws: SnapshotError.unsupportedVersion(99)) { try Snapshot(contentsOf: url) }
    }

    @Test func stringTableInterns() {
        var t = StringTable()
        let a = t.intern("hello"); let b = t.intern("hello"); let c = t.intern("world")
        #expect(a == b)
        #expect(c.offset == 5)
        #expect(t.blob.count == 10)
    }

    @Test func outOfRangeStringIsEmptyNotCrash() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSample(to: url)
        let s = try Snapshot(contentsOf: url)
        #expect(s.strings.string(offset: 10_000, length: 5) == "")
    }
}
