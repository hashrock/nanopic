// swift-tools-version:5.10
import Foundation
import PackageDescription

// App Store 用ビルド（NANOPIC_APPSTORE=1）では、エージェント連携（MCP）をコンパイルの段階で外す。
// アプリは NanopicAgent に依存せず、Sources/Nanopic/Agent（MCP サーバー・設定画面・アプリ側のツール）も入れない。
// 残りのコードは `#if !APPSTORE` で分ける。作り方は scripts/build-appstore.sh
let appStore = ProcessInfo.processInfo.environment["NANOPIC_APPSTORE"] == "1"

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
            dependencies: appStore ? ["NanopicCore", "NanopicUI"] : ["NanopicCore", "NanopicAgent", "NanopicUI"],
            exclude: appStore ? ["Agent"] : [],
            swiftSettings: appStore ? [.define("APPSTORE")] : []
        ),
        .testTarget(
            name: "NanopicCoreTests",
            dependencies: ["NanopicCore", "NanopicAgent"]
        ),
    ]
)
