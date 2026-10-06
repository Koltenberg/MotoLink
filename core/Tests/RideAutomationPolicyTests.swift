import Foundation
import XCTest
@testable import MotoLinkCore

final class RideAutomationPolicyTests: XCTestCase {
    private let bikeA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let bikeB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    func testAuthorizedMigrationEnablesBothOldOffSettingsAndClearsLegacyPauseOnce() {
        let suite = "MotoLink-AutomaticMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "MotoLink.autoReconnect")
        defaults.set(false, forKey: "MotoLink.autoRecord")
        defaults.set(true, forKey: "MotoLink.connectionPaused")
        defaults.set(bikeA.uuidString, forKey: "MotoLink.autoRecordFinishedPeripheral")
        XCTAssertTrue(AutomaticRideSettings.migrate(defaults))
        XCTAssertTrue(defaults.bool(forKey: "MotoLink.autoReconnect"))
        XCTAssertTrue(defaults.bool(forKey: "MotoLink.autoRecord"))
        XCTAssertFalse(defaults.bool(forKey: "MotoLink.connectionPaused"))
        XCTAssertEqual(defaults.string(forKey: "MotoLink.autoRecordFinishedPeripheral"), bikeA.uuidString)
        // A later explicit pause is not another old-toggle accident.
        defaults.set(true, forKey: "MotoLink.connectionPaused")
        XCTAssertFalse(AutomaticRideSettings.migrate(defaults))
        XCTAssertTrue(defaults.bool(forKey: "MotoLink.connectionPaused"))
        XCTAssertEqual(defaults.string(forKey: "MotoLink.autoRecordFinishedPeripheral"), bikeA.uuidString)
    }

