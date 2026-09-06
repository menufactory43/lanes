import Foundation

/// Un fichier touché par un commit, tel que le dashboard l'affiche.
public struct CommitFileEntry: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let added: Int
    public let deleted: Int
    public let status: Character
    public var isBinary: Bool { added < 0 }
    public init(path: String, added: Int, deleted: Int, status: Character) {
        self.path = path; self.added = added; self.deleted = deleted; self.status = status
    }
}

public struct RemoteRepo: Sendable, Hashable, Identifiable {
    public var id: String { cloneURL }
    public let fullName: String
    public let description: String
    public let stars: Int
    public let language: String?
    public let cloneURL: String
    public init(fullName: String, description: String, stars: Int, language: String?, cloneURL: String) {
        self.fullName = fullName; self.description = description; self.stars = stars; self.language = language; self.cloneURL = cloneURL
    }
}

public struct EditorApp: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public init(name: String) { self.name = name }
}

/// Ce que l'app fournit au dashboard. Le dashboard ne sait pas comment c'est
/// fait (git, réseau, NSWorkspace) : il ne connaît que ces contrats.
public struct DashboardProviders: Sendable {
    public var commitFiles: @Sendable (_ repoPath: String, _ hash: String) async throws -> [CommitFileEntry]
    public var openInFinder: @MainActor (_ path: String) -> Void
    public var openInTerminal: @MainActor (_ path: String) -> Void
    public var openInEditor: @MainActor (_ path: String, _ editor: EditorApp) -> Void
    public var editors: [EditorApp]
    public var searchRemote: @Sendable (_ query: String) async throws -> [RemoteRepo]
    public var normalizeCloneInput: @Sendable (_ input: String) -> String?
    public var clone: @Sendable (_ url: String, _ into: URL, _ progress: @escaping @Sendable (String) -> Void) async throws -> String
    public var chooseDirectory: @MainActor (_ current: URL) async -> URL?
    public var defaultCloneDirectory: URL

    public init(commitFiles: @escaping @Sendable (String, String) async throws -> [CommitFileEntry],
                openInFinder: @escaping @MainActor (String) -> Void,
                openInTerminal: @escaping @MainActor (String) -> Void,
                openInEditor: @escaping @MainActor (String, EditorApp) -> Void,
                editors: [EditorApp],
                searchRemote: @escaping @Sendable (String) async throws -> [RemoteRepo],
                normalizeCloneInput: @escaping @Sendable (String) -> String?,
                clone: @escaping @Sendable (String, URL, @escaping @Sendable (String) -> Void) async throws -> String,
                chooseDirectory: @escaping @MainActor (URL) async -> URL?,
                defaultCloneDirectory: URL) {
        self.commitFiles = commitFiles; self.openInFinder = openInFinder; self.openInTerminal = openInTerminal
        self.openInEditor = openInEditor; self.editors = editors; self.searchRemote = searchRemote
        self.normalizeCloneInput = normalizeCloneInput; self.clone = clone; self.chooseDirectory = chooseDirectory
        self.defaultCloneDirectory = defaultCloneDirectory
    }

    /// Fournisseurs inertes, pour les aperçus et les tests.
    public static let none = DashboardProviders(
        commitFiles: { _, _ in [] }, openInFinder: { _ in }, openInTerminal: { _ in }, openInEditor: { _, _ in }, editors: [],
        searchRemote: { _ in [] }, normalizeCloneInput: { _ in nil }, clone: { _, _, _ in "" }, chooseDirectory: { _ in nil },
        defaultCloneDirectory: FileManager.default.homeDirectoryForCurrentUser)
}
