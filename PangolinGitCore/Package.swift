// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PangolinGitCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PangolinGitCore",
            targets: ["PangolinGitCore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PangolinGitCore",
            dependencies: [],
            path: "Sources/PangolinGitCore"
        ),
        .testTarget(
            name: "PangolinGitCoreTests",
            dependencies: ["PangolinGitCore"],
            path: "Tests/PangolinGitCoreTests"
        ),
    ]
)
