import Foundation
import XCTest
@testable import MotoLinkCore

final class BLECancelResumePolicyTests: XCTestCase {
    private let bikeA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let bikeB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    func testOffThenOnWaitsForCancellationAndResumesExactlyOnce() {
        var policy = BLECancelResumePolicy()
        policy.requestedCancellation(for: bikeA)
        XCTAssertTrue(policy.requestedResume(for: bikeA))
        XCTAssertEqual(policy.cancellingPeripheralID, bikeA)
        // Queued intent alone does not consume ownership of the old request.
        XCTAssertTrue(policy.resumeAfterCancellation)
        XCTAssertTrue(policy.completedCancellation(for: bikeA, canResume: true))
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: true))
        XCTAssertNil(policy.cancellingPeripheralID)
    }

    func testOffWithoutNewResumeStaysStopped() {
        var policy = BLECancelResumePolicy()
        policy.requestedCancellation(for: bikeA)
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: true))
    }

    func testOffOnOffRevokesQueuedResume() {
        var policy = BLECancelResumePolicy()
        policy.requestedCancellation(for: bikeA)
        policy.requestedResume(for: bikeA)
        policy.revokeResume()
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: true))
    }

    func testExplicitPauseAfterResumeRevokesItAndRetainsCancelOwnership() {
        var policy = BLECancelResumePolicy()
        policy.requestedCancellation(for: bikeA)
        policy.requestedResume(for: bikeA)
        policy.requestedCancellation(for: bikeA)
        XCTAssertEqual(policy.cancellingPeripheralID, bikeA)
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: true))
    }

    func testRacingConnectDoesNotConsumeTheQueuedResume() {
        var policy = BLECancelResumePolicy()
        policy.requestedCancellation(for: bikeA)
        policy.requestedResume(for: bikeA)
        // didConnect must cancel and return, not complete this policy. Repeated
        // UI requests before didDisconnect still become one later connect.
        XCTAssertTrue(policy.requestedResume(for: bikeA))
        XCTAssertTrue(policy.completedCancellation(for: bikeA, canResume: true))
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: true))
    }

    func testAnotherPeripheralCannotRequestOrConsumeResume() {
        var policy = BLECancelResumePolicy()
        policy.requestedCancellation(for: bikeA)
        XCTAssertFalse(policy.requestedResume(for: bikeB))
        policy.requestedResume(for: bikeA)
        XCTAssertFalse(policy.completedCancellation(for: bikeB, canResume: true))
        XCTAssertTrue(policy.completedCancellation(for: bikeA, canResume: true))
    }

    func testPowerOffOrNewConnectionDropsOldIntent() {
        var policy = BLECancelResumePolicy()
        policy.requestedCancellation(for: bikeA)
        policy.requestedResume(for: bikeA)
        policy.reset()
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: true))
        XCTAssertFalse(policy.requestedResume(for: bikeA))
    }

    func testUnavailableRadioConsumesWithoutConnecting() {
        var policy = BLECancelResumePolicy()
        policy.requestedCancellation(for: bikeA)
        policy.requestedResume(for: bikeA)
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: false))
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: true))
    }

    func testNormalFailureOrCooldownNeverCreatesCancellationIntent() {
        var policy = BLECancelResumePolicy()
        XCTAssertFalse(policy.requestedResume(for: bikeA))
        XCTAssertFalse(policy.completedCancellation(for: bikeA, canResume: true))
    }
}
