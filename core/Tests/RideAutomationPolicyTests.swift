import XCTest
@testable import MotoLinkCore

final class RideAutomationPolicyTests: XCTestCase {
    func testBluetoothTransportAloneDoesNotStartCapture() {
        let policy = RideAutomationPolicy()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testReadyChannelsStartWithoutAnyGPSDependency() {
        var policy = RideAutomationPolicy()
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        XCTAssertFalse(policy.shouldStart(enabled: false, hasActiveRide: false, finishing: false))
    }

    func testReconnectKeepsExistingRideRatherThanStartingAnother() {
        var policy = RideAutomationPolicy()
        policy.channelsBecameReady()
        policy.transportDisconnected()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
    }

    func testRestoredRideIsNeverReplaced() {
        var restoredPolicy = RideAutomationPolicy()
        restoredPolicy.channelsBecameReady()
        XCTAssertFalse(restoredPolicy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
    }

    func testAsynchronousSaveCannotStartAnotherRide() {
        var policy = RideAutomationPolicy()
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: true))
        policy.rideFinished(transportConnected: true)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testManualFinishSuppressesSameConnectionButNotNextConnection() {
        var policy = RideAutomationPolicy()
        policy.channelsBecameReady()
        policy.rideFinished(transportConnected: true)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.transportDisconnected()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testFinishWhileDisconnectedAllowsNextReadyConnection() {
        var policy = RideAutomationPolicy()
        policy.rideFinished(transportConnected: false)
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testExplicitlyReenablingAutoRecordingRearmsCurrentConnection() {
        var policy = RideAutomationPolicy()
        policy.channelsBecameReady()
        policy.rideFinished(transportConnected: true)
        policy.userEnabledAutomaticRecording()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }
}
