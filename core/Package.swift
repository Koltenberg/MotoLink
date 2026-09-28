// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MotoLinkCore",
    platforms: [.macOS(.v11), .iOS(.v16)],
    products: [.library(name: "MotoLinkCore", targets: ["MotoLinkCore"])],
    targets: [
        .target(name: "MotoLinkCore", path: ".", exclude: ["Tests"], sources: ["MotoProtocol.swift", "BLEStreamRecovery.swift", "BLEGATTRecoveryPolicy.swift", "JournalCheckpointPolicy.swift", "BLEReconnectScheduler.swift", "RideDataQuality.swift", "RideArchiveFiles.swift", "TelemetryPresentation.swift", "MotorcycleCompanion.swift", "RideAutomationPolicy.swift", "BLECancelResumePolicy.swift", "BLENativeReconnectPolicy.swift", "BLEDiscoverySelection.swift"]),
        .testTarget(name: "MotoLinkCoreTests", dependencies: ["MotoLinkCore"], path: "Tests")
    ]
)
