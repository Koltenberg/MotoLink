import Foundation

/// Compiles against the production Foundation-only implementation. Each case
/// operates inside one newly created test directory, never the app's storage.
@main enum ExportCleanupRegressionTests {
    static func main() throws {
        let manager = FileManager.default
        let sandbox = manager.temporaryDirectory.appendingPathComponent("MotoLink-cleanup-test-\(UUID().uuidString)")
        let temporary = sandbox.appendingPathComponent("tmp", isDirectory: true)
        let documents = sandbox.appendingPathComponent("Documents", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        try manager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: sandbox) }

        func file(in directory: URL) throws -> URL {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("journal.jsonl")
            try Data("retained evidence\n".utf8).write(to: path)
            return path
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "ExportCleanupRegressionTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func exists(_ path: URL) -> Bool { manager.fileExists(atPath: path.path) }
        func owned(_ prefix: String = "MotoLink-capture-") -> URL {
            temporary.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        }

        for prefix in ["MotoLink-capture-", "MotoLink-ride-", "MotoLink-export-"] {
            let directory = owned(prefix), exported = try file(in: directory)
            MotoLinkExportCleanup.removeCompletedExports([exported, exported], temporaryDirectory: temporary)
            try require(!exists(directory), "Finished \(prefix) export was retained")
        }

        let original = try file(in: documents.appendingPathComponent("MotoLink-capture-\(UUID().uuidString)"))
        let invalid = try file(in: temporary.appendingPathComponent("MotoLink-capture-not-a-UUID"))
        let unrelated = try file(in: temporary.appendingPathComponent("OtherApp-\(UUID().uuidString)"))
        let nested = try file(in: temporary.appendingPathComponent("nested/MotoLink-capture-\(UUID().uuidString)"))
        MotoLinkExportCleanup.removeCompletedExports([original, invalid, unrelated, nested], temporaryDirectory: temporary)
        for preserved in [original, invalid, unrelated, nested] {
            try require(exists(preserved), "Cleanup crossed ownership boundary: \(preserved.lastPathComponent)")
        }

        let link = owned()
        try manager.createSymbolicLink(at: link, withDestinationURL: original.deletingLastPathComponent())
        MotoLinkExportCleanup.removeCompletedExports([link.appendingPathComponent(original.lastPathComponent)],
                                                     temporaryDirectory: temporary)
        try require(exists(original), "Cleanup followed a symlink into Documents")
        try require((try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil,
                    "Cleanup must leave an unowned symlink alone")

        let now = Date(), old = now.addingTimeInterval(-48 * 60 * 60)
        let stale = owned(), recent = owned(), touched = owned()
        _ = try file(in: stale); _ = try file(in: recent); _ = try file(in: touched)
        try manager.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: stale.path)
        try manager.setAttributes([.creationDate: old, .modificationDate: now], ofItemAtPath: touched.path)
        MotoLinkExportCleanup.removeStale(temporaryDirectory: temporary, now: now)
        try require(!exists(stale), "Stale owned copy was retained")
        try require(exists(recent), "New export inside the grace period was deleted")
        try require(exists(touched), "Recently modified export was deleted")
        try require(exists(original) && exists(invalid) && exists(unrelated) && exists(nested),
                    "Stale cleanup crossed an ownership boundary")
        print("Export cleanup: 11 safety cases passed")
    }
}
