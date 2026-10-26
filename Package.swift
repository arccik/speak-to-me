// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpeakToMe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpeakToMe",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "ObjCSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "ObjCSupport"),
    ]
)
