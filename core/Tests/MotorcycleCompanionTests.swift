import XCTest
@testable import MotoLinkCore

final class MotorcycleCompanionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func fill(_ day: Double, _ odometer: Double, _ liters: Double,
                      full: Bool = true, cost: Double? = nil) -> FuelEntry {
        FuelEntry(date: epoch.addingTimeInterval(day * 86_400), odometerKm: odometer,
                  liters: liters, cost: cost, fullTank: full)
    }

    func testFullToFullIncludesPartialFillsButExcludesStartingFuelAndOpenTail() throws {
        let beforeBaseline = fill(0, 900, 3, full: false)
        let start = fill(1, 1000, 12)
        let partial = fill(2, 1100, 4, full: false)
        let end = fill(3, 1300, 8)
        let tail = fill(4, 1400, 3, full: false)
        let data = CompanionData(fuelEntries: [tail, end, start, beforeBaseline, partial])
        try data.validate()
        let interval = try XCTUnwrap(data.fuelConsumptions.first)
        XCTAssertEqual(data.fuelConsumptions.count, 1)
        XCTAssertEqual(interval.fromEntryID, start.id)
        XCTAssertEqual(interval.toEntryID, end.id)
        XCTAssertEqual(interval.distanceKm, 300)
        XCTAssertEqual(interval.liters, 12)
        XCTAssertEqual(interval.litersPer100Km, 4, accuracy: 0.00001)
    }

    func testConsecutiveFullFillsMakeSeparateIntervalsAndNoInventedBaseline() {
        let data = CompanionData(fuelEntries: [fill(1, 1000, 10), fill(2, 1200, 6), fill(3, 1500, 12)])
        XCTAssertEqual(data.fuelConsumptions.map(\.litersPer100Km), [3, 4])
        XCTAssertTrue(CompanionData(fuelEntries: [fill(1, 1000, 5, full: false), fill(2, 1200, 7)]).fuelConsumptions.isEmpty)
        XCTAssertTrue(CompanionData(fuelEntries: [fill(1, 1000, 5)]).fuelConsumptions.isEmpty)
    }

    func testDuplicateAndDecreasingOdometersRejectTheWholeCalculation() {
        for middle in [1000.0, 999, 1400] {
            let data = CompanionData(fuelEntries: [fill(1, 1000, 9), fill(2, middle, 3, full: false), fill(3, 1300, 9)])
            XCTAssertThrowsError(try data.validate()) {
                XCTAssertEqual($0 as? CompanionValidationError, .nonIncreasingOdometer)
            }
            XCTAssertTrue(data.fuelConsumptions.isEmpty)
        }
    }

    func testMalformedFuelValuesAndCostsCannotProduceConsumption() {
        for liters in [0.0, -1, .nan, .infinity] {
            let data = CompanionData(fuelEntries: [fill(1, 1000, 10), fill(2, 1300, liters)])
            XCTAssertThrowsError(try data.validate())
            XCTAssertTrue(data.fuelConsumptions.isEmpty)
        }
        for cost in [-1.0, .nan, .infinity] {
            XCTAssertThrowsError(try fill(1, 1000, 10, cost: cost).validate())
        }
        for odometer in [-1.0, .nan, .infinity] {
            XCTAssertThrowsError(try fill(1, odometer, 10).validate())
        }
        XCTAssertNoThrow(try fill(1, 0, 10, cost: 0).validate())
        XCTAssertThrowsError(try FuelEntry(date: Date(timeIntervalSince1970: .nan), odometerKm: 1, liters: 1).validate())
    }

    func testRetrospectiveInsertionIsValidatedAndFailedInsertionIsAtomic() throws {
        var data = CompanionData(fuelEntries: [fill(1, 1000, 10), fill(3, 1300, 9)])
        try data.addFuelEntry(fill(2, 1100, 3, full: false))
        XCTAssertEqual(data.fuelConsumptions.first?.liters, 12)
        let previous = data
        XCTAssertThrowsError(try data.addFuelEntry(fill(2.5, 1050, 2)))
        XCTAssertEqual(data, previous)
        XCTAssertThrowsError(try data.addFuelEntry(data.fuelEntries[0])) {
            XCTAssertEqual($0 as? CompanionValidationError, .duplicateIdentifier)
        }
        XCTAssertEqual(data, previous)
    }

    func testSameTimestampCanRepresentMultipleOrderedFillsButNeverDuplicateOdometers() throws {
        let data = CompanionData(fuelEntries: [fill(1, 1300, 9), fill(1, 1000, 10)])
        try data.validate()
        XCTAssertEqual(data.fuelConsumptions.first?.litersPer100Km, 3)
        XCTAssertThrowsError(try CompanionData(fuelEntries: [fill(1, 1000, 9), fill(1, 1000, 10)]).validate())
    }

    func testCurrentOdometerUsesManualReadingsFromAllSourcesWithoutAddingDistances() {
        let task = ServiceTask(title: "Цепь", lastDoneAt: epoch, lastDoneOdometerKm: 1800, intervalKm: 500)
        var data = CompanionData(odometerKm: 1200, fuelEntries: [fill(1, 1500, 10)], serviceTasks: [task])
        XCTAssertEqual(data.currentOdometerKm, 1800)
        data.odometerKm = 2000
        XCTAssertEqual(data.currentOdometerKm, 2000)
        XCTAssertNil(CompanionData().currentOdometerKm)
        XCTAssertEqual(CompanionData(odometerKm: 0).currentOdometerKm, 0)
        XCTAssertNil(CompanionData(odometerKm: .nan).currentOdometerKm)
    }

    func testServiceUsesWhicheverUserDefinedLimitComesFirstAndCalendarMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let january31 = calendar.date(from: DateComponents(year: 2024, month: 1, day: 31, hour: 18))!
        let february29 = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))!
        let task = ServiceTask(title: "Масло", lastDoneAt: january31, lastDoneOdometerKm: 1000,
                               intervalKm: 500, intervalMonths: 1)
        try task.validate()
        XCTAssertEqual(task.dueOdometerKm, 1500)
        XCTAssertEqual(task.dueDate(calendar: calendar), february29.addingTimeInterval(18 * 3600))
        XCTAssertFalse(task.isDue(odometerKm: 1499, on: january31, calendar: calendar))
        XCTAssertTrue(task.isDue(odometerKm: 1500, on: january31, calendar: calendar))
        XCTAssertTrue(task.isDue(odometerKm: nil, on: february29, calendar: calendar))
        XCTAssertFalse(task.isDue(odometerKm: 1499, on: february29.addingTimeInterval(-1), calendar: calendar))
    }

    func testServiceRequiresAtLeastOneIntervalAndInvalidInputsAreRejected() throws {
        let task = ServiceTask(title: "Осмотр", lastDoneAt: epoch, lastDoneOdometerKm: 1000)
        XCTAssertThrowsError(try task.validate()) {
            XCTAssertEqual($0 as? CompanionValidationError, .invalidInterval)
        }
        XCTAssertNil(task.dueDate())
        XCTAssertNil(task.dueOdometerKm)
        XCTAssertFalse(task.isDue(odometerKm: 100_000, on: epoch.addingTimeInterval(86_400)))
        var calendarOnly = task
        calendarOnly.intervalMonths = 1
        XCTAssertNoThrow(try calendarOnly.validate())
        var distanceOnly = task
        distanceOnly.intervalKm = 500
        XCTAssertNoThrow(try distanceOnly.validate())
        for interval in [0.0, -1, .nan, .infinity] {
            var invalid = task
            invalid.intervalKm = interval
            XCTAssertThrowsError(try invalid.validate())
            XCTAssertFalse(invalid.isDue(odometerKm: 100_000))
        }
        for months in [0, -1] {
            var invalid = task
            invalid.intervalMonths = months
            XCTAssertThrowsError(try invalid.validate())
        }
        var emptyTitle = task
        emptyTitle.title = " \n "
        XCTAssertThrowsError(try emptyTitle.validate())
        var data = CompanionData()
        XCTAssertThrowsError(try data.addServiceTask(task))
        XCTAssertTrue(data.serviceTasks.isEmpty)
        try data.addServiceTask(distanceOnly)
        XCTAssertThrowsError(try data.addServiceTask(distanceOnly))
        XCTAssertEqual(data.serviceTasks, [distanceOnly])
    }

    func testFuelEditsRecomputeAndMalformedEditsNeverKeepPreviousEstimate() throws {
        var data = CompanionData(fuelEntries: [fill(1, 1000, 10), fill(2, 1100, 3, full: false), fill(3, 1300, 9)])
        XCTAssertEqual(data.fuelConsumptions.first?.liters, 12)
        data.fuelEntries[1].liters = 6
        XCTAssertEqual(data.fuelConsumptions.first?.liters, 15)
        data.fuelEntries[1].odometerKm = 1400
        XCTAssertThrowsError(try data.validate())
        XCTAssertTrue(data.fuelConsumptions.isEmpty)
        data.fuelEntries[1].odometerKm = 1100
        data.fuelEntries[1].cost = -1
        XCTAssertTrue(data.fuelConsumptions.isEmpty)
        data.fuelEntries[1].cost = nil
        data.fuelEntries[1].date = epoch.addingTimeInterval(4 * 86_400)
        XCTAssertTrue(data.fuelConsumptions.isEmpty)
        data.fuelEntries[1].date = epoch.addingTimeInterval(2 * 86_400)
        let expected = data.fuelConsumptions
        data.fuelEntries.reverse()
        XCTAssertEqual(data.fuelConsumptions, expected)
        data.fuelEntries[0].fullTank = false
        XCTAssertTrue(data.fuelConsumptions.isEmpty)
    }

    func testDeletingFuelBoundaryDoesNotKeepAStaleIntervalOrInventABaseline() {
        let first = fill(1, 1000, 10)
        let second = fill(2, 1300, 9)
        let third = fill(3, 1600, 12)
        var data = CompanionData(fuelEntries: [first, second, third])
        XCTAssertEqual(data.fuelConsumptions.count, 2)
        data.fuelEntries.removeFirst()
        XCTAssertEqual(data.fuelConsumptions.count, 1)
        XCTAssertEqual(data.fuelConsumptions.first?.fromEntryID, second.id)
        XCTAssertEqual(data.fuelConsumptions.first?.toEntryID, third.id)
        XCTAssertEqual(data.fuelConsumptions.first?.liters, 12)
        data.fuelEntries.removeLast()
        XCTAssertTrue(data.fuelConsumptions.isEmpty)
        data.fuelEntries.removeAll()
        XCTAssertTrue(data.fuelConsumptions.isEmpty)
    }

    func testOverflowDoesNotBecomeAnInfiniteFuelEstimate() {
        let huge = Double.greatestFiniteMagnitude
        let data = CompanionData(fuelEntries: [fill(1, 0, 1), fill(2, 1, huge, full: false), fill(3, 2, huge)])
        XCTAssertTrue(data.fuelConsumptions.isEmpty)
        let tinyDistance = CompanionData(fuelEntries: [fill(1, 0, 1), fill(2, Double.leastNonzeroMagnitude, 1)])
        XCTAssertTrue(tinyDistance.fuelConsumptions.isEmpty)
    }

    func testCodableRoundTripPreservesIDsAndManualEntries() throws {
        let original = CompanionData(bikeName: "Ninja 500", odometerKm: 1500,
            fuelEntries: [fill(1, 1000, 10), fill(2, 1300, 9, cost: 600)],
            serviceTasks: [ServiceTask(title: "Цепь", lastDoneAt: epoch, lastDoneOdometerKm: 1400, intervalKm: 500)])
        let restored = try JSONDecoder().decode(CompanionData.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.fuelConsumptions, original.fuelConsumptions)
        try restored.validate()
    }
}
