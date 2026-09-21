import XCTest
@testable import MotoLinkCore

final class JournalCheckpointPolicyTests: XCTestCase {
    func testHighRateRawStreamNeedsOnlyOneCheckpointPerSecond() {
        var policy = JournalCheckpointPolicy()
        var count = 0
        for tick in 0..<6000 {
            let uptime = Double(tick) / 100
            if policy.shouldCheckpoint(at: uptime) {
                count += 1
                policy.checkpointSucceeded(at: uptime)
            }
        }
        XCTAssertEqual(count, 60)
    }

    func testFailedCheckpointIsRetriedOnNextAppend() {
        var policy = JournalCheckpointPolicy()
        policy.checkpointSucceeded(at: 10)
        XCTAssertTrue(policy.shouldCheckpoint(at: 11))
        // I/O failed: deliberately do not mark success.
        XCTAssertTrue(policy.shouldCheckpoint(at: 11.01))
    }

    func testFinishExportAndBackgroundForceCheckpointEvenInsideInterval() {
        var policy = JournalCheckpointPolicy()
        policy.checkpointSucceeded(at: 10)
        XCTAssertFalse(policy.shouldCheckpoint(at: 10.1))
        XCTAssertTrue(policy.shouldCheckpoint(at: 10.1, forced: true))
    }

    func testFirstWriteRollbackAndInvalidClockCannotPreventPersistence() {
        var policy = JournalCheckpointPolicy()
        XCTAssertTrue(policy.shouldCheckpoint(at: 0))
        policy.checkpointSucceeded(at: 20)
        XCTAssertTrue(policy.shouldCheckpoint(at: 2))
        XCTAssertTrue(policy.shouldCheckpoint(at: .nan))
        policy.checkpointSucceeded(at: .infinity)
        XCTAssertTrue(policy.shouldCheckpoint(at: 30))
    }
}
