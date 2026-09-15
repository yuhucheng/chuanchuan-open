// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShareHubPlatform",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ShareHubPlatform", targets: ["ShareHubPlatform"])],
    targets: [
        .target(name: "ShareHubPlatform"),
        .testTarget(name: "ShareHubPlatformTests", dependencies: ["ShareHubPlatform"])
    ]
)
