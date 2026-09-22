import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Shell
import Dashboard
import Glyph

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let bootstrapper = Bootstrapper()
    private let model = DashboardModel()
    private lazy var coordinator = RepoCoordinator(model: model)
    private var window: NSWindow!
    private var pendingOpen: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchMetrics.note("didFinishLaunching")
        if let mode = ProcessInfo.processInfo.environment["LANES_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        // 1. Quel dépôt ? Ligne de commande, sinon le dernier ouvert.
        let requested = Self.repoArgument(CommandLine.arguments.dropFirst()).map { ($0 as NSString).expandingTildeInPath } ?? Preferences.lastRepo

        // 2. Snapshot mappé : c'est tout ce que la première frame contient.
        var hadSnapshot = false
        if let requested { hadSnapshot = coordinator.openSnapshotIfAvailable(for: requested) }

        LaunchMetrics.note("snapshot ouvert (\(hadSnapshot))")
        // 3. Fenêtre.
        model.providers = AppProviders.make(window: { [weak self] in self?.window })
        buildMenu()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = false
        w.minSize = NSSize(width: 1120, height: 680)
        w.backgroundColor = NSColor.windowBackgroundColor
        w.tabbingMode = .disallowed
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.title = model.snapshot?.meta.repoName ?? "Lanes"
        coordinator.onTitleChange = { [weak w] name in w?.title = name }

        coordinator.refreshRepoList()
        let root = ContentHost(model: model, onOpen: { [weak self] in self?.openPanel() },
                               onDrop: { [weak self] path in self?.coordinator.open(path: path) },
                               onSelectRepo: { [weak self] path in self?.coordinator.open(path: path) },
                               onForgetRepo: { path in
                                   Preferences.forgetRecent(path)
                                   Preferences.discovered = Preferences.discovered.filter { $0 != path }
                               })
        LaunchMetrics.note("fenêtre créée")
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        w.contentView = hosting
        w.setFrameAutosaveName("LanesMain")
        if !w.setFrameUsingName("LanesMain") { w.center() }
        window = w
        LaunchMetrics.note("hosting posé")

        // Apparition : pas d'attente, juste un fondu court une fois la frame prête.
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        LaunchMetrics.note("orderFront")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            w.animator().alphaValue = 1
        }

        // 4. Phases. La première frame est commise au prochain tour de boucle.
        DispatchQueue.main.async { [self] in
            bootstrapper.advance(to: .firstFrame)
        }
        bootstrapper.schedule(.firstFrame) { [self] in
            coordinator.computeAnalytics { [self] in bootstrapper.advance(to: .interactive) }
            if !hadSnapshot { bootstrapper.advance(to: .interactive) }
        }
        bootstrapper.schedule(.interactive) { [self] in
            DispatchQueue.main.async { [self] in bootstrapper.advance(to: .warm) }
        }
        bootstrapper.schedule(.warm) { [self] in
            if let pendingOpen { coordinator.open(path: pendingOpen); self.pendingOpen = nil }
            else if let requested {
                if hadSnapshot {
                    model.lastVisit = Preferences.consumeLastVisit(for: requested)
                    Preferences.touchRecent(requested)
                    coordinator.warm(path: requested)
                } else {
                    coordinator.open(path: requested)
                }
            }
            coordinator.discoverAndPrebuild()
            if ProcessInfo.processInfo.environment["LANES_TEST_SHEET"] == "1" { model.showClone = true }
            if LaunchMetrics.isMeasuring {
                FileHandle.standardError.write(Data((LaunchMetrics.report() + "\n").utf8))
                if ProcessInfo.processInfo.environment["LANES_AUTOQUIT"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if bootstrapper.current >= .warm { coordinator.open(path: url.path) } else { pendingOpen = url.path }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Premier argument qui désigne un dépôt. Les paires `-Clé valeur` du
    /// domaine d'arguments (`-AppleLanguages '(fr)'`, `-NSDocumentRevisionsDebugMode YES`…)
    /// sont sautées en entier : leur valeur n'est pas un chemin.
    static func repoArgument(_ args: ArraySlice<String>) -> String? {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("-psn_") { continue }
            if a.hasPrefix("-") { _ = it.next(); continue }
            return a
        }
        return nil
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Lanes"), action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Lanes"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Lanes"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: String(localized: "File"))
        file.addItem(withTitle: String(localized: "Open Repository…"), action: #selector(openPanelAction), keyEquivalent: "o")
        let cloneItem = NSMenuItem(title: String(localized: "Clone Repository…"), action: #selector(cloneAction), keyEquivalent: "O")
        cloneItem.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(cloneItem)
        let recentItem = NSMenuItem(title: String(localized: "Recent Repositories"), action: nil, keyEquivalent: "")
        let recent = NSMenu(title: String(localized: "Recent Repositories"))
        for path in Preferences.recents {
            let item = NSMenuItem(title: path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            recent.addItem(item)
        }
        recentItem.submenu = recent
        file.addItem(recentItem)
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Next Repository"), action: #selector(nextRepo), keyEquivalent: "]")
        file.addItem(withTitle: String(localized: "Previous Repository"), action: #selector(previousRepo), keyEquivalent: "[")
        let goItem = NSMenuItem(title: String(localized: "Go to Repository"), action: nil, keyEquivalent: "")
        let go = NSMenu(title: String(localized: "Go to Repository"))
        for i in 1...9 {
            let item = NSMenuItem(title: String(localized: "Repository \(i)"), action: #selector(selectRepoNumber(_:)), keyEquivalent: "\(i)")
            item.tag = i - 1
            go.addItem(item)
        }
        goItem.submenu = go
        file.addItem(goItem)
        file.addItem(withTitle: String(localized: "Find Repositories on This Mac"), action: #selector(rediscover), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Open in Finder"), action: #selector(revealInFinder), keyEquivalent: "R")
        file.addItem(withTitle: String(localized: "Open in Terminal"), action: #selector(openTerminal), keyEquivalent: "T")
        for (i, e) in model.providers.editors.enumerated() {
            let item = NSMenuItem(title: String(localized: "Open in \(e.name)"), action: #selector(openEditor(_:)), keyEquivalent: i == 0 ? "E" : "")
            item.tag = i
            file.addItem(item)
        }
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Rebuild Snapshot"), action: #selector(rebuild), keyEquivalent: "r")
        file.addItem(.separator())
        file.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Filter"), action: #selector(focusFilter), keyEquivalent: "f")
        editItem.submenu = edit

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func about() {
        let report = LaunchMetrics.report()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Lanes",
            .credits: NSAttributedString(string: String(localized: "Read-only Git dashboard.\nLaunch:\n\(report)"), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]),
        ])
    }

    @objc private func openPanelAction() { openPanel() }
    @objc private func cloneAction() { model.showClone = true }
    @objc private func revealInFinder() { if let p = model.currentRepoPath { model.providers.openInFinder(p) } }
    @objc private func openTerminal() { if let p = model.currentRepoPath { model.providers.openInTerminal(p) } }
    @objc private func openEditor(_ sender: NSMenuItem) {
        guard let p = model.currentRepoPath, sender.tag < model.providers.editors.count else { return }
        model.providers.openInEditor(p, model.providers.editors[sender.tag])
    }
    @objc private func nextRepo() { coordinator.cycle(+1) }
    @objc private func previousRepo() { coordinator.cycle(-1) }
    @objc private func selectRepoNumber(_ sender: NSMenuItem) {
        guard sender.tag < model.repos.count else { return }
        coordinator.open(path: model.repos[sender.tag].path)
    }
    @objc private func rediscover() { coordinator.discoverAndPrebuild(force: true) }
    @objc private func focusFilter() { NotificationCenter.default.post(name: .lanesFocusFilter, object: nil) }

    @objc private func rebuild() {
        guard let path = model.snapshot?.meta.repoPath ?? Preferences.lastRepo else { return }
        coordinator.store.remove(forRepo: path)
        coordinator.open(path: path)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        coordinator.open(path: path)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder containing a Git repository")
        panel.prompt = String(localized: "Open")
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.coordinator.open(path: url.path)
            self?.buildMenu()
        }
    }
}

extension Notification.Name {
    static let lanesFocusFilter = Notification.Name("app.lanes.focusFilter")
}

/// Hôte SwiftUI : thème, glisser-déposer de dossiers, focus du filtre.
struct ContentHost: View {
    let model: DashboardModel
    let onOpen: () -> Void
    let onDrop: (String) -> Void
    let onSelectRepo: (String) -> Void
    let onForgetRepo: (String) -> Void
    @State private var targeted = false

    var body: some View {
        RootView(model: model, onOpen: onOpen, onSelectRepo: onSelectRepo, onForgetRepo: onForgetRepo)
            .glyphTheme(.default)
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in onDrop(url.path) }
                }
                return true
            }
            .overlay {
                if targeted {
                    Rectangle().stroke(GlyphTheme.default.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(6)
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 1120, minHeight: 680)
    }
}
