import Foundation
import XCTest
@testable import MotoLinkCore

final class MileageLedgerTests: XCTestCase {
    private let bike = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let other = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func feed(_ ledger: inout MileageLedger, _ seconds: Double, speed: Double = 10,
                      source: MileageLedger.SpeedSource = .motorcycle, id: UUID? = nil) -> Double {
        let time = epoch.addingTimeInterval(seconds)
        return ledger.recordSpeed(bikeID: id ?? bike, source: source, metersPerSecond: speed,
                                  timestamp: time, receivedAt: time)
    }

    func testConstantSpeedWithoutDetailedRideCreatesOnlyCompactMileage() throws {
        var ledger = MileageLedger(timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(feed(&ledger, 0), 0) // No tracking session.
        ledger.beginTracking(bikeID: bike)
        XCTAssertEqual(feed(&ledger, 0), 0)
        for second in 1...60 { XCTAssertEqual(feed(&ledger, Double(second)), 10, accuracy: 1e-8) }
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 600, accuracy: 1e-8)
        XCTAssertEqual(ledger.accounts[bike]?.days.count, 1)
        XCTAssertEqual(ledger.accounts[bike]?.bikeSourceMeters, 600)
        XCTAssertNil(ledger.estimatedOdometerKilometers(bikeID: bike))
        try ledger.validate()
    }

