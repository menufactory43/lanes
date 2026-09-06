import Foundation
import Testing
import Snapshot
@testable import Analytics

@Suite struct AnalyticsTests {
    /// Snapshot synthétique : 10 commits sur 10 jours, 2 auteurs, 3 fichiers.
    func makeSnapshot(now: Date) throws -> Snapshot {
        var w = SnapshotWriter()
        var meta = RecordBuilder(stride: Layout.Meta.stride)
        let (o, l) = w.intern("/r"); meta.put(o, at: Layout.Meta.repoPathOff); meta.put(l, at: Layout.Meta.repoPathLen)
        meta.put(UInt32(0), at: Layout.Meta.headCommit)
        w.set(.meta, Data(meta.bytes))
        var commits = Data(), parents = Data()
        let base = Int64(now.timeIntervalSince1970)
        for i in 0..<10 {
            var c = RecordBuilder(stride: Layout.Commit.stride)
            c.put(base - Int64(i) * 86_400 - 3600, at: Layout.Commit.timestamp)
            c.put([UInt8](repeating: UInt8(i), count: 20), at: Layout.Commit.oid)
            c.put(UInt32(i % 3 == 0 ? 1 : 0), at: Layout.Commit.author)
            let (mo, ml) = w.intern("c\(i)"); c.put(mo, at: Layout.Commit.messageOff); c.put(ml, at: Layout.Commit.messageLen)
            c.put(UInt8(i < 9 ? 1 : 0), at: Layout.Commit.parentCount)
            c.put(UInt32(i), at: Layout.Commit.parentStart)
            commits.append(contentsOf: c.bytes)
            if i < 9 { parents.appendLE(UInt32(i + 1)) }
        }
        w.set(.commits, commits); w.set(.parents, parents)
        var authors = Data()
        for (name, count) in [("Ada", 6), ("Linus", 4)] {
            var a = RecordBuilder(stride: Layout.Author.stride)
            let (no, nl) = w.intern(name); a.put(no, at: Layout.Author.nameOff); a.put(nl, at: Layout.Author.nameLen)
            a.put(UInt32(count), at: Layout.Author.commits)
            a.put(base - 10 * 86_400, at: Layout.Author.firstTs); a.put(UInt32(10 * 86_400), at: Layout.Author.lastTs)
            authors.append(contentsOf: a.bytes)
        }
        w.set(.authors, authors)
        var files = Data()
        for (path, changes) in [("src/a.swift", 5), ("src/b.swift", 2), ("README.md", 1)] {
            var f = RecordBuilder(stride: Layout.File.stride)
            let (po, pl) = w.intern(path); f.put(po, at: Layout.File.pathOff); f.put(pl, at: Layout.File.pathLen)
            f.put(UInt32(changes), at: Layout.File.changes); f.put(UInt32(0), at: Layout.File.topAuthor)
            f.put(UInt64(100), at: Layout.File.size)
            files.append(contentsOf: f.bytes)
        }
        w.set(.files, files)
        var changes = Data()
        for (file, daysAgo) in [(0, 0), (0, 1), (0, 2), (0, 5), (0, 8), (1, 1), (1, 6), (2, 3)] {
            var c = RecordBuilder(stride: Layout.Change.stride)
            c.put(UInt32(file), at: Layout.Change.file); c.put(UInt32(0), at: Layout.Change.author)
            c.put(base - Int64(daysAgo) * 86_400 - 3600, at: Layout.Change.timestamp); c.put(UInt32(daysAgo), at: Layout.Change.commit)
            changes.append(contentsOf: c.bytes)
        }
        w.set(.changes, changes)
        var refs = Data()
        for (name, kind, flags, commit) in [("main", RefKind.localBranch, RefFlags.isHead, 0), ("v1", .tag, 0, 5), ("old", .localBranch, RefFlags.stale | RefFlags.unmerged, 9)] {
            var r = RecordBuilder(stride: Layout.Ref.stride)
            let (no, nl) = w.intern(name); r.put(no, at: Layout.Ref.nameOff); r.put(nl, at: Layout.Ref.nameLen)
            r.put(kind.rawValue, at: Layout.Ref.kind); r.put(flags, at: Layout.Ref.flags); r.put(UInt32(commit), at: Layout.Ref.commit)
            refs.append(contentsOf: r.bytes)
        }
        w.set(.refs, refs)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("an-\(UUID()).lanes")
        try w.write(to: url)
        return try Snapshot(contentsOf: url)
    }

    @Test func derivesEverything() throws {
        let now = Date()
        let s = try makeSnapshot(now: now)
        let a = Analytics(snapshot: s, lastVisit: now.addingTimeInterval(-3 * 86_400 - 1800), now: now)

        #expect(a.calendar.total == 10)
        #expect(a.calendar.maxPerDay == 1)
        #expect(a.calendar.currentStreak == 10)
        #expect(a.calendar.levels.count == 53 * 7)
        #expect(a.calendar.levels.compactMap { $0 }.filter { $0 > 0 }.count == 10)

        #expect(a.authors.map(\.name) == ["Ada", "Linus"])
        #expect(abs(a.authors[0].share - 0.6) < 0.001)
        #expect(a.authors[0].recent == 6)

        #expect(a.clock.counts.reduce(0, +) == 10)
        #expect(a.hotFiles.first?.path == "src/a.swift")
        #expect(a.directories.first?.path == "src/")
        #expect(a.directories.first?.changes == 7)
        #expect(abs(a.directories.first!.share - 7.0 / 8.0) < 0.001)
        #expect(a.directories.first?.owner == "Ada")

        #expect(a.refsByCommit[0]?.first?.name == "main")
        #expect(a.refsByCommit[0]?.first?.isHead == true)
        #expect(a.staleBranches == ["old"])
        #expect(a.unmergedBranches == ["old"])

        // Depuis la visite d'il y a ~3 jours : commits à 1 h, 1 j+1 h, 2 j+1 h → 3 commits
        #expect(a.sinceLastVisit.commits == 3)
        #expect(a.sinceLastVisit.authors == ["Ada", "Linus"])
        #expect(a.sinceLastVisit.files.first?.path == "src/a.swift")
        #expect(a.sinceLastVisit.files.first?.changes == 3)
        #expect(a.river.series.count == 3) // 2 auteurs + autres
        #expect(a.firstCommit != nil && a.lastCommit != nil)
    }

    @Test func handlesEmptySnapshot() throws {
        var w = SnapshotWriter()
        var meta = RecordBuilder(stride: Layout.Meta.stride); meta.put(noIndex, at: Layout.Meta.headCommit)
        w.set(.meta, Data(meta.bytes)); w.set(.commits, Data())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID()).lanes")
        try w.write(to: url)
        let s = try Snapshot(contentsOf: url)
        let a = Analytics(snapshot: s, lastVisit: nil)
        #expect(a.calendar.total == 0)
        #expect(a.authors.isEmpty)
        #expect(a.clock.peak == nil)
        #expect(a.firstCommit == nil)
    }

    @Test func topDirectory() {
        #expect(Analytics.topDirectory("src/a/b.swift") == "src/")
        #expect(Analytics.topDirectory("README.md") == "./")
    }
}
