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

        // Real first-write interruption: run the same production preparation
        // used by RideArchive before JSONL creation, then leave only the first
        // synchronized raw line as if the process died before its checkpoint.
        let rides = documents.appendingPathComponent("rides", isDirectory: true)
        try manager.createDirectory(at: rides, withIntermediateDirectories: true)
        let rideID = UUID()
        let manifest = rides.appendingPathComponent(rideID.uuidString + ".json")
        let journal = rides.appendingPathComponent(rideID.uuidString + ".jsonl")
        let initial = Data("{\"id\":\"\(rideID.uuidString)\",\"trigger\":\"capture\"}".utf8)
        try JournalInitialManifest.prepare(at: manifest, contents: initial)
        try require(exists(manifest) && !exists(journal), "First append was possible before its manifest existed")
        try Data("{\"kind\":\"started\"}\n".utf8).write(to: journal)
        let firstWrite = try FileHandle(forWritingTo: journal)
        try firstWrite.synchronize()
        try firstWrite.close()
        let discovered = try manager.contentsOfDirectory(at: rides, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        try require(discovered.map { $0.resolvingSymlinksInPath().path } == [manifest.resolvingSymlinksInPath().path],
                    "Crash after first raw fsync orphaned the ride")
        let manifestAfterInterruptedCheckpoint = try Data(contentsOf: manifest)
        try require(manifestAfterInterruptedCheckpoint == initial, "Initial manifest was lost before checkpoint")
        try JournalInitialManifest.prepare(at: manifest, contents: Data("must not replace saved manifest".utf8))
        let manifestAfterLaterAppend = try Data(contentsOf: manifest)
        try require(manifestAfterLaterAppend == initial, "Later append replaced the manifest before raw commit")

        let impossibleManifest = rides.appendingPathComponent("missing-parent/\(UUID().uuidString).json")
        let forbiddenJournal = rides.appendingPathComponent(UUID().uuidString + ".jsonl")
        var appendReached = false
        do {
            try JournalInitialManifest.prepare(at: impossibleManifest, contents: initial)
            appendReached = true
            try Data("must not write".utf8).write(to: forbiddenJournal)
        } catch { }
        try require(!appendReached && !exists(forbiddenJournal), "Failed first manifest allowed raw append")
        print("Initial ride manifest: interruption and failure cases passed")

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

        // Exercise the production logger with a real file handle and one
        // injected replacement-open failure. The old rotate() closed its handle
        // before this failure, making all later appends and exports fail too.
        let logs = sandbox.appendingPathComponent("logs", isDirectory: true)
        var openAttempts = 0
        let store = try SessionLogStore(directory: logs, limit: 700) { url in
            openAttempts += 1
            if openAttempts == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            return try SessionLogStore.openProtectedLog(url)
        }
        var storageErrors: [String] = []
        store.onError = { storageErrors.append($0) }
        let padding = String(repeating: "x", count: 400)
        store.append(DiagnosticEvent(kind: "rx", detail: "first " + padding))
        store.append(DiagnosticEvent(kind: "rx", detail: "injected-failure " + padding))
        store.append(DiagnosticEvent(kind: "rx", detail: "after-recovery " + padding))
        var exported: Result<[URL], Error>?
        store.export { exported = $0 }
        let deadline = Date().addingTimeInterval(10)
        while exported == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let exported else {
            throw NSError(domain: "SessionLogRotationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Logger export did not complete"])
        }
        let files = try exported.get()
        defer { MotoLinkExportCleanup.removeCompletedExports(files) }
        let events = try files.filter { $0.pathExtension == "jsonl" }.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
            }
        }
        try require(storageErrors.count == 1, "One transient rotation failure poisoned later logging")
        try require(events.contains { $0.detail.hasPrefix("first ") }, "Rotation lost the original file")
        try require(events.contains { $0.detail.hasPrefix("after-recovery ") }, "Logger did not recover after transient failure")
        try require(openAttempts == 3, "Expected the failed rotation to retry once")
        print("Session log rotation: transient replacement failure recovered; existing journal preserved")
    }
}