    func testDuplicateOutOfOrderInvalidStaleAndFutureSamplesDoNotAddMileage() throws {
        var ledger = MileageLedger()
        ledger.beginTracking(bikeID: bike)
        _ = feed(&ledger, 0)
        _ = feed(&ledger, 1)
        XCTAssertEqual(feed(&ledger, 1, speed: 99), 0)
        XCTAssertEqual(feed(&ledger, 0.5, speed: 99), 0)
        for speed in [-1.0, .nan, .infinity, 100.01] { XCTAssertEqual(feed(&ledger, 2, speed: speed), 0) }
        XCTAssertEqual(ledger.recordSpeed(bikeID: bike, source: .motorcycle, metersPerSecond: 99,
            timestamp: epoch.addingTimeInterval(2), receivedAt: epoch.addingTimeInterval(6)), 0)
        XCTAssertEqual(ledger.recordSpeed(bikeID: bike, source: .motorcycle, metersPerSecond: 99,
            timestamp: epoch.addingTimeInterval(2), receivedAt: epoch.addingTimeInterval(1.9)), 0)
        XCTAssertEqual(feed(&ledger, 2), 10, accuracy: 1e-8)
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 20, accuracy: 1e-8)
        try ledger.validate()
    }

    func testTwoSourcesAtSameTimestampNeverDoubleCountAndOrderDoesNotMatter() throws {
        func make(gpsFirst: Bool) throws -> MileageLedger {
            var ledger = MileageLedger()
            ledger.beginTracking(bikeID: bike)
            for second in 0...10 {
                let sources: [MileageLedger.SpeedSource] = gpsFirst ? [.gps, .motorcycle] : [.motorcycle, .gps]
                for source in sources { _ = feed(&ledger, Double(second), speed: source == .motorcycle ? 20 : 10, source: source) }
            }
            try ledger.validate()
            return ledger
        }
        let first = try make(gpsFirst: true)
        let second = try make(gpsFirst: false)
        XCTAssertEqual(first.totalMeters(bikeID: bike), 200, accuracy: 1e-8)
        XCTAssertEqual(first.accounts[bike], second.accounts[bike])
        XCTAssertEqual(first.accounts[bike]?.gpsSourceMeters, 0)
    }

    func testFreshBikeThenGPSFallbackThenBikeReturnNeverAddsTwoDistances() throws {
        var ledger = MileageLedger()
        ledger.beginTracking(bikeID: bike)
        _ = feed(&ledger, 0, speed: 20)
        for second in 0...5 { _ = feed(&ledger, Double(second), speed: 10, source: .gps) }
        // Bike supplies [0,2), then fresh GPS supplies [2,5).
        XCTAssertEqual(ledger.accounts[bike]?.bikeSourceMeters, 40)
        XCTAssertEqual(ledger.accounts[bike]?.gpsSourceMeters, 30)
        _ = feed(&ledger, 5, speed: 30)
        _ = feed(&ledger, 6, speed: 10, source: .gps)
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 100, accuracy: 1e-8)
        XCTAssertEqual(ledger.accounts[bike]?.bikeSourceMeters, 70)
        try ledger.validate()
    }

    func testFreshStationaryBikeOverridesMovingGPSEstimate() throws {
        var ledger = MileageLedger()
        ledger.beginTracking(bikeID: bike)
        for second in 0...5 {
            _ = feed(&ledger, Double(second), speed: 0)
            _ = feed(&ledger, Double(second), speed: 8, source: .gps)
        }
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 0)
        try ledger.validate()
    }

    func testFreshnessExpiresWithoutInventingWholeShortOrLongGap() throws {
        var ledger = MileageLedger()
        ledger.beginTracking(bikeID: bike)
        _ = feed(&ledger, 0, speed: 30)
        // A 2.5s event interval only has two seconds of supported old speed.
        XCTAssertEqual(feed(&ledger, 2.5, speed: 30), 60, accuracy: 1e-8)
        XCTAssertEqual(feed(&ledger, 10, speed: 30), 0)
        XCTAssertEqual(feed(&ledger, 11, speed: 30), 30, accuracy: 1e-8)
        ledger.endTracking(bikeID: bike)
        XCTAssertEqual(feed(&ledger, 12, speed: 30), 0)
        ledger.beginTracking(bikeID: bike)
        XCTAssertEqual(feed(&ledger, 12, speed: 30), 0)
        XCTAssertEqual(feed(&ledger, 13, speed: 0), 30, accuracy: 1e-8)
        XCTAssertEqual(feed(&ledger, 14, speed: 0), 0)
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 120, accuracy: 1e-8)
        try ledger.validate()
    }

    func testRestartDropsTransientSamplesAndRequiresFreshTracking() throws {
        var ledger = MileageLedger()
        ledger.beginTracking(bikeID: bike)
        _ = feed(&ledger, 0)
        _ = feed(&ledger, 1)
        let bytes = try JSONEncoder().encode(ledger)
        var restored = try JSONDecoder().decode(MileageLedger.self, from: bytes)
        XCTAssertFalse(restored.isTracking(bikeID: bike))
        XCTAssertEqual(feed(&restored, 2), 0)
        restored.beginTracking(bikeID: bike)
        XCTAssertEqual(feed(&restored, 2), 0)
        XCTAssertEqual(feed(&restored, 3), 10, accuracy: 1e-8)
        XCTAssertEqual(restored.totalMeters(bikeID: bike), 20, accuracy: 1e-8)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("cursor"))
    }

    func testBikeAccountsAreIndependent() throws {
        var ledger = MileageLedger()
        ledger.beginTracking(bikeID: bike)
        ledger.beginTracking(bikeID: other)
        _ = feed(&ledger, 0, speed: 10)
        _ = feed(&ledger, 0, speed: 30, source: .gps, id: other)
        _ = feed(&ledger, 1, speed: 10)
        _ = feed(&ledger, 1, speed: 30, source: .gps, id: other)
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 10)
        XCTAssertEqual(ledger.totalMeters(bikeID: other), 30)
        XCTAssertEqual(ledger.accounts[other]?.gpsSourceMeters, 30)
        try ledger.validate()
    }

    func testDailyBoundIsCompactedWithoutLosingLifetimeOrSourceTotals() throws {
        var ledger = MileageLedger(timeZone: TimeZone(secondsFromGMT: 0)!, maximumDailyBuckets: 3)
        for day in 0..<8 {
            ledger.beginTracking(bikeID: bike)
            let second = Double(day) * 86_400
            let source: MileageLedger.SpeedSource = day.isMultiple(of: 2) ? .motorcycle : .gps
            _ = feed(&ledger, second, source: source)
            _ = feed(&ledger, second + 1, source: source)
        }
        XCTAssertEqual(ledger.accounts[bike]?.days.count, 3)
        XCTAssertEqual(ledger.accounts[bike]?.foldedTotalMeters, 50)
        XCTAssertEqual(ledger.accounts[bike]?.foldedBikeSourceMeters, 30)
        XCTAssertEqual(ledger.accounts[bike]?.foldedGPSSourceMeters, 20)
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 80)
        try ledger.validate()
        let decoded = try JSONDecoder().decode(MileageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded.accounts, ledger.accounts)
    }

    func testMidnightIsSplitInTheConfiguredTimeZone() throws {
        var ledger = MileageLedger(timeZone: TimeZone(secondsFromGMT: 3 * 3600)!)
        let midnight = ISO8601DateFormatter().date(from: "2026-10-06T00:00:00+03:00")!
        ledger.beginTracking(bikeID: bike)
        let before = midnight.addingTimeInterval(-0.5)
        _ = ledger.recordSpeed(bikeID: bike, source: .motorcycle, metersPerSecond: 20, timestamp: before, receivedAt: before)
        let after = midnight.addingTimeInterval(0.5)
        _ = ledger.recordSpeed(bikeID: bike, source: .motorcycle, metersPerSecond: 20, timestamp: after, receivedAt: after)
        XCTAssertEqual(ledger.accounts[bike]?.days.map(\.day), ["2026-10-05", "2026-10-06"])
        XCTAssertEqual(ledger.accounts[bike]?.days.map(\.totalMeters), [10, 10])
        try ledger.validate()
    }

    func testManualOdometerCorrectionAnchorsOnlyFutureMileageAndCanBeCleared() throws {
        var ledger = MileageLedger()
        ledger.beginTracking(bikeID: bike)
        _ = feed(&ledger, 0)
        _ = feed(&ledger, 1)
        XCTAssertTrue(try ledger.setOdometer(kilometers: 26_123, bikeID: bike, at: epoch.addingTimeInterval(1)))
        XCTAssertEqual(feed(&ledger, 2), 0) // Correction resets the partial interval.
        _ = feed(&ledger, 3)
        XCTAssertEqual(ledger.estimatedOdometerKilometers(bikeID: bike)!, 26_123.01, accuracy: 1e-8)
        let restored = try JSONDecoder().decode(MileageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.estimatedOdometerKilometers(bikeID: bike)!, 26_123.01, accuracy: 1e-8)
        XCTAssertFalse(try ledger.setOdometer(kilometers: 999, bikeID: bike, at: epoch))
        XCTAssertTrue(try ledger.setOdometer(kilometers: 26_122, bikeID: bike, at: epoch.addingTimeInterval(3)))
        XCTAssertEqual(ledger.estimatedOdometerKilometers(bikeID: bike), 26_122)
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 20)
        XCTAssertThrowsError(try ledger.setOdometer(kilometers: .nan, bikeID: bike, at: epoch))
        ledger.clearOdometer(bikeID: bike)
        XCTAssertNil(ledger.estimatedOdometerKilometers(bikeID: bike))
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 20)
        try ledger.validate()
    }

    func testDecodeRejectsInvalidIdentityTotalsDatesAndUnboundedBuckets() throws {
        var ledger = MileageLedger(timeZone: TimeZone(secondsFromGMT: 0)!)
        ledger.beginTracking(bikeID: bike)
        _ = feed(&ledger, 0)
        _ = feed(&ledger, 1)
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as! [String: Any]
        func rejects(_ mutate: (inout [String: Any]) -> Void) throws {
            var changed = original
            mutate(&changed)
            let bytes = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try JSONDecoder().decode(MileageLedger.self, from: bytes))
        }
        try rejects { $0["schemaVersion"] = 99 }
        try rejects { $0["maximumDailyBuckets"] = 401 }
        try rejects { $0["timeZoneIdentifier"] = "not/a/timezone" }
        try rejects { root in
            let accounts = root["accounts"] as! [String: Any]
            root["accounts"] = ["not-a-uuid": accounts[bike.uuidString]!]
        }
        try rejects { root in
            var accounts = root["accounts"] as! [String: Any]
            var account = accounts[bike.uuidString] as! [String: Any]
            account["totalMeters"] = 900
            accounts[bike.uuidString] = account; root["accounts"] = accounts
        }
        try rejects { root in
            var accounts = root["accounts"] as! [String: Any]
            var account = accounts[bike.uuidString] as! [String: Any]
            var days = account["days"] as! [[String: Any]]
            days[0]["day"] = "2026-02-30"
            account["days"] = days; accounts[bike.uuidString] = account; root["accounts"] = accounts
        }
        try rejects { root in
            var accounts = root["accounts"] as! [String: Any]
            var account = accounts[bike.uuidString] as! [String: Any]
            account["odometerAnchor"] = ["kilometers": 123.0, "lifetimeMeters": 11.0,
                                        "recordedAt": epoch.timeIntervalSinceReferenceDate]
            accounts[bike.uuidString] = account; root["accounts"] = accounts
        }
    }

    func testUnrepresentableLocalDayCannotPoisonAnOtherwiseValidLedger() throws {
        var ledger = MileageLedger(timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        ledger.beginTracking(bikeID: bike)
        for second in [1.0, 2.0] { // UTC 1970, but local day is outside the ledger's supported range.
            let time = Date(timeIntervalSince1970: second)
            XCTAssertEqual(ledger.recordSpeed(bikeID: bike, source: .motorcycle, metersPerSecond: 10,
                timestamp: time, receivedAt: time), 0)
        }
        XCTAssertEqual(ledger.totalMeters(bikeID: bike), 0)
        try ledger.validate()
        _ = try JSONEncoder().encode(ledger)
    }
}
