import Foundation
import GitExtract
import Snapshot

import Sync

enum CommandLineBuild {
    static func search(query: String) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 0
        Task {
            do {
                let r = try await GitHubSearch.search(query)
                for x in r { print("\(x.fullName)  ★\(x.stars)  \(x.language ?? "")  \(x.cloneURL)") }
            } catch { FileHandle.standardError.write(Data("erreur: \(error.localizedDescription)\n".utf8)); code = 1 }
            sem.signal()
        }
        sem.wait()
        return code
    }

    static func run(path: String) -> Int32 {
        do {
            let t0 = Date()
            let repo = try RepoInfo.locate(path)
            let fp = Fingerprint.compute(repo: repo)
            let store = SnapshotStore.default
            let url = store.url(forRepo: repo.topLevel)
            FileHandle.standardError.write(Data("  localisation+empreinte \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".utf8))
            let n = try Extractor(repo: repo, progress: { p in
                FileHandle.standardError.write(Data("  \(p.stage.localizedName) \(p.detail)  @\(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".utf8))
            }).build(to: url, fingerprint: fp)
            let dt = Date().timeIntervalSince(t0)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            print("snapshot \(url.path)\n\(n) commits, \(size / 1024) Ko, \(String(format: "%.2f", dt)) s")
            let t1 = Date()
            let s = try Snapshot(contentsOf: url)
            print("ouverture mmap: \(String(format: "%.2f", Date().timeIntervalSince(t1) * 1000)) ms, \(s.commits.count) commits, head \(s.meta.head)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("erreur: \(error)\n".utf8))
            return 1
        }
    }
}
