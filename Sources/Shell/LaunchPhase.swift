/// Les phases d'un lancement, dans l'ordre. Une tâche déclarée pour une phase
/// ne peut pas s'exécuter avant que cette phase soit atteinte.
public enum LaunchPhase: Int, Comparable, Sendable, CaseIterable {
    /// Le processus existe, rien n'est encore à l'écran.
    case processStart
    /// La fenêtre est visible avec tout son contenu issu du snapshot.
    case firstFrame
    /// Les statistiques dérivées sont là ; l'utilisateur peut tout faire.
    case interactive
    /// Travail de fond : vérification du dépôt, reconstruction, surveillance.
    case warm

    public static func < (lhs: LaunchPhase, rhs: LaunchPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}
