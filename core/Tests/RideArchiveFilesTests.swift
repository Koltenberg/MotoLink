import Foundation
import XCTest
@testable import MotoLinkCore

final class RideArchiveFilesTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent("MotoLink-history-test-\(UUID().uuidString)")
        directory = root.appendingPathComponent("rides", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try manager.removeItem(at: root) }

    private func path(_ id: UUID, _ ext: String) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
    }
    @discardableResult private func fixture(_ id: UUID = UUID(), ended: Bool = true) throws -> UUID {
        var summary: [String: Any] = ["id": id.uuidString, "startedAt": "2026-09-24T10:00:00Z",
            "lastSavedAt": "2026-09-24T11:00:00Z", "trigger": "capture", "futureField": ["keep": true]]
        if ended { summary["endedAt"] = "2026-09-24T11:00:00Z" }
        try JSONSerialization.data(withJSONObject: summary).write(to: path(id, "json"))
        try Data("unknown raw packet\n{truncated tail".utf8).write(to: path(id, "jsonl"))
        try Data("[]".utf8).write(to: path(id, "route-estimates"))
        return id
    }

    func testEditingLegacyMetadataPreservesRawAndUnknownFieldsAndCanClearText() throws {
        let id = try fixture(), store = try RideArchiveFiles(directory: directory)
        let raw = try Data(contentsOf: path(id, "jsonl"))
        let changed = try store.updateMetadata(id, title: "  До работы  ", note: "  Потеря GPS  ")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: changed) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "До работы")
        XCTAssertEqual(object["note"] as? String, "Потеря GPS")
        XCTAssertEqual(object["lastSavedAt"] as? String, "2026-09-24T11:00:00Z")
        XCTAssertEqual((object["futureField"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual(try Data(contentsOf: path(id, "jsonl")), raw)
        let cleared = try JSONSerialization.jsonObject(with: store.updateMetadata(id, title: " \n", note: "")) as! [String: Any]
        XCTAssertNil(cleared["title"]); XCTAssertNil(cleared["note"])
        XCTAssertEqual(try Data(contentsOf: path(id, "jsonl")), raw)
    }

    func testTextLimitsRejectWithoutChangingFiles() throws {
        let id = try fixture(), store = try RideArchiveFiles(directory: directory)
        let before = try Data(contentsOf: path(id, "json"))
        XCTAssertThrowsError(try store.updateMetadata(id, title: String(repeating: "ы", count: 81), note: ""))
        XCTAssertThrowsError(try store.updateMetadata(id, title: "", note: String(repeating: "x", count: 4001)))
        XCTAssertEqual(try Data(contentsOf: path(id, "json")), before)
    }

    func testDeleteRemovesOnlyThreeExactUUIDFiles() throws {
        let first = try fixture(), second = try fixture()
        let extra = directory.appendingPathComponent(first.uuidString + ".jsonl.backup")
        try Data("keep".utf8).write(to: extra)
        try RideArchiveFiles(directory: directory).deleteCompletedRide(first)
        for ext in ["json", "jsonl", "route-estimates"] {
            XCTAssertFalse(manager.fileExists(atPath: path(first, ext).path))
            XCTAssertTrue(manager.fileExists(atPath: path(second, ext).path))
        }
        XCTAssertTrue(manager.fileExists(atPath: extra.path))
    }

    func testActiveRideCannotBeEditedOrDeletedEvenWithFinishedManifest() throws {
        let active = try fixture(ended: false), completed = try fixture()
        let store = try RideArchiveFiles(directory: directory)
        XCTAssertThrowsError(try store.deleteCompletedRide(active))
        XCTAssertThrowsError(try store.updateMetadata(active, title: "no", note: ""))
        XCTAssertThrowsError(try store.deleteCompletedRide(completed, activeID: completed))
        XCTAssertThrowsError(try store.updateMetadata(completed, title: "no", note: "", activeID: completed))
        XCTAssertTrue(manager.fileExists(atPath: path(active, "jsonl").path))
        XCTAssertTrue(manager.fileExists(atPath: path(completed, "jsonl").path))
    }

    func testMismatchedManifestCannotDeleteOrEditOtherRide() throws {
        let id = try fixture(), other = try fixture()
        try Data(contentsOf: path(other, "json")).write(to: path(id, "json"))
        let store = try RideArchiveFiles(directory: directory)
        XCTAssertThrowsError(try store.deleteCompletedRide(id))
        XCTAssertThrowsError(try store.updateMetadata(id, title: "wrong", note: ""))
        XCTAssertTrue(manager.fileExists(atPath: path(id, "jsonl").path))
        XCTAssertTrue(manager.fileExists(atPath: path(other, "jsonl").path))
    }

    func testEachSymlinkIsRejectedBeforeAnyRideFileIsRemoved() throws {
        let external = root.appendingPathComponent("outside.jsonl")
        let evidence = Data("outside stays".utf8)
        try evidence.write(to: external)
        for ext in ["json", "jsonl", "route-estimates"] {
            let id = try fixture()
            try manager.removeItem(at: path(id, ext))
            try manager.createSymbolicLink(at: path(id, ext), withDestinationURL: external)
            XCTAssertThrowsError(try RideArchiveFiles(directory: directory).deleteCompletedRide(id))
            for untouched in ["json", "jsonl", "route-estimates"] where untouched != ext {
                XCTAssertTrue(manager.fileExists(atPath: path(id, untouched).path))
            }
            XCTAssertEqual(try Data(contentsOf: external), evidence)
        }
    }

    func testDirectoryMasqueradingAsRawFileIsNotRecursivelyDeleted() throws {
        let id = try fixture(), raw = path(id, "jsonl")
        try manager.removeItem(at: raw)
        try manager.createDirectory(at: raw, withIntermediateDirectories: false)
        let child = raw.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: child)
        XCTAssertThrowsError(try RideArchiveFiles(directory: directory).deleteCompletedRide(id))
        XCTAssertTrue(manager.fileExists(atPath: child.path))
        XCTAssertTrue(manager.fileExists(atPath: path(id, "json").path))
    }

    func testMissingOptionalFilesCanBeRetriedButMissingManifestCannotDeleteRaw() throws {
        let first = try fixture(), second = try fixture()
        try manager.removeItem(at: path(first, "jsonl"))
        try manager.removeItem(at: path(first, "route-estimates"))
        try RideArchiveFiles(directory: directory).deleteCompletedRide(first)
        XCTAssertFalse(manager.fileExists(atPath: path(first, "json").path))
        try manager.removeItem(at: path(second, "json"))
        XCTAssertThrowsError(try RideArchiveFiles(directory: directory).deleteCompletedRide(second))
        XCTAssertTrue(manager.fileExists(atPath: path(second, "jsonl").path))
    }

    func testSymlinkRootAndReplacedRootAreRejected() throws {
        let id = try fixture(), store = try RideArchiveFiles(directory: directory)
        let moved = root.appendingPathComponent("moved")
        try manager.moveItem(at: directory, to: moved)
        try manager.createSymbolicLink(at: directory, withDestinationURL: moved)
        XCTAssertThrowsError(try RideArchiveFiles(directory: directory))
        XCTAssertThrowsError(try store.deleteCompletedRide(id))
        XCTAssertTrue(manager.fileExists(atPath: moved.appendingPathComponent(id.uuidString + ".jsonl").path))
    }
}
