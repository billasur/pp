// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PpDesktop",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "PpCore", targets: ["PpCore"]),
        .library(name: "PpMLX", targets: ["PpMLX"]),
        .executable(name: "PpDesktop", targets: ["PpDesktop"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.21.0")
    ],
    targets: [
        .target(
            name: "PpCore"
        ),
        .target(
            name: "PpMLX",
            dependencies: [
                "PpCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift")
            ]
        ),
        .executableTarget(
            name: "PpDesktop",
            dependencies: ["PpCore", "PpMLX"]
        ),
        .testTarget(
            name: "PpCoreTests",
            dependencies: ["PpCore"]
        ),
        .testTarget(
            name: "PpMLXTests",
            dependencies: ["PpMLX", "PpCore"]
        )
    ]
)
