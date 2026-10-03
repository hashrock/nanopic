// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nanopic",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nanopic", targets: ["Nanopic"]),
    ],
    targets: [
        .target(
            name: "NanopicCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        // エージェント（MCP）向けのツール。コアの描画とは独立しているので、別のモジュールにして並列にビルドする
        .target(
            name: "NanopicAgent",
            dependencies: ["NanopicCore"]
        ),
        .executableTarget(
            name: "Nanopic",
            dependencies: ["NanopicCore", "NanopicAgent"]
        ),
        .testTarget(
            name: "NanopicCoreTests",
            dependencies: ["NanopicCore", "NanopicAgent"]
        ),
    ]
)
