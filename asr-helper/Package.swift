// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "asr-helper",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .executableTarget(
            name: "asr-helper",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
