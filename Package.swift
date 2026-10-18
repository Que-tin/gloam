// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Gloam",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Gloam", targets: ["Gloam"]),
    ],
    targets: [
        // Pure, AppKit-free logic: colour science, sun position, the schedule curve.
        // Deliberately nonisolated so tests and callers aren't tied to the main actor.
        .target(name: "GloamCore"),
        // The menu-bar app: display engines, model, SwiftUI. Everything here touches
        // AppKit or UI state, so the main actor is the default.
        .executableTarget(
            name: "Gloam",
            dependencies: ["GloamCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "GloamCoreTests", dependencies: ["GloamCore"]),
    ]
)
