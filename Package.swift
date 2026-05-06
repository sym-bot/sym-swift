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
            url: "https://github.com/sym-bot/sym-swift/releases/download/v0.3.85/SYMCore.xcframework.zip",
            checksum: "de44078c6736c536bb9644e76ff6e73f9e4b069f0aff06d44ba7948c2cca5b53"
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
