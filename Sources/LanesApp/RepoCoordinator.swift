import AppKit
import Shell
import Snapshot
import GitExtract
import Analytics
import Dashboard
import Sync

/// Orchestre l'ouverture d'un dépôt : snapshot mappé d'abord, analytics ensuite,
/// vérification d'empreinte et reconstruction en fond, surveillance FSEvents.
@MainActor
final class RepoCoordinator {
    let model: DashboardModel
    let store = SnapshotStore.default
    private var repo: RepoInfo?
    private var watcher: RepoWatcher?
    private var buildTask: Task<Void, Never>?
    private var analyticsGeneration = 0
    var onTitleChange: ((String) -> Void)?

    init(model: DashboardModel) { self.model = model }

    /// Phase `.processStart` : ouvre le snapshot du dernier dépôt s'il existe.
    /// Coût : un `mmap` et la lecture de l'en-tête. Aucun `git` ici.
    func openSnapshotIfAvailable(for path: String) -> Bool {
        guard let s = try? store.open(forRepo: path) else { return false }
        model.lastVisit = Preferences.peekLastVisit(for: path)
        model.replace(snapshot: s, analytics: nil)
        onTitleChange?(s.meta.repoName)
        return true
    }

    /// Phase `.interactive` : statistiques dérivées, hors du fil principal.
    func computeAnalytics(then completion: @escaping @MainActor () -> Void = {}) {
        guard let s = model.snapshot else { completion(); return }
        analyticsGeneration += 1
        let gen = analyticsGeneration
        let lastVisit = model.lastVisit
        Task.detached(priority: .userInitiated) {
            let a = Analytics(snapshot: s, lastVisit: lastVisit)
            await MainActor.run {
                guard gen == self.analyticsGeneration, self.model.snapshot === s else { return }
                self.model.setAnalytics(a)
                completion()
            }
        }
    }

    /// Phase `.warm` : localise le dépôt, compare l'empreinte, reconstruit si besoin, surveille.
    func warm(path: String) {
        Task.detached(priority: .utility) {
            let located = try? RepoInfo.locate(path)
            await MainActor.run { self.didLocate(located, requested: path) }
        }
    }

    /// Ouverture explicite (menu, glisser-déposer, ligne de commande).
    func open(path: String) {
        buildTask?.cancel()
        watcher?.stop(); watcher = nil
        model.errorMessage = nil
        model.building = .building(stage: "localisation", detail: "")
        Task.detached(priority: .userInitiated) {
            do {
                let info = try RepoInfo.locate(path)
                await MainActor.run {
                    Preferences.touchRecent(info.topLevel)
                    self.model.lastVisit = Preferences.consumeLastVisit(for: info.topLevel)
                    if let s = try? self.store.open(forRepo: info.topLevel) {
                        self.model.replace(snapshot: s, analytics: nil)
                        self.onTitleChange?(s.meta.repoName)
                        self.computeAnalytics()
                    } else {
                        self.model.replace(snapshot: nil, analytics: nil)
                        self.onTitleChange?(info.name)
                    }
                    self.model.building = .idle
                    self.didLocate(info, requested: path)
                }
            } catch {
                await MainActor.run {
                    self.model.building = .failed("pas un dépôt git : \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                }
            }
        }
    }

    private func didLocate(_ info: RepoInfo?, requested: String) {
        guard let info else {
            Preferences.forgetRecent(requested)
            if model.snapshot?.meta.repoPath == requested || model.snapshot == nil {
                model.building = .failed("le dépôt \(requested.replacingOccurrences(of: NSHomeDirectory(), with: "~")) n'est plus accessible")
            }
            return
        }
        repo = info
        if model.snapshot == nil || model.snapshot?.meta.repoPath != info.topLevel {
            if let s = try? store.open(forRepo: info.topLevel) {
                model.replace(snapshot: s, analytics: nil)
                onTitleChange?(s.meta.repoName)
                computeAnalytics()
            }
        }
        checkFingerprintAndRebuild()
        startWatching(info)
    }

    private func startWatching(_ info: RepoInfo) {
        watcher?.stop()
        let w = RepoWatcher(paths: [info.gitDir, info.topLevel]) { [weak self] in
            Task { @MainActor in self?.checkFingerprintAndRebuild() }
        }
        w.start()
        watcher = w
    }

    private func checkFingerprintAndRebuild() {
        guard let repo, buildTask == nil else { return }
        let current = model.snapshot?.meta.fingerprint
        let snapshotRepo = model.snapshot?.meta.repoPath
        let force = current == nil || snapshotRepo != repo.topLevel
        buildTask = Task.detached(priority: .utility) { [store] in
            let fp = Fingerprint.compute(repo: repo)
            if !force && fp == current {
                await MainActor.run { self.buildTask = nil; self.model.building = .idle }
                return
            }
            let progress: @Sendable (ExtractProgress) -> Void = { p in
                Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    self.model.building = .building(stage: p.stage.rawValue, detail: p.detail)
                }
            }
            do {
                let url = store.url(forRepo: repo.topLevel)
                try Extractor(repo: repo, progress: progress).build(to: url, fingerprint: fp)
                let s = try Snapshot(contentsOf: url)
                await MainActor.run {
                    self.buildTask = nil
                    guard self.repo?.topLevel == repo.topLevel else { return }
                    let keepSelection = self.model.selectedCommit.flatMap { i -> String? in
                        self.model.snapshot.map { $0.commits.fullHash(i) }
                    }
                    self.model.replace(snapshot: s, analytics: nil)
                    if let hash = keepSelection {
                        self.model.selectedCommit = (0..<s.commits.count).first { s.commits.fullHash($0) == hash }
                    }
                    self.onTitleChange?(s.meta.repoName)
                    self.model.building = .idle
                    self.computeAnalytics()
                    // L'empreinte peut avoir bougé pendant la construction : on revérifie une fois.
                    let after = Fingerprint.compute(repo: repo)
                    if after != fp { self.checkFingerprintAndRebuild() }
                }
            } catch {
                await MainActor.run {
                    self.buildTask = nil
                    self.model.building = .failed("\(error)")
                }
            }
        }
    }
}
