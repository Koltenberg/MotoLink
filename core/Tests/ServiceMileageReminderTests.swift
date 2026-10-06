import XCTest
@testable import MotoLinkCore

final class ServiceMileageReminderTests: XCTestCase {
    private func oil() -> ServiceTask {
        ServiceTask(title: "Масло", lastDoneOdometerKm: 23_000,
                    intervalKm: 4_000, intervalStartKm: 3_000, intervalDueKm: 3_500)
    }

    func testThreeStagesUseExactUserBoundariesWithoutCalendarDate() throws {
        let task = oil()
        try task.validate()
        XCTAssertNil(task.lastDoneAt)
        XCTAssertNil(task.dueDate())
        XCTAssertNil(task.mileageStage(odometerKm: 25_999.99))
        XCTAssertEqual(task.mileageStage(odometerKm: 26_000), .soon)
        XCTAssertEqual(task.mileageStage(odometerKm: 26_499.99), .soon)
        XCTAssertEqual(task.mileageStage(odometerKm: 26_500), .due)
        XCTAssertEqual(task.mileageStage(odometerKm: 26_999.99), .due)
        XCTAssertEqual(task.mileageStage(odometerKm: 27_000), .overdue)
        XCTAssertEqual(task.mileageStage(odometerKm: 29_000), .overdue)
        XCTAssertTrue(task.isDueSoon(odometerKm: 26_000))
        XCTAssertFalse(task.isDueSoon(odometerKm: 26_500))
        XCTAssertTrue(task.isDue(odometerKm: 26_500))
        XCTAssertEqual(task.targetOdometerKm, 26_500)
        XCTAssertEqual(task.dueOdometerKm, 27_000)
    }

    func testThresholdsAcceptSingleKilometerPrecisionAndRejectUnorderedMiddle() throws {
        var task = oil()
        task.intervalStartKm = 3_001
        task.intervalDueKm = 3_002
        task.intervalKm = 3_003
        try task.validate()
        XCTAssertEqual(task.mileageStage(odometerKm: 26_002), .due)
        for middle in [0.0, -1, 3_001, 3_003, .nan, .infinity] {
            task.intervalDueKm = middle
            XCTAssertThrowsError(try task.validate())
            XCTAssertNil(task.mileageStage(odometerKm: 99_999))
        }
        task = oil()
        task.intervalStartKm = nil
        XCTAssertThrowsError(try task.validate())
        task = oil()
        task.intervalKm = nil
        XCTAssertThrowsError(try task.validate())
        for reading in [nil, Double.nan, Double.infinity, -1] as [Double?] {
            XCTAssertNil(oil().mileageStage(odometerKm: reading))
        }
    }

    func testLegacyJSONAndTwoStageSemanticsAreUnchanged() throws {
        let json = Data("""
        {"id":"E3B8859E-0190-4021-A8E6-71324676ADEB","title":"Масло",
         "lastDoneOdometerKm":23000,"intervalKm":4000,"intervalStartKm":3000}
        """.utf8)
        var task = try JSONDecoder().decode(ServiceTask.self, from: json)
        try task.validate()
        XCTAssertNil(task.intervalDueKm)
        XCTAssertEqual(task.mileageStage(odometerKm: 26_500), .soon)
        XCTAssertEqual(task.mileageStage(odometerKm: 27_000), .due)
        XCTAssertEqual(task.mileageStage(odometerKm: 28_000), .due)
        task.intervalStartKm = nil
        XCTAssertNil(task.mileageStage(odometerKm: 26_599))
        XCTAssertEqual(task.mileageStage(odometerKm: 26_600), .soon)
        XCTAssertEqual(task.mileageStage(odometerKm: 27_000), .due)
        XCTAssertEqual(try JSONDecoder().decode(ServiceTask.self, from: JSONEncoder().encode(oil())).intervalDueKm, 3_500)
    }

    func testOnlySuccessfulAcknowledgementSuppressesFutureNotification() throws {
        let task = oil()
        var ledger = ServiceMileageReminderLedger()
        XCTAssertEqual(ledger.pendingStage(for: task, odometerKm: 26_000), .soon)
        // Merely evaluating a candidate (or a denied/failed add) is not a receipt.
        XCTAssertEqual(ledger.pendingStage(for: task, odometerKm: 26_001), .soon)
        ledger.acknowledge(.soon, for: task)
        XCTAssertNil(ledger.pendingStage(for: task, odometerKm: 26_001))
        XCTAssertEqual(ledger.pendingStage(for: task, odometerKm: 26_500), .due)
        ledger.acknowledge(.due, for: task)
        ledger = try JSONDecoder().decode(ServiceMileageReminderLedger.self, from: JSONEncoder().encode(ledger))
        for reading in [25_000.0, 26_000, 26_500, 26_999] {
            XCTAssertNil(ledger.pendingStage(for: task, odometerKm: reading), "A corrected estimate must not repeat a stage")
        }
        XCTAssertEqual(ledger.pendingStage(for: task, odometerKm: 27_000), .overdue)
        ledger.acknowledge(.overdue, for: task)
        ledger.acknowledge(.soon, for: task)
        XCTAssertNil(ledger.pendingStage(for: task, odometerKm: 27_500))
    }

    func testJumpToOverdueSendsOneStageInsteadOfBacklog() {
        let task = oil()
        var ledger = ServiceMileageReminderLedger()
        XCTAssertEqual(ledger.pendingStage(for: task, odometerKm: 28_000), .overdue)
        ledger.acknowledge(.overdue, for: task)
        XCTAssertEqual(ledger.receipts.count, 1)
        XCTAssertNil(ledger.pendingStage(for: task, odometerKm: 26_500))
    }

    func testServiceCompletionAndNewConfigurationAllowReminderButRevertAndRenameDoNot() {
        var task = oil()
        var ledger = ServiceMileageReminderLedger()
        ledger.acknowledge(.due, for: task)
        task.title = "Масло и фильтр"
        XCTAssertNil(ledger.pendingStage(for: task, odometerKm: 26_500))
        task.intervalDueKm = 3_400
        XCTAssertEqual(ledger.pendingStage(for: task, odometerKm: 26_500), .due)
        ledger.acknowledge(.due, for: task)
        task.intervalDueKm = 3_500
        XCTAssertNil(ledger.pendingStage(for: task, odometerKm: 26_500))
        task.lastDoneOdometerKm = 26_500
        XCTAssertNil(ledger.pendingStage(for: task, odometerKm: 26_500))
        XCTAssertEqual(ledger.pendingStage(for: task, odometerKm: 29_500), .soon)
        var another = task
        another.id = UUID()
        XCTAssertEqual(ledger.pendingStage(for: another, odometerKm: 29_500), .soon)
    }

    func testCalendarOnlyTaskCannotGenerateMileageNotification() {
        let task = ServiceTask(title: "Осмотр", lastDoneAt: Date(timeIntervalSince1970: 1_700_000_000),
                               lastDoneOdometerKm: 0, intervalMonths: 12)
        var ledger = ServiceMileageReminderLedger()
        XCTAssertNil(ledger.pendingStage(for: task, odometerKm: 100_000))
        ledger.acknowledge(.due, for: task)
        XCTAssertTrue(ledger.receipts.isEmpty)
    }
}
