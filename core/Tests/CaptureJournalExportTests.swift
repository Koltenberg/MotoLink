import Foundation
import XCTest
@testable import MotoLinkCore

final class CaptureJournalExportTests: XCTestCase {
    func testLargeCapturePreservesEveryRawByteIncludingUnknownPackets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jsonl")
        let output = root.appendingPathComponent("output.jsonl")
        let raw = Data(String(repeating: "{\"kind\":\"diagnostic\",\"hex\":\"FF00FF\"}\n", count: 10000).utf8)
        try raw.write(to: source)
        let header = Data("{\"kind\":\"capture_manifest\"}".utf8)
        let footer = Data("{\"kind\":\"capture_end\"}".utf8)
        try CaptureJournalExport.write(to: output, header: header, source: source, footer: footer)
        XCTAssertEqual(try Data(contentsOf: output), header + Data([10]) + raw + Data([10]) + footer + Data([10]))
    }

    func testMissingSourceCannotProduceApparentlySuccessfulExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output.jsonl")
        XCTAssertThrowsError(try CaptureJournalExport.write(to: output, header: Data(),
            source: root.appendingPathComponent("missing"), footer: Data()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testStreamingReaderKeepsRecordsAcrossChunkBoundaryAndTruncatedTail() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let long = String(repeating: "a", count: 70000)
        try Data((long + "\n\n{\"kind\":\"gps\"}\n{\"kind\":").utf8).write(to: file)
        var lines: [String] = []
        try CaptureJournalExport.forEachLine(in: file) { lines.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(lines, [long, "{\"kind\":\"gps\"}", "{\"kind\":"])
    }
}
