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

    func testLegacy049ServiceJSONKeepsDateAndIdentifiers() throws {
        // Exact non-optional date shape written by the 0.4.9 synthesized encoder.
        let legacy = Data("""
        {"id":"A0587EA3-CB3F-443A-81E2-9BA4CB4D32BD","bikeName":"Ninja 500",
         "odometerKm":25000,"fuelEntries":[],"serviceTasks":[
          {"id":"023C064C-2CA3-45CB-8F03-D6E8C8D8E177","title":"Масло",
           "lastDoneAt":721692800,"lastDoneOdometerKm":23000,
           "intervalKm":3000,"intervalMonths":12}]}
        """.utf8)
        let restored = try JSONDecoder().decode(CompanionData.self, from: legacy)
        try restored.validate()
        XCTAssertEqual(restored.id.uuidString, "A0587EA3-CB3F-443A-81E2-9BA4CB4D32BD")
        let task = try XCTUnwrap(restored.serviceTasks.first)
        XCTAssertEqual(task.id.uuidString, "023C064C-2CA3-45CB-8F03-D6E8C8D8E177")
        XCTAssertEqual(task.lastDoneAt, epoch)
        XCTAssertEqual(task.dueOdometerKm, 26_000)
        XCTAssertNotNil(task.dueDate())
        XCTAssertEqual(try JSONDecoder().decode(CompanionData.self, from: JSONEncoder().encode(restored)), restored)
    }

    func testMissingAndNullServiceDatesDecodeWithoutInventingToday() throws {
        for dateField in ["", "\"lastDoneAt\":null,"] {
            let json = Data("""
            {"id":"023C064C-2CA3-45CB-8F03-D6E8C8D8E177","title":"Масло",
             \(dateField)"lastDoneOdometerKm":23000,"intervalKm":3000}
            """.utf8)
            let task = try JSONDecoder().decode(ServiceTask.self, from: json)
            try task.validate()
            XCTAssertNil(task.lastDoneAt)
            XCTAssertNil(task.dueDate())
            XCTAssertEqual(task.dueOdometerKm, 26_000)
            let roundTrip = try JSONDecoder().decode(ServiceTask.self, from: JSONEncoder().encode(task))
            XCTAssertEqual(roundTrip, task)
            XCTAssertNil(roundTrip.lastDoneAt)
        }
    }

    func testMileageOnlyServiceRequiresNoDateAndTracksManualOdometer() throws {
        let task = ServiceTask(title: "Масло", lastDoneOdometerKm: 23_000, intervalKm: 3_000)
        try task.validate()
        XCTAssertNil(task.lastDoneAt)
        XCTAssertNil(task.dueDate())
        XCTAssertEqual(task.dueOdometerKm, 26_000)
        XCTAssertEqual(task.kilometersRemaining(odometerKm: 25_500), 500)
        XCTAssertEqual(task.kilometersRemaining(odometerKm: 26_200), -200)
        XCTAssertNil(task.kilometersRemaining(odometerKm: nil))
        XCTAssertNil(task.kilometersRemaining(odometerKm: .nan))
        XCTAssertNil(task.kilometersRemaining(odometerKm: -1))
        XCTAssertFalse(task.isDue(odometerKm: 25_999, on: epoch))
        XCTAssertTrue(task.isDue(odometerKm: 26_000, on: epoch))
        XCTAssertFalse(task.isDue(odometerKm: nil, on: epoch.addingTimeInterval(100_000_000)))
    }

    func testMonthIntervalRequiresKnownDateWithoutInventingOne() throws {
        var task = ServiceTask(title: "Тормозная жидкость", lastDoneOdometerKm: 23_000, intervalMonths: 24)
        XCTAssertThrowsError(try task.validate()) {
            XCTAssertEqual($0 as? CompanionValidationError, .missingServiceDate)
        }
        XCTAssertNil(task.dueDate())
        task.lastDoneAt = epoch
        XCTAssertNoThrow(try task.validate())
        XCTAssertNotNil(task.dueDate())
        task.lastDoneAt = nil
        task.intervalMonths = nil
        task.intervalKm = 5_000
        XCTAssertNoThrow(try task.validate())
        XCTAssertNil(task.dueDate())
        task.lastDoneAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertThrowsError(try task.validate()) {
            XCTAssertEqual($0 as? CompanionValidationError, .invalidDate)
        }
    }

    func testDateUnknownServiceCanBeAddedEditedAndDeletedWithoutTouchingFuel() throws {
        let fuel = fill(1, 24_000, 10)
        var data = CompanionData(bikeName: "Тахиро", odometerKm: 25_000, fuelEntries: [fuel])
        let task = ServiceTask(title: "Масло", lastDoneOdometerKm: 23_000, intervalKm: 3_000)
        try data.addServiceTask(task)
        XCTAssertEqual(data.serviceTasks.first?.dueOdometerKm, 26_000)
        data.serviceTasks[0].lastDoneOdometerKm = 26_000
        data.serviceTasks[0].title = "Масло и фильтр"
        try data.validate()
        XCTAssertEqual(data.serviceTasks[0].id, task.id)
        XCTAssertNil(data.serviceTasks[0].lastDoneAt)
        XCTAssertEqual(data.serviceTasks[0].dueOdometerKm, 29_000)
        let restored = try JSONDecoder().decode(CompanionData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(restored, data)
        data.serviceTasks.removeAll { $0.id == task.id }
        try data.validate()
        XCTAssertTrue(data.serviceTasks.isEmpty)
        XCTAssertEqual(data.fuelEntries, [fuel])
        XCTAssertEqual(data.odometerKm, 25_000)
        XCTAssertEqual(data.bikeName, "Тахиро")
    }

    func testMileageReminderUsesLastTenPercentCappedAtFiveHundredKm() {
        let oil = ServiceTask(title: "Масло", lastDoneOdometerKm: 23_000, intervalKm: 3_000)
        XCTAssertFalse(oil.isDueSoon(odometerKm: 25_699, on: epoch))
        XCTAssertTrue(oil.isDueSoon(odometerKm: 25_700, on: epoch))
        XCTAssertTrue(oil.isDueSoon(odometerKm: 25_999, on: epoch))
        XCTAssertFalse(oil.isDueSoon(odometerKm: 26_000, on: epoch))
        XCTAssertFalse(oil.isDueSoon(odometerKm: nil, on: epoch))
        let large = ServiceTask(title: "Осмотр", lastDoneOdometerKm: 0, intervalKm: 20_000)
        XCTAssertFalse(large.isDueSoon(odometerKm: 19_499, on: epoch))
        XCTAssertTrue(large.isDueSoon(odometerKm: 19_500, on: epoch))
        let chain = ServiceTask(title: "Цепь", lastDoneOdometerKm: 0, intervalKm: 500)
        XCTAssertFalse(chain.isDueSoon(odometerKm: 449, on: epoch))
        XCTAssertTrue(chain.isDueSoon(odometerKm: 450, on: epoch))
    }

    func testCalendarReminderUsesLocalDaysAndOverdueHasSeparateStatus() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 18)))
        let task = ServiceTask(title: "Осмотр", lastDoneAt: start, lastDoneOdometerKm: 0, intervalMonths: 1)
        let due = try XCTUnwrap(task.dueDate(calendar: calendar))
        let seven = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: due))
        let eight = try XCTUnwrap(calendar.date(byAdding: .day, value: -8, to: due))
        XCTAssertFalse(task.isDueSoon(odometerKm: nil, on: eight, calendar: calendar))
        XCTAssertTrue(task.isDueSoon(odometerKm: nil, on: seven, calendar: calendar))
        XCTAssertFalse(task.isDueSoon(odometerKm: nil, on: due, calendar: calendar))
        XCTAssertTrue(task.isDue(odometerKm: nil, on: due, calendar: calendar))
    }

    func testLegacyFuelNumbersAndFixedServiceIntervalDecodeUnchanged() throws {
        let json = Data("""
        {"id":"A0587EA3-CB3F-443A-81E2-9BA4CB4D32BD","bikeName":"Тахиро",
         "odometerKm":25000,"fuelEntries":[
          {"id":"0593799B-F04D-4DE3-A32A-6D1F504ED061","date":721692800,
           "odometerKm":25000,"liters":9.25,"cost":650,"fullTank":true}],
         "serviceTasks":[{"id":"023C064C-2CA3-45CB-8F03-D6E8C8D8E177",
          "title":"Масло","lastDoneOdometerKm":23000,"intervalKm":3000}]}
        """.utf8)
        let restored = try JSONDecoder().decode(CompanionData.self, from: json)
        try restored.validate()
        let fuel = try XCTUnwrap(restored.fuelEntries.first)
        XCTAssertEqual(fuel.liters, 9.25)
        XCTAssertEqual(fuel.cost, 650)
        XCTAssertEqual(fuel.date, epoch)
        let task = try XCTUnwrap(restored.serviceTasks.first)
        XCTAssertNil(task.intervalStartKm)
        XCTAssertEqual(task.dueOdometerKm, 26_000)
        XCTAssertFalse(task.isDueSoon(odometerKm: 25_699, on: epoch))
        XCTAssertTrue(task.isDueSoon(odometerKm: 25_700, on: epoch))
        XCTAssertEqual(try JSONDecoder().decode(CompanionData.self, from: JSONEncoder().encode(restored)), restored)
    }

    func testUnknownFullTankRoundTripsWithoutInventingLitersOrCost() throws {
        for cost in [nil, 900.0] as [Double?] {
            let entry = FuelEntry(date: epoch, odometerKm: 25_000, cost: cost)
            try entry.validate()
            let encoded = try JSONEncoder().encode(entry)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(object["liters"])
            XCTAssertEqual(try JSONDecoder().decode(FuelEntry.self, from: encoded), entry)
        }
        for litersField in ["", "\"liters\":null,"] {
            let json = Data("""
            {"id":"0593799B-F04D-4DE3-A32A-6D1F504ED061","date":721692800,
             "odometerKm":25000,\(litersField)"fullTank":true}
            """.utf8)
            let entry = try JSONDecoder().decode(FuelEntry.self, from: json)
            try entry.validate()
            XCTAssertNil(entry.liters)
            XCTAssertNil(entry.cost)
        }
    }

    func testUnknownLitersRequireFullTankButKnownPartialIsValid() {
        XCTAssertThrowsError(try FuelEntry(date: epoch, odometerKm: 1, fullTank: false).validate()) {
            XCTAssertEqual($0 as? CompanionValidationError, .invalidLiters)
        }
        XCTAssertNoThrow(try FuelEntry(date: epoch, odometerKm: 1, liters: 2.5, fullTank: false).validate())
        for invalid in [0.0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try FuelEntry(date: epoch, odometerKm: 1, liters: invalid).validate())
        }
        for invalidCost in [-1.0, .nan, .infinity] {
            XCTAssertThrowsError(try FuelEntry(date: epoch, odometerKm: 1, cost: invalidCost).validate())
        }
    }

    func testUnknownStartingFullTankStillProvidesConsumptionBaseline() throws {
        let start = FuelEntry(date: epoch, odometerKm: 1000)
        let data = CompanionData(fuelEntries: [start, fill(1, 1100, 3, full: false), fill(2, 1300, 6)])
        try data.validate()
        let consumption = try XCTUnwrap(data.latestFullTankConsumption)
        XCTAssertEqual(consumption.fromEntryID, start.id)
        XCTAssertEqual(consumption.liters, 9)
        XCTAssertEqual(consumption.litersPer100Km, 3, accuracy: 0.00001)
    }

    func testUnknownFullFillBreaksCalculationAndRestartsAtItsFullLevel() throws {
        let first = fill(0, 1000, 10)
        let knownFull = fill(1, 1200, 6)
        let unknownFull = FuelEntry(date: epoch.addingTimeInterval(3 * 86_400), odometerKm: 1500)
        var data = CompanionData(fuelEntries: [first, knownFull, fill(2, 1300, 4, full: false), unknownFull])
        try data.validate()
        XCTAssertEqual(data.fuelConsumptions.count, 1)
        XCTAssertEqual(data.fuelConsumptions.first?.toEntryID, knownFull.id)
        XCTAssertNil(data.latestFullTankConsumption, "Older valid consumption must not appear to describe the unknown ending fill")
        try data.addFuelEntry(fill(4, 1600, 3, full: false))
        XCTAssertNil(data.latestFullTankConsumption)
        let nextFull = fill(5, 1800, 9)
        try data.addFuelEntry(nextFull)
        let latest = try XCTUnwrap(data.latestFullTankConsumption)
        XCTAssertEqual(data.fuelConsumptions.count, 2)
        XCTAssertEqual(latest.fromEntryID, unknownFull.id)
        XCTAssertEqual(latest.toEntryID, nextFull.id)
        XCTAssertEqual(latest.distanceKm, 300)
        XCTAssertEqual(latest.liters, 12, "Liters before the unknown full fill must not cross its boundary")
    }

    func testEditingUnknownAmountRecalculatesWithoutChangingManualOdometer() throws {
        let unknown = FuelEntry(date: epoch.addingTimeInterval(86_400), odometerKm: 1300)
        var data = CompanionData(odometerKm: 1400, fuelEntries: [fill(0, 1000, 12), unknown])
        XCTAssertNil(data.latestFullTankConsumption)
        data.fuelEntries[1].liters = 9
        try data.validate()
        XCTAssertEqual(data.latestFullTankConsumption?.litersPer100Km, 3)
        data.fuelEntries[1].liters = nil
        try data.validate()
        XCTAssertNil(data.latestFullTankConsumption)
        XCTAssertEqual(data.currentOdometerKm, 1400)
        XCTAssertEqual(data.fuelEntries[1].id, unknown.id)
    }

    func testServiceRangeWarnsAtMinimumAndIsDueAtMaximumWithoutDate() throws {
        let task = ServiceTask(title: "Масло", lastDoneOdometerKm: 23_000,
                               intervalKm: 4_000, intervalStartKm: 3_000)
        try task.validate()
        XCTAssertNil(task.lastDoneAt)
        XCTAssertNil(task.dueDate())
        XCTAssertEqual(task.rangeStartOdometerKm, 26_000)
        XCTAssertEqual(task.dueOdometerKm, 27_000)
        for reading in [23_000.0, 25_700, 25_999] {
            XCTAssertFalse(task.isDueSoon(odometerKm: reading, on: epoch))
            XCTAssertFalse(task.isDue(odometerKm: reading, on: epoch))
        }
        for reading in [26_000.0, 26_999] {
            XCTAssertTrue(task.isDueSoon(odometerKm: reading, on: epoch))
            XCTAssertFalse(task.isDue(odometerKm: reading, on: epoch))
        }
        for reading in [27_000.0, 28_000] {
            XCTAssertFalse(task.isDueSoon(odometerKm: reading, on: epoch))
            XCTAssertTrue(task.isDue(odometerKm: reading, on: epoch))
        }
        XCTAssertEqual(task.kilometersRemaining(odometerKm: 26_500), 500)
        XCTAssertFalse(task.isDueSoon(odometerKm: nil, on: epoch))
    }

    func testServiceRangeMileageProgressClampsAndRequiresKnownReading() throws {
        let task = ServiceTask(title: "Масло", lastDoneOdometerKm: 23_000,
                               intervalKm: 4_000, intervalStartKm: 3_000)
        XCTAssertEqual(task.mileageProgress(odometerKm: 22_000), 0)
        XCTAssertEqual(task.mileageProgress(odometerKm: 23_000), 0)
        XCTAssertEqual(task.mileageProgress(odometerKm: 26_000), 0.75)
        XCTAssertEqual(task.mileageProgress(odometerKm: 27_000), 1)
        XCTAssertEqual(task.mileageProgress(odometerKm: 28_000), 1)
        for invalid in [nil, Double.nan, Double.infinity, -1] as [Double?] {
            XCTAssertNil(task.mileageProgress(odometerKm: invalid))
        }
        let calendarOnly = ServiceTask(title: "Осмотр", lastDoneAt: epoch, lastDoneOdometerKm: 0, intervalMonths: 1)
        XCTAssertNil(calendarOnly.mileageProgress(odometerKm: 1000))
    }

    func testMalformedServiceRangeIsRejectedInsteadOfBecomingFixedInterval() {
        for lower in [0.0, -1, 4_000, 5_000, .nan, .infinity] {
            let task = ServiceTask(title: "Масло", lastDoneOdometerKm: 23_000,
                                   intervalKm: 4_000, intervalStartKm: lower)
            XCTAssertThrowsError(try task.validate()) {
                XCTAssertEqual($0 as? CompanionValidationError, .invalidIntervalRange)
            }
            XCTAssertFalse(task.isDue(odometerKm: 50_000, on: epoch))
            XCTAssertFalse(task.isDueSoon(odometerKm: 26_000, on: epoch))
            XCTAssertNil(task.rangeStartOdometerKm)
            XCTAssertNil(task.mileageProgress(odometerKm: 26_000))
        }
        let missingUpper = ServiceTask(title: "Масло", lastDoneAt: epoch, lastDoneOdometerKm: 23_000,
                                       intervalStartKm: 3_000, intervalMonths: 12)
        XCTAssertThrowsError(try missingUpper.validate()) {
            XCTAssertEqual($0 as? CompanionValidationError, .invalidIntervalRange)
        }
        let overflowing = ServiceTask(title: "Осмотр", lastDoneOdometerKm: .greatestFiniteMagnitude,
                                       intervalKm: .greatestFiniteMagnitude, intervalStartKm: 3_000)
        XCTAssertThrowsError(try overflowing.validate())
    }

    func testServiceRangeAndOptionalDateRoundTripAndMoveAfterCompletion() throws {
        var task = ServiceTask(title: "Масло", lastDoneOdometerKm: 23_000,
                               intervalKm: 4_000, intervalStartKm: 3_000)
        let decoded = try JSONDecoder().decode(ServiceTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)
        task.lastDoneOdometerKm = 26_500
        try task.validate()
        XCTAssertEqual(task.rangeStartOdometerKm, 29_500)
        XCTAssertEqual(task.dueOdometerKm, 30_500)
        XCTAssertNil(task.lastDoneAt)
        XCTAssertEqual(task.id, decoded.id)
        task.intervalStartKm = nil
        try task.validate()
        XCTAssertNil(task.rangeStartOdometerKm)
        XCTAssertFalse(task.isDueSoon(odometerKm: 29_500, on: epoch))
        XCTAssertTrue(task.isDueSoon(odometerKm: 30_100, on: epoch))
    }

    func testCalendarDeadlineStillWinsOverMileageRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let task = ServiceTask(title: "Масло", lastDoneAt: epoch, lastDoneOdometerKm: 23_000,
                               intervalKm: 4_000, intervalStartKm: 3_000, intervalMonths: 1)
        let deadline = try XCTUnwrap(task.dueDate(calendar: calendar))
        let warning = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: deadline))
        XCTAssertTrue(task.isDueSoon(odometerKm: 24_000, on: warning, calendar: calendar))
        XCTAssertFalse(task.isDue(odometerKm: 24_000, on: warning, calendar: calendar))
        XCTAssertTrue(task.isDue(odometerKm: 24_000, on: deadline, calendar: calendar))
    }
}
