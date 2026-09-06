// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lanes",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Lanes", targets: ["LanesApp"]),
    ],
    targets: [
        // Chemin critique : aucune dépendance interne.
        .target(name: "Shell"),

        // Format binaire mappé.
        .target(name: "Snapshot"),

        // Fonction pure : voies du graphe.
        .target(name: "GraphLayout"),

        // Travail lourd : git CLI → snapshot.
        .target(name: "GitExtract", dependencies: ["Snapshot", "GraphLayout"]),

        // Stats dérivées, calculées hors chemin critique.
        .target(name: "Analytics", dependencies: ["Snapshot"]),

        // Système de design monospace.
        .target(name: "Glyph"),

        // Widgets Git.
        .target(name: "Dashboard", dependencies: ["Snapshot", "Analytics", "Glyph"]),

        // Surveillance du dépôt.
        .target(name: "Sync", dependencies: ["GitExtract"]),

        .executableTarget(
            name: "LanesApp",
            dependencies: ["Shell", "Snapshot", "GitExtract", "Analytics", "Glyph", "Dashboard", "Sync"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),

        .testTarget(name: "SnapshotTests", dependencies: ["Snapshot"]),
        .testTarget(name: "GraphLayoutTests", dependencies: ["GraphLayout"]),
        .testTarget(name: "GitExtractTests", dependencies: ["GitExtract", "Snapshot"]),
        .testTarget(name: "AnalyticsTests", dependencies: ["Analytics", "Snapshot", "GitExtract"]),
    ],
    swiftLanguageModes: [.v6]
)