    func testAutomaticProductModeStillRequiresAnIdentifiedReadyMotorcycle() {
        var policy = RideAutomationPolicy()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.observePeripheral(bikeA)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.userRequestedFinish(transportConnected: true)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.confirmedTransportBoundary(for: bikeA)
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testNewApplicationProcessResumesPausedBikeWithoutErasingFinishedRideMarker() {
        let suite = "MotoLink-AutomaticLaunch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        AutomaticRideSettings.prepareForLaunch(defaults)
        defaults.set(true, forKey: "MotoLink.connectionPaused")
        defaults.set(bikeA.uuidString, forKey: "MotoLink.autoRecordFinishedPeripheral")
        // The recorder may inspect migration again; this is not a new process.
        XCTAssertFalse(AutomaticRideSettings.migrate(defaults))
        XCTAssertTrue(defaults.bool(forKey: "MotoLink.connectionPaused"))
        // Only creating the Bluetooth owner for a new process resumes intent.
        AutomaticRideSettings.prepareForLaunch(defaults)
        XCTAssertFalse(defaults.bool(forKey: "MotoLink.connectionPaused"))
        XCTAssertEqual(defaults.string(forKey: "MotoLink.autoRecordFinishedPeripheral"), bikeA.uuidString)
        var restored = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        restored.observePeripheral(bikeA)
        restored.channelsBecameReady()
        XCTAssertFalse(restored.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testInPlaceRepairRestoresReadinessWithoutOverridingRecordingChoice() {
        var policy = RideAutomationPolicy()
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: false, hasActiveRide: false, finishing: false))
        // Same-link service discovery observes identity again. Its ready
        // callback must reach the recorder even though this is not firstReady.
        policy.observePeripheral(bikeA)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: false, hasActiveRide: false, finishing: false))
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
    }

    func testRepeatedReadinessAfterRepairDoesNotUndoManualFinish() {
        var policy = readyPolicy()
        policy.userRequestedFinish(transportConnected: true)
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        XCTAssertEqual(policy.stoppedPeripheralID, bikeA)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    private func readyPolicy() -> RideAutomationPolicy {
        var policy = RideAutomationPolicy()
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        return policy
    }

    func testBluetoothTransportAloneDoesNotStartCapture() {
        var policy = RideAutomationPolicy()
        policy.observePeripheral(bikeA)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testReadyChannelsNeedIdentifiedMotorcycle() {
        var policy = RideAutomationPolicy()
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testReadyChannelsStartWithoutAnyGPSDependency() {
        let policy = readyPolicy()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        XCTAssertFalse(policy.shouldStart(enabled: false, hasActiveRide: false, finishing: false))
    }

    func testReconnectKeepsExistingRideRatherThanStartingAnother() {
        var policy = readyPolicy()
        policy.confirmedTransportBoundary(for: bikeA)
        policy.transportDisconnected()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
        policy.confirmedTransportBoundary(for: bikeA)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
    }

    func testRestoredRideIsNeverReplaced() {
        var restoredPolicy = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        restoredPolicy.observePeripheral(bikeA)
        restoredPolicy.channelsBecameReady()
        XCTAssertFalse(restoredPolicy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
        restoredPolicy.confirmedTransportBoundary(for: bikeA)
        restoredPolicy.channelsBecameReady()
        XCTAssertFalse(restoredPolicy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
    }

    func testAsynchronousSaveCannotStartAnotherRide() {
        var policy = readyPolicy()
        policy.userRequestedFinish(transportConnected: true)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: true))
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: true))
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testManualFinishSuppressesSameConnectionButNotNextConnection() {
        var policy = readyPolicy()
        policy.userRequestedFinish(transportConnected: true)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.confirmedTransportBoundary(for: bikeA)
        policy.transportDisconnected()
        XCTAssertNil(policy.stoppedPeripheralID)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testFinishWhileDisconnectedAllowsNextReadyConnection() {
        var policy = RideAutomationPolicy()
        policy.observePeripheral(bikeA)
        policy.userRequestedFinish(transportConnected: false)
        policy.confirmedTransportBoundary(for: bikeA)
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testSavedFinishSurvivesNewProcessAndRestoredConnectedPeripheral() {
        var beforeRestart = readyPolicy()
        beforeRestart.userRequestedFinish(transportConnected: true)
        let persistedID = beforeRestart.stoppedPeripheralID
        XCTAssertEqual(persistedID, bikeA)

        var afterRestart = RideAutomationPolicy(stoppedPeripheralID: persistedID)
        afterRestart.transportDisconnected() // Initial Published(false), not a BLE callback.
        afterRestart.observePeripheral(bikeA)
        afterRestart.channelsBecameReady() // Restoration has no new didConnect.
        XCTAssertEqual(afterRestart.stoppedPeripheralID, bikeA)
        XCTAssertFalse(afterRestart.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testConfirmedNewConnectionClearsRestoredFinishMarker() {
        var policy = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        policy.observePeripheral(bikeA)
        policy.confirmedTransportBoundary(for: bikeA) // Actual didConnect.
        policy.channelsBecameReady()
        XCTAssertNil(policy.stoppedPeripheralID)
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testOtherMotorcycleDoesNotInheritFinishedSession() {
        var policy = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        policy.observePeripheral(bikeB)
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.confirmedTransportBoundary(for: bikeB)
        XCTAssertEqual(policy.stoppedPeripheralID, bikeA)
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testChangingMotorcycleRequiresFreshChannelReadiness() {
        var policy = readyPolicy()
        policy.observePeripheral(bikeB)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testExplicitManualStartClearsSavedFinishMarker() {
        var policy = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        policy.userRequestedManualStart()
        XCTAssertNil(policy.stoppedPeripheralID)
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testReconnectDuringSaveStartsOnlyAfterSavedRideIsReleased() {
        var policy = readyPolicy()
        policy.userRequestedFinish(transportConnected: true)
        policy.confirmedTransportBoundary(for: bikeA)
        policy.transportDisconnected()
        policy.confirmedTransportBoundary(for: bikeA)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: true))
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }
}
