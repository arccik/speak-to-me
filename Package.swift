// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpeakToMe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.33.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpeakToMe",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLinalg", package: "mlx-swift"),
                "ObjCSupport",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "ObjCSupport"),
    ]
)
