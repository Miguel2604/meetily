// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeetyKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Audio", targets: ["Audio"]),
        .library(name: "Transcription", targets: ["Transcription"]),
        .library(name: "Summary", targets: ["Summary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: approachable([
        .target(name: "Core", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Resources/migrations")]),
        .target(name: "Audio", dependencies: ["Core"]),
        .target(name: "Transcription", dependencies: ["Core", "Audio", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "Summary", dependencies: ["Core"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "AudioTests", dependencies: ["Audio"]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"]),
        .testTarget(name: "SummaryTests", dependencies: ["Summary"]),
    ])
)

/// Approachable concurrency: nonisolated async functions run on the caller's actor unless `@concurrent`.
func approachable(_ targets: [Target]) -> [Target] {
    for target in targets {
        target.swiftSettings = (target.swiftSettings ?? []) + [
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
        ]
    }
    return targets
}
