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
        .executableTarget(
            name: "Nanopic",
            dependencies: ["NanopicCore"]
        ),
        .testTarget(
            name: "NanopicCoreTests",
            dependencies: ["NanopicCore"]
        ),
    ]
)
