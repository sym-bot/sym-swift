// swift-tools-version: 5.9
// SYM Swift — add your iOS/macOS app to the mesh
// Copyright (c) 2026 SYM.BOT Ltd. Apache 2.0 License.

import PackageDescription

let package = Package(
    name: "SYM",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SYM",
            targets: ["SYM"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "SYMCore",
            url: "https://github.com/sym-bot/sym-swift/releases/download/v0.3.78/SYMCore.xcframework.zip",
            checksum: "30099e05541ba019e4d7d361c4c15beeef0df1dcdba902567ea7ac705255da93"
        ),
        .target(
            name: "SYM",
            dependencies: ["SYMCore"],
            path: "Sources/SYM"
        ),
        .testTarget(
            name: "SYMTests",
            dependencies: ["SYM"],
            path: "Tests/SYMTests"
        ),
    ]
)
