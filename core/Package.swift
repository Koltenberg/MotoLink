// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MotoLinkCore",
    platforms: [.macOS(.v11), .iOS(.v16)],
    products: [.library(name: "MotoLinkCore", targets: ["MotoLinkCore"])],
    targets: [
        .target(name: "MotoLinkCore", path: ".", exclude: ["Tests"], sources: ["MotoProtocol.swift", "BLEStreamRecovery.swift", "JournalCheckpointPolicy.swift"]),
        .testTarget(name: "MotoLinkCoreTests", dependencies: ["MotoLinkCore"], path: "Tests")
    ]
)
