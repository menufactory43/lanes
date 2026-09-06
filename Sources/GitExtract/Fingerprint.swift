import Foundation
import CryptoKit

/// Empreinte de l'état d'un dépôt : si elle change, le snapshot est périmé.
/// Couvre HEAD, toutes les références, et l'index (arbre de travail indexé).
/// Coût : une invocation de `for-each-ref` et deux `stat`, quelques millisecondes.
public enum Fingerprint {
    public static func compute(repo: RepoInfo) -> String {
        let runner = GitRunner(repoPath: repo.topLevel)
        var h = SHA256()
        let head = (try? runner.string(["rev-parse", "HEAD"], allowFailure: true)) ?? ""
        h.update(data: Data(head.utf8))
        let symbolic = (try? runner.string(["symbolic-ref", "-q", "HEAD"], allowFailure: true)) ?? ""
        h.update(data: Data(symbolic.utf8))
        let refs = (try? runner.run(["for-each-ref", "--format=%(refname) %(objectname)"], allowFailure: true)) ?? Data()
        h.update(data: refs)
        for file in ["index", "MERGE_HEAD", "REBASE_HEAD"] {
            let url = URL(fileURLWithPath: repo.gitDir).appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let m = attrs[.modificationDate] as? Date, let s = attrs[.size] as? NSNumber {
                h.update(data: Data("\(file):\(m.timeIntervalSince1970):\(s)".utf8))
            }
        }
        // L'arbre de travail : on hache la sortie de status, bornée. Coûte
        // quelques dizaines de ms sur un gros dépôt, hors chemin critique.
        let status = (try? runner.run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"], allowFailure: true)) ?? Data()
        h.update(data: status.prefix(1 << 20))
        return h.finalize().map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
