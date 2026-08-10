// swift-tools-version: 5.9
// SYM Swift — add your iOS/macOS app to the mesh
// Copyright (c) 2026 SYM.BOT. Apache 2.0 License.

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
            url: "https://github.com/sym-bot/sym-swift/releases/download/v0.3.94/SYMCore.xcframework.zip",
            checksum: "534303901a46ff51d38dad5622a6b0cd60347a81c852c0376dc83b6a568d843e"
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
