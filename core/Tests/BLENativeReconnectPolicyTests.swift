import Foundation
import XCTest
@testable import MotoLinkCore

final class BLENativeReconnectPolicyTests: XCTestCase {
    private let bike = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func connectedPolicy() -> BLENativeReconnectPolicy {
        var policy = BLENativeReconnectPolicy()
        XCTAssertTrue(policy.connectionRequested(for: bike, supported: true, enabled: true))
        XCTAssertTrue(policy.connected(bike))
        return policy
    }

    func testTurningOffFutureAutoConnectKeepsRestoredLiveLink() {
        XCTAssertTrue(BLENativeReconnectPolicy.shouldAdoptRestoredPeripheral(
            isSaved: true, paused: false, autoReconnect: false, isConnected: true))
        XCTAssertFalse(BLENativeReconnectPolicy.shouldAdoptRestoredPeripheral(
            isSaved: true, paused: true, autoReconnect: true, isConnected: true))
        XCTAssertFalse(BLENativeReconnectPolicy.shouldAdoptRestoredPeripheral(
            isSaved: false, paused: false, autoReconnect: true, isConnected: true))
        XCTAssertFalse(BLENativeReconnectPolicy.shouldAdoptRestoredPeripheral(
            isSaved: true, paused: false, autoReconnect: false, isConnected: false))
    }

    func testFutureAutoConnectPreferenceDoesNotCancelIOSNativeReconnectOfExistingLink() {
        let preserve = BLENativeReconnectPolicy.shouldPreserveNativeConnection(
            wanted: true, powered: true, paused: false,
            pairingFailure: false, transportRestartPending: false)
        XCTAssertTrue(preserve)
        var policy = connectedPolicy()
        XCTAssertEqual(policy.disconnected(bike, timestamp: 121,
            reconnecting: true, peripheralIsConnected: false, mayResume: preserve), .waitForSystem)
        XCTAssertEqual(policy.disconnected(bike, timestamp: 122,
            reconnecting: true, peripheralIsConnected: true, mayResume: preserve), .prepareConnected)
        XCTAssertFalse(BLENativeReconnectPolicy.shouldPreserveNativeConnection(
            wanted: true, powered: true, paused: true,
            pairingFailure: false, transportRestartPending: false))
    }

    func testSystemPendingHasNoApplicationDeadlineAndNewConnectPrepares() {
        var policy = connectedPolicy()
        XCTAssertEqual(policy.disconnected(bike, timestamp: 120,
            reconnecting: true, peripheralIsConnected: false, mayResume: true), .waitForSystem)
        XCTAssertTrue(policy.systemOwnsPendingConnection)
        XCTAssertTrue(policy.connected(bike))
        XCTAssertFalse(policy.systemOwnsPendingConnection)
    }

    func testSystemGiveUpAllowsApplicationFallback() {
        var policy = connectedPolicy()
        _ = policy.disconnected(bike, timestamp: 120,
            reconnecting: true, peripheralIsConnected: false, mayResume: true)
        XCTAssertEqual(policy.disconnected(bike, timestamp: 130,
            reconnecting: false, peripheralIsConnected: false, mayResume: true), .applicationFallback)
        XCTAssertFalse(policy.systemOwnsPendingConnection)
    }

    func testStopCancelsSystemRequestEvenWhenPeripheralLooksDisconnected() {
        var policy = connectedPolicy()
        XCTAssertEqual(policy.disconnected(bike, timestamp: 120,
            reconnecting: true, peripheralIsConnected: false, mayResume: false), .cancelConnection)
        XCTAssertTrue(policy.systemOwnsPendingConnection)
        policy.cancellationRequested()
        XCTAssertFalse(policy.connected(bike))
        XCTAssertTrue(policy.awaitingCancellation)
        XCTAssertEqual(policy.disconnected(bike, timestamp: 123,
            reconnecting: false, peripheralIsConnected: false, mayResume: false), .applicationFallback)
        XCTAssertFalse(policy.awaitingCancellation)
    }

    func testOffOnRaceMustFinishCancellationBeforeResuming() {
        var native = connectedPolicy()
        var intent = BLECancelResumePolicy()
        _ = native.disconnected(bike, timestamp: 120,
            reconnecting: true, peripheralIsConnected: false, mayResume: true)
        native.cancellationRequested()
        intent.requestedCancellation(for: bike)
        intent.requestedResume(for: bike)
        XCTAssertFalse(native.connected(bike))
        XCTAssertEqual(native.disconnected(bike, timestamp: 123,
            reconnecting: false, peripheralIsConnected: false, mayResume: true), .applicationFallback)
        XCTAssertTrue(intent.completedCancellation(for: bike, canResume: true))
        XCTAssertFalse(intent.completedCancellation(for: bike, canResume: true))
    }

    func testRestoredConnectingIsAlreadyOwnedBySystem() {
        var policy = BLENativeReconnectPolicy()
        policy.restored(bike, connecting: true)
        XCTAssertTrue(policy.systemOwnsPendingConnection)
        XCTAssertFalse(policy.optionUsedForAttempt)
        XCTAssertTrue(policy.connected(bike))
        XCTAssertFalse(policy.systemOwnsPendingConnection)
    }

