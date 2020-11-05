// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftDataLoader",
    platforms: [
       .macOS(.v10_15),
    ],
    products: [
        .library(name: "SwiftDataLoader", targets: ["SwiftDataLoader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.23.0"),
    ],
    targets: [
        .target(name: "SwiftDataLoader", dependencies: [
            .product(name: "NIO", package: "swift-nio"),
        ]),
        .testTarget(name: "SwiftDataLoaderTests", dependencies: ["SwiftDataLoader"]),
    ]
)
