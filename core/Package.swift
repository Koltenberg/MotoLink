// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MotoLinkCore",
    products: [.library(name: "MotoLinkCore", targets: ["MotoLinkCore"])],
    targets: [
        .target(name: "MotoLinkCore", path: ".", exclude: ["Tests"], sources: ["MotoProtocol.swift"]),
        .testTarget(name: "MotoLinkCoreTests", dependencies: ["MotoLinkCore"], path: "Tests")
    ]
)
