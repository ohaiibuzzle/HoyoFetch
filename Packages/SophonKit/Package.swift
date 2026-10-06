// swift-tools-version:6.0
import PackageDescription

let swiftLint = Target.PluginUsage.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")

let package = Package(
    name: "SophonKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SophonKit", targets: ["SophonKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7"),
        .package(url: "https://github.com/ohaiibuzzle/hdiffswift.git", branch: "senpai"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins.git", from: "0.65.1"),
    ],
    targets: [
        .target(
            name: "SophonKit",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "libzstd", package: "zstd"),
                .product(name: "HPatch", package: "hdiffswift"),
            ],
            plugins: [swiftLint]
        ),
        .testTarget(
            name: "SophonKitTests",
            dependencies: ["SophonKit"],
            plugins: [swiftLint]
        ),
    ]
)
