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
            url: "https://github.com/sym-bot/sym-swift/releases/download/v0.3.64/SYMCore.xcframework.zip",
            checksum: "4b61336a6ff3a5921cfed98303e219a8c95c0289d7046630cc833a8fd790a680"
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
