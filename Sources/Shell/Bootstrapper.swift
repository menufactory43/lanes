import Foundation

/// Ordonnance les tâches de lancement par phase. Une tâche enregistrée pour
/// une phase s'exécute quand `advance(to:)` atteint cette phase, jamais avant.
/// Tout tourne sur le main actor : les tâches lourdes doivent elles-mêmes
/// partir en arrière-plan (elles reçoivent la main, pas un thread).
@MainActor
public final class Bootstrapper {
    public typealias Task = @MainActor () -> Void

    private var tasks: [LaunchPhase: [Task]] = [:]
    private(set) public var current: LaunchPhase = .processStart

    public init() {}

    /// Enregistre `task` pour `phase`. Si la phase est déjà passée, la tâche
    /// s'exécute immédiatement : on ne perd jamais une tâche.
    public func schedule(_ phase: LaunchPhase, _ task: @escaping Task) {
        precondition(phase != .processStart, "rien ne se planifie avant la première frame")
        if phase <= current {
            task()
        } else {
            tasks[phase, default: []].append(task)
        }
    }

    /// Avance jusqu'à `phase` en exécutant, dans l'ordre, les tâches de chaque
    /// phase traversée. Marque les métriques.
    public func advance(to phase: LaunchPhase) {
        guard phase > current else { return }
        for p in LaunchPhase.allCases where p > current && p <= phase {
            current = p
            LaunchMetrics.mark(p)
            let batch = tasks.removeValue(forKey: p) ?? []
            for task in batch { task() }
        }
    }
}
