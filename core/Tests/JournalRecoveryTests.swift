import Foundation
import XCTest
@testable import MotoLinkCore

final class JournalRecoveryTests: XCTestCase {
    func testFirstRawCommitCannotLeaveAnUndiscoverableRideAfterCheckpointFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let manifest = directory.appendingPathComponent("\(id.uuidString).json")
        let raw = directory.appendingPathComponent("\(id.uuidString).jsonl")
        let initial = Data("{\"id\":\"\(id.uuidString)\"}".utf8)
        try JournalInitialManifest.prepare(at: manifest, contents: initial)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        try Data("{\"kind\":\"started\"}\n".utf8).write(to: raw)
        let handle = try FileHandle(forWritingTo: raw)
        try handle.synchronize(); try handle.close()
        // No later manifest/checkpoint update is performed: simulate its loss.
        let history = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(history, [manifest])
        XCTAssertEqual(try Data(contentsOf: manifest), initial)
        try JournalInitialManifest.prepare(at: manifest, contents: Data("new provisional summary".utf8))
        XCTAssertEqual(try Data(contentsOf: manifest), initial)
    }

    private struct Summary: Codable, JournalRecoverableSummary {
        var id = UUID()
        var startedAt = Date(timeIntervalSince1970: 1000)
        var endedAt: Date?
        var lastSavedAt = Date(timeIntervalSince1970: 1001)
        var distanceMeters = 0.0
        var maxSpeedMS = 0.0
        var pointCount = 0
        var telemetryCount = 0
        var rawEventCount: Int?
        var acceptedSpeedCount: Int?
    }

    private struct Record: Codable {
        var kind: String
        var timestamp: Date
        var summaryCheckpoint: Summary?
        var distanceMeters: Double?
        var speed: Double?
    }

    func testCrashReplayRecoversCompletePostManifestRecordsAndIgnoresTornTail() throws {
        let saved = Summary()
        var newer = saved
        newer.lastSavedAt = saved.startedAt.addingTimeInterval(2)
        newer.distanceMeters = 100
        newer.pointCount = 1
        newer.telemetryCount = 1
        newer.rawEventCount = 1
        let records = [
            Record(kind: "gps", timestamp: saved.startedAt.addingTimeInterval(1.5), distanceMeters: 100, speed: 20),
            Record(kind: "motorcycle", timestamp: saved.startedAt.addingTimeInterval(1.6)),
            Record(kind: "diagnostic", timestamp: saved.startedAt.addingTimeInterval(1.7)),
            Record(kind: "summary_checkpoint", timestamp: newer.lastSavedAt, summaryCheckpoint: newer),
            Record(kind: "gps", timestamp: saved.startedAt.addingTimeInterval(2.25), distanceMeters: 115, speed: 21),
            Record(kind: "motorcycle", timestamp: saved.startedAt.addingTimeInterval(2.3)),
            Record(kind: "diagnostic", timestamp: saved.startedAt.addingTimeInterval(2.31))
        ]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let encoder = RideJournalDates.encoder(), decoder = RideJournalDates.decoder()
        var journal = Data()
        for record in records { journal.append(try encoder.encode(record)); journal.append(10) }
        journal.append(Data("{\"kind\":\"gps\",\"distanceMeters\":999999".utf8))
        try journal.write(to: file)
        var recovery = JournalReplayRecovery(summary: saved)
        try CaptureJournalExport.forEachLine(in: file) { line in
            if let record = try? decoder.decode(Record.self, from: line) {
                recovery.observe(kind: record.kind, at: record.timestamp, checkpoint: record.summaryCheckpoint,
                                 distanceMeters: record.distanceMeters, gpsSpeed: record.speed)
            }
        }
        XCTAssertEqual(recovery.recovered.distanceMeters, 115)
        XCTAssertEqual(recovery.recovered.pointCount, 2)
        XCTAssertEqual(recovery.recovered.telemetryCount, 2)
        XCTAssertEqual(recovery.recovered.rawEventCount, 2)
        XCTAssertEqual(recovery.recovered.acceptedSpeedCount, 2)
        XCTAssertEqual(recovery.recovered.maxSpeedMS, 21)
        XCTAssertEqual(recovery.recovered.lastSavedAt.timeIntervalSince1970, 1002.31, accuracy: 0.001)
        XCTAssertNil(recovery.recovered.endedAt)
    }

    func testPersistedFinishSurvivesFailedManifestReplacementAndRepeatedBoundary() {
        let saved = Summary()
        var recovery = JournalReplayRecovery(summary: saved)
        let finished = saved.startedAt.addingTimeInterval(42.75)
        recovery.observe(kind: "finished", at: finished)
        recovery.observe(kind: "finished", at: finished.addingTimeInterval(0.2))
        recovery.observe(kind: "gps_gap", at: finished)
        recovery.observe(kind: "gps", at: finished.addingTimeInterval(1), distanceMeters: 9000, gpsSpeed: 70)
        XCTAssertEqual(recovery.recovered.endedAt, finished)
        XCTAssertEqual(recovery.recovered.pointCount, 0)
        XCTAssertEqual(recovery.recovered.distanceMeters, 0)
    }

    func testCheckpointFromAnotherRideOrOldRevisionCannotReplaceThisRide() {
        var saved = Summary()
        saved.distanceMeters = 200
        var recovery = JournalReplayRecovery(summary: saved)
        var other = saved
        other.id = UUID()
        other.distanceMeters = 10000
        other.lastSavedAt = saved.lastSavedAt.addingTimeInterval(100)
        recovery.observe(kind: "summary_checkpoint", at: other.lastSavedAt, checkpoint: other)
        var older = saved
        older.lastSavedAt = saved.lastSavedAt.addingTimeInterval(-0.5)
        older.distanceMeters = 10000
        recovery.observe(kind: "summary_checkpoint", at: saved.lastSavedAt, checkpoint: older)
        recovery.observe(kind: "gps", at: saved.startedAt.addingTimeInterval(-1), distanceMeters: 10000, gpsSpeed: 30)
        XCTAssertEqual(recovery.recovered.id, saved.id)
        XCTAssertEqual(recovery.recovered.distanceMeters, 200)
        XCTAssertEqual(recovery.recovered.pointCount, 0)
    }

    func testRouteGapDoesNotManufactureDistanceAndLegacyManifestIsLowerBound() {
        var saved = Summary()
        saved.distanceMeters = 200
        saved.pointCount = 15
        var recovery = JournalReplayRecovery(summary: saved)
        recovery.observe(kind: "gps_gap", at: saved.startedAt.addingTimeInterval(3600), distanceMeters: 100000)
        recovery.observe(kind: "gps", at: saved.startedAt.addingTimeInterval(3601), gpsSpeed: 0)
        XCTAssertEqual(recovery.recovered.distanceMeters, 200)
        XCTAssertEqual(recovery.recovered.pointCount, 15)
    }

    func testDateCodingPreservesSubSecondChartOrderingAndReadsLegacyDates() throws {
        let encoder = RideJournalDates.encoder(), decoder = RideJournalDates.decoder()
        let times = [1000.015, 1000.115, 1000.215, 1000.915].map(Date.init(timeIntervalSince1970:))
        let roundtrip = try decoder.decode([Date].self, from: encoder.encode(times))
        for (original, decoded) in zip(times, roundtrip) {
            XCTAssertEqual(original.timeIntervalSince1970, decoded.timeIntervalSince1970, accuracy: 0.001)
        }
        XCTAssertEqual(Set(roundtrip).count, 4)
        let legacy = try decoder.decode(Date.self, from: Data("\"2026-09-24T10:00:00Z\"".utf8))
        XCTAssertEqual(legacy, RideJournalDates.date(from: "2026-09-24T10:00:00Z"))
        XCTAssertNotNil(RideJournalDates.date(from: "2026-09-24T10:00:00.125Z"))
        XCTAssertThrowsError(try decoder.decode(Date.self, from: Data("\"tomorrow\"".utf8)))
    }

    func testFastMeasurementsAreBoundedAndSlowChannelsStayOneHertz() {
        var sampling = RideMeasurementSampling()
        var rpm = 0, speed = 0, throttle = 0, temperature = 0
        for tick in 0..<6000 {
            let date = Date(timeIntervalSince1970: 1000 + Double(tick) / 100)
            if sampling.accepts(id: "engine_speed", at: date) { rpm += 1 }
            if sampling.accepts(id: "wheel_speed", at: date) { speed += 1 }
            if sampling.accepts(id: "throttle_position", at: date) { throttle += 1 }
            if sampling.accepts(id: "engine_water_temperature", at: date) { temperature += 1 }
        }
        XCTAssertEqual(rpm, 600)
        XCTAssertEqual(speed, 600)
        XCTAssertEqual(throttle, 300)
        XCTAssertEqual(temperature, 60)
        XCTAssertFalse(sampling.accepts(id: "engine_speed", at: Date(timeIntervalSince1970: 900)))
        XCTAssertFalse(sampling.accepts(id: "engine_speed", at: Date(timeIntervalSince1970: .nan)))
    }
}
