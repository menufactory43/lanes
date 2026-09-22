import AppKit
import Dashboard
import GitExtract
import Sync

/// Implémentation concrète des contrats du dashboard : git à la demande,
/// NSWorkspace, réseau GitHub, clonage.
@MainActor
enum AppProviders {
    static func make(window: @escaping @MainActor () -> NSWindow?) -> DashboardProviders {
        let editors = detectEditors()
        return DashboardProviders(
            commitFiles: { repo, hash in
                try await Task.detached(priority: .userInitiated) {
                    try CommitInspector.files(repoPath: repo, hash: hash).map {
                        CommitFileEntry(path: $0.path, added: $0.added, deleted: $0.deleted, status: $0.status)
                    }
                }.value
            },
            openInFinder: { path in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            },
            openInTerminal: { path in
                let apps = ["Ghostty", "iTerm", "Warp", "Terminal"]
                for name in apps {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(for: name)) ?? appURL(named: name) {
                        let cfg = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: url, configuration: cfg)
                        return
                    }
                }
            },
            openInEditor: { path, editor in
                guard let url = appURL(named: editor.name) else { return }
                NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
            },
            editors: editors,
            searchRemote: { q in
                try await GitHubSearch.search(q).map {
                    RemoteRepo(fullName: $0.fullName, description: $0.description, stars: $0.stars, language: $0.language, cloneURL: $0.cloneURL)
                }
            },
            normalizeCloneInput: { Cloner.normalize($0) },
            clone: { url, dir, progress in
                try await Task.detached(priority: .userInitiated) {
                    try Cloner.clone(url: url, into: dir, progress: progress)
                }.value
            },
            chooseDirectory: { current in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                panel.directoryURL = current
                panel.prompt = String(localized: "Clone Here")
                guard let w = window() else { return nil }
                let resp = await panel.beginSheetModal(for: w)
                guard resp == .OK, let url = panel.url else { return nil }
                Preferences.cloneDirectory = url
                return url
            },
            defaultCloneDirectory: Preferences.cloneDirectory
        )
    }

    static func bundleID(for name: String) -> String {
        switch name {
        case "Terminal": return "com.apple.Terminal"
        case "iTerm": return "com.googlecode.iterm2"
        case "Warp": return "dev.warp.Warp-Stable"
        case "Ghostty": return "com.mitchellh.ghostty"
        default: return ""
        }
    }

    static func appURL(named name: String) -> URL? {
        for dir in ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func detectEditors() -> [EditorApp] {
        ["Cursor", "Visual Studio Code", "Zed", "Sublime Text", "Nova", "Xcode"].compactMap { appURL(named: $0) != nil ? EditorApp(name: $0) : nil }
    }
}
