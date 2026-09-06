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
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let requested = args.first.map { ($0 as NSString).expandingTildeInPath } ?? Preferences.lastRepo

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

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos de Lanes", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Masquer Lanes", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Lanes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "Fichier")
        file.addItem(withTitle: "Ouvrir un dépôt…", action: #selector(openPanelAction), keyEquivalent: "o")
        let cloneItem = NSMenuItem(title: "Cloner un dépôt…", action: #selector(cloneAction), keyEquivalent: "O")
        cloneItem.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(cloneItem)
        let recentItem = NSMenuItem(title: "Dépôts récents", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Dépôts récents")
        for path in Preferences.recents {
            let item = NSMenuItem(title: path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            recent.addItem(item)
        }
        recentItem.submenu = recent
        file.addItem(recentItem)
        file.addItem(.separator())
        file.addItem(withTitle: "Dépôt suivant", action: #selector(nextRepo), keyEquivalent: "]")
        file.addItem(withTitle: "Dépôt précédent", action: #selector(previousRepo), keyEquivalent: "[")
        let goItem = NSMenuItem(title: "Aller au dépôt", action: nil, keyEquivalent: "")
        let go = NSMenu(title: "Aller au dépôt")
        for i in 1...9 {
            let item = NSMenuItem(title: "Dépôt \(i)", action: #selector(selectRepoNumber(_:)), keyEquivalent: "\(i)")
            item.tag = i - 1
            go.addItem(item)
        }
        goItem.submenu = go
        file.addItem(goItem)
        file.addItem(withTitle: "Chercher les dépôts de ce Mac", action: #selector(rediscover), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Ouvrir dans le Finder", action: #selector(revealInFinder), keyEquivalent: "R")
        file.addItem(withTitle: "Ouvrir dans le Terminal", action: #selector(openTerminal), keyEquivalent: "T")
        for (i, e) in model.providers.editors.enumerated() {
            let item = NSMenuItem(title: "Ouvrir dans \(e.name)", action: #selector(openEditor(_:)), keyEquivalent: i == 0 ? "E" : "")
            item.tag = i
            file.addItem(item)
        }
        file.addItem(.separator())
        file.addItem(withTitle: "Reconstruire le snapshot", action: #selector(rebuild), keyEquivalent: "r")
        file.addItem(.separator())
        file.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Filtrer", action: #selector(focusFilter), keyEquivalent: "f")
        editItem.submenu = edit

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func about() {
        let report = LaunchMetrics.report()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Lanes",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(string: "Tableau de bord Git en lecture seule.\nLancement :\n\(report)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]),
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
        panel.message = "Choisis un dossier contenant un dépôt Git"
        panel.prompt = "Ouvrir"
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
