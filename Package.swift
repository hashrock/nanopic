// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nanopic",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Nanopic", targets: ["Nanopic"]),
        // iPad 版（App Store で配る）が使う。エージェント連携は入れない
        .library(name: "NanopicKit", targets: ["NanopicCore", "NanopicUI"]),
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
        // Mac 版と iPad 版で共有する表示部品（Metal の表示、色の選択、スライダー）
        .target(
            name: "NanopicUI",
            dependencies: ["NanopicCore"]
        ),
        .executableTarget(
            name: "Nanopic",
            dependencies: ["NanopicCore", "NanopicAgent", "NanopicUI"]
        ),
        .testTarget(
            name: "NanopicCoreTests",
            dependencies: ["NanopicCore", "NanopicAgent"]
        ),
    ]
)
