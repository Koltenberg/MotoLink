import Foundation
import XCTest
@testable import MotoLinkCore

final class BLEReconnectPolicyTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)

    func testDisconnectThenBriefConnectionThenEncryptionTimeoutContinuesRecovery() {
        var policy = BLEReconnectPolicy()
        XCTAssertEqual(policy.nextDelay(allowed: true), 0)
        policy.connectionStarted()
        // didConnect alone is not a successful recovery: no fresh 4A arrived.
        XCTAssertEqual(policy.nextDelay(allowed: true), 2)
        policy.connectionStarted()
        // The following didFailToConnect must retain another pending attempt.
        XCTAssertEqual(policy.nextDelay(allowed: true), 5)
        XCTAssertFalse(policy.pairingRequired)
    }

    func testRepeatedFailuresBackOffWithoutOverflowOrPermanentStop() {
        var policy = BLEReconnectPolicy()
        XCTAssertEqual((0..<6).map { _ in policy.nextDelay(allowed: true) }, [0, 2, 5, 15, 30, 60])
        for _ in 0..<10000 { XCTAssertEqual(policy.nextDelay(allowed: true), 60) }
        XCTAssertEqual(policy.failureCount, 6)
    }

    func testStoppedOrDisabledRecoveryDoesNotCreateAnAttempt() {
        var policy = BLEReconnectPolicy()
        XCTAssertNil(policy.nextDelay(allowed: false))
        XCTAssertEqual(policy.failureCount, 0)
        _ = policy.nextDelay(allowed: true)
        policy.reset()
        XCTAssertNil(policy.nextDelay(allowed: false))
        XCTAssertEqual(policy.failureCount, 0)
    }

    func testRemovedPairingBlocksRetriesUntilExplicitReset() {
        var policy = BLEReconnectPolicy()
        XCTAssertNil(policy.nextDelay(allowed: true, requiresPairing: true))
        XCTAssertTrue(policy.pairingRequired)
        XCTAssertNil(policy.nextDelay(allowed: true))
        policy.connectionStarted()
        XCTAssertNil(policy.nextDelay(allowed: true))
        policy.reset()
        XCTAssertFalse(policy.pairingRequired)
        XCTAssertEqual(policy.nextDelay(allowed: true), 0)
    }

    func testSingleTelemetryPacketDoesNotResetFailureStreak() {
        var policy = BLEReconnectPolicy()
        _ = policy.nextDelay(allowed: true)
        _ = policy.nextDelay(allowed: true)
        policy.connectionStarted()
        policy.receivedTelemetry(at: start)
        XCTAssertEqual(policy.failureCount, 2)
        XCTAssertEqual(policy.nextDelay(allowed: true), 5)
    }

    func testContinuousTelemetryResetsBackoffAfterFifteenSeconds() {
        var policy = BLEReconnectPolicy()
        _ = policy.nextDelay(allowed: true)
        _ = policy.nextDelay(allowed: true)
        policy.connectionStarted()
        for second in 0..<15 { policy.receivedTelemetry(at: start.addingTimeInterval(Double(second))) }
        XCTAssertEqual(policy.failureCount, 2)
        policy.receivedTelemetry(at: start.addingTimeInterval(15))
        XCTAssertEqual(policy.failureCount, 0)
        XCTAssertEqual(policy.nextDelay(allowed: true), 0)
    }

    func testSilentGapAndBackwardsClockCannotProveStableRecovery() {
        var policy = BLEReconnectPolicy()
        _ = policy.nextDelay(allowed: true)
        policy.receivedTelemetry(at: start)
        policy.receivedTelemetry(at: start.addingTimeInterval(30))
        XCTAssertEqual(policy.failureCount, 1)
        policy.receivedTelemetry(at: start.addingTimeInterval(-10))
        policy.receivedTelemetry(at: start)
        XCTAssertEqual(policy.failureCount, 1)
    }

    func testNewConnectionCannotBorrowPreviousStreamDuration() {
        var policy = BLEReconnectPolicy()
        _ = policy.nextDelay(allowed: true)
        for second in 0...14 { policy.receivedTelemetry(at: start.addingTimeInterval(Double(second))) }
        policy.connectionStarted()
        policy.receivedTelemetry(at: start.addingTimeInterval(15))
        XCTAssertEqual(policy.failureCount, 1)
    }

    func testGATTFailureSurvivesCancellationAndEncryptionFailure() {
        var policy = BLEReconnectPolicy()
        policy.requestTransportRestart()
        XCTAssertTrue(policy.transportRestartPending)
        // iOS confirms our cancel after a discovery/write/notification failure.
        XCTAssertEqual(policy.nextDelay(allowed: true, cancelled: true), 0)
        XCTAssertFalse(policy.transportRestartPending)
        policy.connectionStarted()
        // The next encryption timeout must not permanently abandon the ride.
        XCTAssertEqual(policy.nextDelay(allowed: true), 2)
        policy.connectionStarted()
        policy.requestTransportRestart()
        XCTAssertEqual(policy.nextDelay(allowed: true, cancelled: true), 5)
    }

    func testUserStopWhileTransportIsClosingWinsOverScheduledRecovery() {
        var policy = BLEReconnectPolicy()
        policy.requestTransportRestart()
        policy.reset() // Stop button or disabling automatic reconnection.
        XCTAssertNil(policy.nextDelay(allowed: false, cancelled: true))
        XCTAssertFalse(policy.transportRestartPending)
        XCTAssertEqual(policy.failureCount, 0)
    }

    func testUnexpectedCancellationCannotBorrowAnEarlierRestart() {
        var policy = BLEReconnectPolicy()
        policy.requestTransportRestart()
        XCTAssertEqual(policy.nextDelay(allowed: true, cancelled: true), 0)
        policy.connectionStarted()
        XCTAssertNil(policy.nextDelay(allowed: true, cancelled: true))
        XCTAssertEqual(policy.failureCount, 1)
    }

    func testPairingErrorStillBlocksLocallyRequestedRestart() {
        var policy = BLEReconnectPolicy()
        policy.requestTransportRestart()
        XCTAssertNil(policy.nextDelay(allowed: true, requiresPairing: true, cancelled: true))
        XCTAssertTrue(policy.pairingRequired)
        policy.requestTransportRestart()
        XCTAssertNil(policy.nextDelay(allowed: true, cancelled: true))
    }

    func testPowerLossCannotUsePendingRestartWithoutPermission() {
        var policy = BLEReconnectPolicy()
        policy.requestTransportRestart()
        XCTAssertNil(policy.nextDelay(allowed: false, cancelled: true))
        XCTAssertFalse(policy.transportRestartPending)
        XCTAssertEqual(policy.failureCount, 0)
    }

    func testRepeatedGATTFailuresStayBoundedThenFortyMinuteStreamRecovers() {
        var policy = BLEReconnectPolicy()
        for _ in 0..<100 {
            policy.requestTransportRestart()
            let delay = policy.nextDelay(allowed: true, cancelled: true)
            XCTAssertNotNil(delay)
            XCTAssertLessThanOrEqual(delay!, 60)
            policy.connectionStarted()
        }
        for packet in 0...12000 { // 40 minutes at the observed 5 Hz.
            policy.receivedTelemetry(at: start.addingTimeInterval(Double(packet) / 5))
        }
        XCTAssertEqual(policy.failureCount, 0)
        XCTAssertFalse(policy.transportRestartPending)
        XCTAssertEqual(policy.nextDelay(allowed: true), 0)
    }
}
