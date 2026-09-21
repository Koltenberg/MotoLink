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
}
