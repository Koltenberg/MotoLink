import Foundation
import XCTest
@testable import MotoLinkCore

final class JournalCheckpointPolicyTests: XCTestCase {
    func testFinishingBatchRetryDoesNotDuplicateAnAlreadyWrittenBoundary() throws {
        var progress = JournalFinishWriteProgress()
        let id = UUID()
        let boundary = Data("{\"kind\":\"finished\"}\n".utf8)
        let gap = Data("{\"kind\":\"gps_gap\"}\n".utf8)
        let records = [boundary, gap]
        var persisted = Data()
        var writes = 0
        XCTAssertThrowsError(try progress.append(records, rideID: id) { bytes in
            writes += 1
            if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            persisted.append(bytes)
        })
        XCTAssertEqual(persisted, boundary)
        try progress.append(records, rideID: id) { persisted.append($0) }
        XCTAssertEqual(persisted, boundary + gap)
        // The records are complete but pretend fsync or manifest replacement
        // failed. A retry must still leave exactly one finish and one gap.
        try progress.append(records, rideID: id) { persisted.append($0) }
        XCTAssertEqual(persisted, boundary + gap)
        progress.checkpointSucceeded(rideID: id)
        let nextRide = UUID()
        try progress.append([boundary], rideID: nextRide) { persisted.append($0) }
        XCTAssertEqual(persisted, boundary + gap + boundary)
    }

    func testFailedFirstFinishRecordIsRetried() throws {
        var progress = JournalFinishWriteProgress()
        let id = UUID(), records = [Data("finished\n".utf8)]
        XCTAssertThrowsError(try progress.append(records, rideID: id) { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        var persisted = Data()
        try progress.append(records, rideID: id) { persisted.append($0) }
        XCTAssertEqual(persisted, records[0])
    }

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
