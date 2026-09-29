// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NowBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared models and service contracts (Foundation only).
        .target(name: "NowBarCore"),
        // macOS integrations: Apple Music bridge, system volume, media keys.
        .target(name: "NowBarServices", dependencies: ["NowBarCore"]),
        // SwiftUI panel, menu bar label, observable store and settings.
        .target(name: "NowBarUI", dependencies: ["NowBarCore"]),
        // The menu bar app: wires the services into the UI.
        .executableTarget(name: "NowBar", dependencies: ["NowBarCore", "NowBarServices", "NowBarUI"]),
        // Renders the panel to PNGs for visual checks: `swift run NowBarSnapshots <output-dir>`.
        .executableTarget(name: "NowBarSnapshots", dependencies: ["NowBarCore", "NowBarUI"], path: "Tools/NowBarSnapshots"),
        .testTarget(name: "NowBarCoreTests", dependencies: ["NowBarCore"]),
        .testTarget(name: "NowBarServicesTests", dependencies: ["NowBarServices"]),
        .testTarget(name: "NowBarUITests", dependencies: ["NowBarUI"]),
    ],
    swiftLanguageModes: [.v5]
)
