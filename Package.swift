// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unremarkable",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RMKit", targets: ["RMKit"]),
        .executable(name: "Unremarkable", targets: ["Unremarkable"]),
    ],
    targets: [
        // Platform core: reMarkable cloud (sync15), blob store, SQLite/FTS5 library,
        // .rm v6 parser, CoreGraphics renderer and AI providers. No UI.
        .target(
            name: "RMKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // SwiftUI macOS app.
        .executableTarget(
            name: "Unremarkable",
            dependencies: ["RMKit"]
        ),
        .testTarget(
            name: "RMKitTests",
            dependencies: ["RMKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
