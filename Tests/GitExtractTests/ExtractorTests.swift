import Foundation
import Testing
@testable import GitExtract
import Snapshot

final class StageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [ExtractStage] = []
    func add(_ s: ExtractStage) { lock.lock(); stages.append(s); lock.unlock() }
    var all: [ExtractStage] { lock.lock(); defer { lock.unlock() }; return stages }
}

/// Construit un vrai dépôt Git temporaire avec branches, fusion, tag et
/// modifications non indexées, puis vérifie le snapshot produit.
@Suite(.serialized) struct ExtractorTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lanes-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sh("git init -q -b main")
        try sh("git config user.name Ada && git config user.email ada@example.com")
        try write("README.md", "# Test\n")
        try sh("git add . && git -c commit.gpgsign=false commit -q -m 'initial commit' --date='2024-01-01T10:00:00'")
        try write("src/app.swift", "print(1)\n")
        try sh("git add . && git commit -q -m 'add app' --date='2024-01-02T11:00:00'")
        try sh("git checkout -q -b feature")
        try write("src/feature.swift", "// f\n")
        try sh("git add . && git -c user.name=Linus -c user.email=linus@example.com commit -q -m 'feature work' --date='2024-01-03T12:00:00'")
        try sh("git checkout -q main")
        try write("src/app.swift", "print(2)\n")
        try sh("git add . && git commit -q -m 'bump app' --date='2024-01-04T13:00:00'")
        try sh("git merge -q --no-ff -m 'merge feature' feature", fresh: true)
        try sh("git tag -a v1.0 -m 'release'")
        try sh("git checkout -q -b old-branch HEAD~3 && git checkout -q main")
        try write("src/app.swift", "print(3)\n")       // modifié, non indexé
        try write("notes.txt", "todo\n")                // non suivi
    }

    func sh(_ cmd: String, fresh: Bool = false) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "cd '\(dir.path)' && \(cmd)"]
        var env = ProcessInfo.processInfo.environment
        if !fresh { env["GIT_COMMITTER_DATE"] = "2024-01-05T09:00:00" }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Issue.record("commande échouée: \(cmd)\n\(e)")
        }
    }

    func write(_ rel: String, _ content: String) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func locatesRepoFromSubdirectory() throws {
        let info = try RepoInfo.locate(dir.appendingPathComponent("src").path)
        #expect(info.topLevel.hasSuffix(dir.lastPathComponent))
        #expect(info.name == dir.lastPathComponent)
    }

    @Test func buildsCompleteSnapshot() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = try RepoInfo.locate(dir.path)
        let fp = Fingerprint.compute(repo: info)
        #expect(fp.count == 32)
        let out = dir.appendingPathComponent("snap.lanes")
        let stages = StageBox()
        let n = try Extractor(repo: info, progress: { p in stages.add(p.stage) }).build(to: out, fingerprint: fp)
        #expect(n == 5)
        #expect(Set(stages.all).count == ExtractStage.allCases.count - 1) // .locate n'est pas émis par build

        let s = try Snapshot(contentsOf: out)
        #expect(s.meta.repoName == dir.lastPathComponent)
        #expect(s.meta.head == "main")
        #expect(s.meta.fingerprint == fp)
        #expect(s.meta.headCommit == 0)
        #expect(s.commits.count == 5)
        #expect(s.message(0) == "merge feature")
        #expect(s.commits.isMerge(0))
        #expect(s.commits.parentCount(0) == 2)
        #expect(s.message(4) == "initial commit")
        #expect(s.commits.parentCount(4) == 0)
        #expect(s.commits.timestamp(4) > 1_700_000_000)

        // Auteurs
        #expect(s.authors.count == 2)
        let names = (0..<s.authors.count).map { s.authors.name($0) }
        #expect(names.contains("Ada") && names.contains("Linus"))
        let ada = names.firstIndex(of: "Ada")!
        #expect(s.authors.commits(ada) == 4)

        // Références
        let refNames = (0..<s.refs.count).map { s.refs.name($0) }
        #expect(refNames.contains("main") && refNames.contains("feature") && refNames.contains("v1.0") && refNames.contains("old-branch"))
        let main = refNames.firstIndex(of: "main")!
        #expect(s.refs.flags(main) & RefFlags.isHead != 0)
        #expect(s.refs.commit(main) == 0)
        let tag = refNames.firstIndex(of: "v1.0")!
        #expect(s.refs.kind(tag) == .tag)
        #expect(s.refs.commit(tag) == 0)  // tag annoté résolu vers le commit
        let old = refNames.firstIndex(of: "old-branch")!
        #expect(s.refs.flags(old) & RefFlags.stale != 0)

        // Graphe : la fusion ouvre une seconde voie
        #expect(s.edges.rows == 5)
        #expect(s.edges.edges(row: 0).count == 2)
        #expect(s.edges.edges(row: 0).allSatisfy { $0.kind == .toParent })

        // État de travail
        #expect(s.health.modified == 1)
        #expect(s.health.untracked == 1)
        #expect(s.health.staged == 0)
        #expect(s.health.trackedFiles == 3)
        #expect(s.health.localBranches == 3)
        #expect(s.health.tags == 1)
        #expect(s.health.staleBranches == 2) // feature et old-branch datent de 2024, main vient d'être fusionnée
        let statusPaths = (0..<s.status.count).map { s.status.path($0) }
        #expect(statusPaths.contains("src/app.swift") && statusPaths.contains("notes.txt"))

        // Fichiers : tous datent de 2024, donc hors des 90 jours → seulement les plus gros
        #expect(s.files.count == 3)
        #expect(s.changes.count == 0)
        #expect(s.health.sizeBytes > 0)
    }

    @Test func fingerprintChangesWithWorkingTree() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = try RepoInfo.locate(dir.path)
        let a = Fingerprint.compute(repo: info)
        try write("another.txt", "x\n")
        let b = Fingerprint.compute(repo: info)
        #expect(a != b)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("another.txt"))
        #expect(Fingerprint.compute(repo: info) == a)
    }
}
