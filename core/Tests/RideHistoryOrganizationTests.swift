import Foundation
import XCTest
@testable import MotoLinkCore

final class RideHistoryOrganizationTests: XCTestCase {
    private struct Item: RideHistoryItem {
        let id: UUID
        let startedAt: Date
        var isFavorite = false
    }
    private func calendar(zone: String = "UTC", firstWeekday: Int = 2) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = firstWeekday
        value.minimumDaysInFirstWeek = 4
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12,
                      in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func item(_ at: Date, favorite: Bool = false) -> Item {
        Item(id: UUID(), startedAt: at, isFavorite: favorite)
    }

    func testCurrentWeekOpensDaysAndPreviousSundayRemainsInCollapsedPreviousWeek() {
        let calendar = calendar(), now = date(2026, 10, 5, in: calendar)
        let monday = item(date(2026, 10, 5, hour: 0, in: calendar))
        let sunday = item(date(2026, 10, 4, hour: 23, in: calendar))
        let groups = RideHistoryOrganization.groups([sunday, monday], at: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.rides).flatMap { $0 }.map(\.id), [monday.id, sunday.id])
        XCTAssertEqual(groups[0].bucket, .day(calendar.startOfDay(for: monday.startedAt)))
        XCTAssertTrue(groups[0].bucket.initiallyExpanded)
        XCTAssertEqual(groups[1].bucket, .previousWeek(date(2026, 9, 28, hour: 0, in: calendar)))
        XCTAssertFalse(groups[1].bucket.initiallyExpanded)
    }

    func testCurrentWeekIsGroupedByCalendarDayWithNewestRidesFirst() {
        let calendar = calendar(), now = date(2026, 10, 8, in: calendar)
        let morning = item(date(2026, 10, 8, hour: 8, in: calendar))
        let evening = item(date(2026, 10, 8, hour: 20, in: calendar))
        let previous = item(date(2026, 10, 7, in: calendar))
        let groups = RideHistoryOrganization.groups([morning, previous, evening], at: now, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].rides.map(\.id), [evening.id, morning.id])
        XCTAssertEqual(groups[1].rides.map(\.id), [previous.id])
        XCTAssertTrue(groups.allSatisfy { $0.bucket.initiallyExpanded })
    }

    func testPreviousWeekCrossingNewYearIsOneGroupInsteadOfTwoMonths() {
        let calendar = calendar(), now = date(2026, 1, 5, in: calendar)
        let december = item(date(2025, 12, 31, in: calendar))
        let january = item(date(2026, 1, 4, in: calendar))
        let older = item(date(2025, 12, 20, in: calendar))
        let groups = RideHistoryOrganization.groups([december, january, older], at: now, calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].bucket, .previousWeek(date(2025, 12, 29, hour: 0, in: calendar)))
        XCTAssertEqual(groups[0].rides.map(\.id), [january.id, december.id])
        XCTAssertEqual(groups[1].bucket, .month(date(2025, 12, 1, hour: 0, in: calendar)))
        XCTAssertFalse(groups[1].bucket.initiallyExpanded)
    }

    func testFavoritesArePinnedFirstAndNeverDuplicatedInTheirDateGroups() {
        let calendar = calendar(), now = date(2026, 10, 8, in: calendar)
        let today = item(now)
        var older = item(date(2026, 8, 20, in: calendar), favorite: true)
        let groups = RideHistoryOrganization.groups([today, older], at: now, calendar: calendar)
        XCTAssertEqual(groups[0].bucket, .favorites)
        XCTAssertTrue(groups[0].bucket.initiallyExpanded)
        XCTAssertEqual(groups[0].rides.map(\.id), [older.id])
        XCTAssertEqual(groups.flatMap(\.rides).count, 2)
        XCTAssertEqual(Set(groups.flatMap(\.rides).map(\.id)).count, 2)
        older.isFavorite = false
        let unpinned = RideHistoryOrganization.groups([today, older], at: now, calendar: calendar)
        XCTAssertFalse(unpinned.contains { $0.bucket == .favorites })
        XCTAssertEqual(unpinned.last?.bucket, .month(date(2026, 8, 1, hour: 0, in: calendar)))
    }

    func testSundayFirstWeekCalendarUsesItsOwnWeekBoundary() {
        let sundayCalendar = calendar(firstWeekday: 1)
        let mondayCalendar = calendar(firstWeekday: 2)
        let now = date(2026, 10, 4, in: sundayCalendar)
        let saturday = item(date(2026, 10, 3, in: sundayCalendar))
        let sundayFirst = RideHistoryOrganization.groups([saturday], at: now, calendar: sundayCalendar)
        let mondayFirst = RideHistoryOrganization.groups([saturday], at: now, calendar: mondayCalendar)
        XCTAssertFalse(sundayFirst[0].bucket.initiallyExpanded)
        XCTAssertTrue(mondayFirst[0].bucket.initiallyExpanded)
    }

    func testMidnightAndDaylightSavingUseCalendarBoundariesNotFixedSeconds() {
        let calendar = calendar(zone: "America/Los_Angeles")
        let now = date(2026, 11, 2, in: calendar)
        let lastSunday = item(date(2026, 11, 1, hour: 23, in: calendar))
        let monday = item(date(2026, 11, 2, hour: 0, in: calendar))
        let groups = RideHistoryOrganization.groups([lastSunday, monday], at: now, calendar: calendar)
        XCTAssertEqual(groups[0].bucket, .day(calendar.startOfDay(for: monday.startedAt)))
        XCTAssertEqual(groups[1].bucket, .previousWeek(date(2026, 10, 26, hour: 0, in: calendar)))
        let previousWeek = calendar.dateInterval(of: .weekOfYear, for: lastSunday.startedAt)!
        XCTAssertEqual(previousWeek.duration, 7 * 86400 + 3600)
    }

    func testTimeZoneChangesDayKeyWithoutLosingTheRide() {
        let utc = calendar(), tokyo = calendar(zone: "Asia/Tokyo")
        let at = date(2026, 10, 7, hour: 23, in: utc)
        let ride = item(at)
        let now = at.addingTimeInterval(3600)
        let first = RideHistoryOrganization.groups([ride], at: now, calendar: utc)[0]
        let second = RideHistoryOrganization.groups([ride], at: now, calendar: tokyo)[0]
        XCTAssertEqual(first.rides.map(\.id), second.rides.map(\.id))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.bucket, .day(tokyo.startOfDay(for: at)))
    }

    func testRefreshReorderingKeepsStableGroupIDsAndEqualTimestampOrder() {
        let calendar = calendar(), now = date(2026, 10, 8, in: calendar)
        let first = Item(id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!, startedAt: now)
        let second = Item(id: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!, startedAt: now)
        let original = RideHistoryOrganization.groups([second, first], at: now, calendar: calendar)
        let refreshed = RideHistoryOrganization.groups([first, second], at: now, calendar: calendar)
        XCTAssertEqual(original.map(\.id), refreshed.map(\.id))
        XCTAssertEqual(original[0].rides.map(\.id), [first.id, second.id])
        XCTAssertEqual(original[0].rides.map(\.id), refreshed[0].rides.map(\.id))
    }

    func testLargeArchiveRetainsEveryRideWithoutAGlobalThirtyRideCutoff() {
        let calendar = calendar(), now = date(2026, 10, 8, in: calendar)
        let rides = (0..<1000).map { index in
            item(calendar.date(byAdding: .day, value: -index, to: now)!, favorite: index % 100 == 0)
        }
        let groups = RideHistoryOrganization.groups(rides, at: now, calendar: calendar)
        XCTAssertEqual(groups.flatMap(\.rides).count, rides.count)
        XCTAssertEqual(Set(groups.flatMap(\.rides).map(\.id)), Set(rides.map(\.id)))
        XCTAssertEqual(groups[0].bucket, .favorites)
        XCTAssertEqual(groups[0].rides.count, 10)
        XCTAssertTrue(groups.contains { $0.rides.count > 30 })
    }

    func testEmptyArchiveHasNoEmptyHeaders() {
        let groups = RideHistoryOrganization.groups([Item]())
        XCTAssertTrue(groups.isEmpty)
    }
}
