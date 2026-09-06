import AppKit
import Shell

// Point d'entrée AppKit : on garde la main sur l'ordre exact
// fenêtre → première frame → travail différé. Voir docs/DECISIONS.md, ADR-1.
LaunchMetrics.prime()
LaunchMetrics.mark(.processStart)

let arguments = Array(CommandLine.arguments.dropFirst())
if let i = arguments.firstIndex(of: "--build"), i + 1 < arguments.count {
    // Mode ligne de commande : construit un snapshot et sort. Sert aux mesures.
    exit(CommandLineBuild.run(path: arguments[i + 1]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
