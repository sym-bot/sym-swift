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
        // SYMCore 0.3.95. The tag is namespaced because it hosts a binary artifact and is
        // not a sym-swift version — sym-swift's own releases stay on the v0.5.x line, and
        // a bare v0.3.95 tag here would read as a downgrade.
        .binaryTarget(
            name: "SYMCore",
            url: "https://github.com/sym-bot/sym-swift/releases/download/symcore-v0.3.95/SYMCore.xcframework.zip",
            checksum: "d4738c7bc70a91d034324ea11cb5560bb41e3f17f5e253ef4f95cc795b64e0fc"
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