    func testRestoredConnectedCanPrepareWithoutNewConnectionRequest() {
        var policy = BLENativeReconnectPolicy()
        policy.restored(bike, connecting: false)
        XCTAssertFalse(policy.systemOwnsPendingConnection)
        policy.preparedConnectedState(bike)
        XCTAssertFalse(policy.connected(bike))
    }

    func testPowerLossDropsOwnershipAndOldPeripheralCallbacks() {
        var policy = connectedPolicy()
        _ = policy.disconnected(bike, timestamp: 120,
            reconnecting: true, peripheralIsConnected: false, mayResume: true)
        policy.clearConnection()
        XCTAssertFalse(policy.systemOwnsPendingConnection)
        XCTAssertEqual(policy.disconnected(bike, timestamp: 125,
            reconnecting: true, peripheralIsConnected: false, mayResume: true), .ignore)
    }

    func testStalePeripheralCannotStealOwnership() {
        var policy = connectedPolicy()
        XCTAssertEqual(policy.disconnected(other, timestamp: 120,
            reconnecting: true, peripheralIsConnected: false, mayResume: true), .ignore)
        XCTAssertFalse(policy.connected(other))
    }

    func testDelayedDisconnectCannotDestroyAlreadyObservedNewConnection() {
        var policy = connectedPolicy()
        XCTAssertTrue(policy.connected(bike))
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: true, mayResume: true), .ignore)
        XCTAssertFalse(policy.systemOwnsPendingConnection)
    }

    func testQueuedBackgroundConnectionDoesNotHideActualDisconnectedState() {
        var policy = connectedPolicy()
        XCTAssertTrue(policy.connected(bike))
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: true), .waitForSystem)
    }

    func testConnectedStateCanReconcileBeforeDelayedDidConnectWithoutTwoSetups() {
        var policy = connectedPolicy()
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: true, mayResume: true), .prepareConnected)
        XCTAssertFalse(policy.connected(bike))
        XCTAssertFalse(policy.systemOwnsPendingConnection)
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: true, mayResume: true), .ignore)
    }

    func testDuplicateDisconnectDoesNotResetPendingWait() {
        var policy = connectedPolicy()
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: true), .waitForSystem)
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: true), .ignore)
        XCTAssertTrue(policy.systemOwnsPendingConnection)
    }

    func testTerminalOwnershipChangeMayReuseOriginalDisconnectTimestamp() {
        var policy = connectedPolicy()
        _ = policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: true)
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: false, peripheralIsConnected: false, mayResume: true), .applicationFallback)
        XCTAssertFalse(policy.systemOwnsPendingConnection)
    }

    func testDifferentEarlierTimestampCannotSuppressARealDisconnectAfterClockChange() {
        var policy = connectedPolicy()
        _ = policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: true)
        XCTAssertTrue(policy.connected(bike))
        XCTAssertEqual(policy.disconnected(bike, timestamp: 10,
            reconnecting: true, peripheralIsConnected: false, mayResume: true), .waitForSystem)
        XCTAssertTrue(policy.systemOwnsPendingConnection)
    }

    func testARepeatedTerminalTimestampCannotHideCancellationAcknowledgement() {
        var policy = connectedPolicy()
        _ = policy.disconnected(bike, timestamp: 140,
            reconnecting: false, peripheralIsConnected: true, mayResume: true)
        policy.cancellationRequested()
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: false, peripheralIsConnected: false, mayResume: false), .applicationFallback)
        XCTAssertFalse(policy.awaitingCancellation)
    }

    func testSameTimestampCannotHideNewDisconnectedStateAfterConnect() {
        var policy = connectedPolicy()
        _ = policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: true)
        XCTAssertTrue(policy.connected(bike))
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: true), .waitForSystem)
        XCTAssertTrue(policy.systemOwnsPendingConnection)
    }

    func testRepeatedNativeWaitEventDoesNotIssueAnotherCancel() {
        var policy = connectedPolicy()
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: false), .cancelConnection)
        policy.cancellationRequested()
        XCTAssertEqual(policy.disconnected(bike, timestamp: 140,
            reconnecting: true, peripheralIsConnected: false, mayResume: false), .ignore)
        XCTAssertTrue(policy.awaitingCancellation)
    }

    func testOptionalParameterRejectionFallsBackOnlyOnceAndSurvivesPowerReset() {
        var policy = BLENativeReconnectPolicy()
        XCTAssertTrue(policy.connectionRequested(for: bike, supported: true, enabled: true))
        XCTAssertFalse(policy.rejectOptionIfUsed(invalidParameters: false))
        XCTAssertTrue(policy.rejectOptionIfUsed(invalidParameters: true))
        policy.clearConnection()
        XCTAssertFalse(policy.connectionRequested(for: bike, supported: true, enabled: true))
        XCTAssertFalse(policy.rejectOptionIfUsed(invalidParameters: true))
    }

    func testLegacyOrDisabledAttemptCannotBeBlamedOnNativeOption() {
        var policy = BLENativeReconnectPolicy()
        XCTAssertFalse(policy.connectionRequested(for: bike, supported: false, enabled: true))
        XCTAssertFalse(policy.rejectOptionIfUsed(invalidParameters: true))
        XCTAssertFalse(policy.connectionRequested(for: bike, supported: true, enabled: false))
        XCTAssertFalse(policy.rejectOptionIfUsed(invalidParameters: true))
        XCTAssertFalse(policy.optionRejected)
    }
}
