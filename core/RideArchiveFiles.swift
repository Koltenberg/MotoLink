import Foundation

enum RideArchiveFileError: LocalizedError {
    case unsafePath, activeRide, invalidManifest, textTooLong
    var errorDescription: String? {
        switch self {
        case .unsafePath: return "Файлы поездки имеют неподдерживаемый путь или тип. Изменения отменены."
        case .activeRide: return "Сначала завершите запись этой поездки."
        case .invalidManifest: return "Описание поездки не удалось проверить. Исходные файлы сохранены."
        case .textTooLong: return "Название — до 80 символов, заметка — до 4000."
        }
    }
}

/// Foundation-only file boundary for explicit user edits/deletion. The caller
/// serializes access with ride recording/export. No recursive directory removal.
struct RideArchiveFiles {
    let directory: URL
    private let resolvedDirectory: URL
    private static let extensions = ["jsonl", "route-estimates", "json"]

    init(directory: URL) throws {
        guard directory.isFileURL else { throw RideArchiveFileError.unsafePath }
        self.directory = directory.standardizedFileURL
        resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try validateDirectory()
    }

    private func validateDirectory() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              directory.resolvingSymlinksInPath().path == resolvedDirectory.path else {
            throw RideArchiveFileError.unsafePath
        }
    }

    private func existingFile(_ id: UUID, extension ext: String, optional: Bool = false) throws -> URL? {
        try validateDirectory()
        guard Self.extensions.contains(ext) else { throw RideArchiveFileError.unsafePath }
        let path = directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: path.path) }
        catch {
            let failure = error as NSError
            if optional && failure.domain == NSCocoaErrorDomain && [4, 260].contains(failure.code) { return nil }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              path.deletingLastPathComponent().standardizedFileURL.path == directory.path,
              path.resolvingSymlinksInPath().path == resolvedDirectory.appendingPathComponent(path.lastPathComponent).path
        else { throw RideArchiveFileError.unsafePath }
        return path
    }

    func manifest(_ id: UUID) throws -> Data {
        guard let manifest = try existingFile(id, extension: "json") else { throw RideArchiveFileError.invalidManifest }
        let data = try Data(contentsOf: manifest)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedID = object["id"] as? String, UUID(uuidString: storedID) == id else {
            throw RideArchiveFileError.invalidManifest
        }
        return data
    }

    func completedManifest(_ id: UUID, activeID: UUID? = nil) throws -> Data {
        guard id != activeID else { throw RideArchiveFileError.activeRide }
        let data = try manifest(id)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endedAt = object["endedAt"] as? String,
              RideJournalDates.date(from: endedAt) != nil else { throw RideArchiveFileError.activeRide }
        return data
    }

    /// Validate every selection before starting the background copy. Completed
    /// journals are immutable; the caller prevents history edits until export ends.
    func exportSources(_ ids: [UUID], activeID: UUID? = nil) throws -> [RideExportSource] {
        guard !ids.isEmpty else { throw RideArchiveFileError.invalidManifest }
        var seen = Set<UUID>()
        return try ids.filter { seen.insert($0).inserted }.map { id in
            let manifest = try completedManifest(id, activeID: activeID)
            guard let journal = try existingFile(id, extension: "jsonl") else {
                throw RideArchiveFileError.invalidManifest
            }
            let estimates = try existingFile(id, extension: "route-estimates", optional: true)
            return RideExportSource(id: id, manifest: manifest, journal: journal,
                                    estimates: estimates)
        }
    }

    /// Only the small manifest changes; raw packets and GPS are byte-for-byte intact.
    @discardableResult
    func updateMetadata(_ id: UUID, title: String, note: String, activeID: UUID? = nil,
                        now: Date = Date()) throws -> Data {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count <= 80, note.count <= 4000 else { throw RideArchiveFileError.textTooLong }
        let current = try completedManifest(id, activeID: activeID)
        guard var object = try JSONSerialization.jsonObject(with: current) as? [String: Any],
              let manifest = try existingFile(id, extension: "json") else { throw RideArchiveFileError.invalidManifest }
        object["title"] = title.isEmpty ? nil : title
        object["note"] = note.isEmpty ? nil : note
        object["metadataUpdatedAt"] = ISO8601DateFormatter().string(from: now)
        let updated = try JSONSerialization.data(withJSONObject: object)
        try updated.write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return updated
    }

    /// Pinning updates only the atomic manifest. It preserves names, unknown
    /// future metadata, route estimates and every original journal byte.
    @discardableResult
    func setFavorite(_ favorite: Bool, for id: UUID, activeID: UUID? = nil,
                     now: Date = Date()) throws -> Data {
        let current = try completedManifest(id, activeID: activeID)
        guard var object = try JSONSerialization.jsonObject(with: current) as? [String: Any],
              let manifest = try existingFile(id, extension: "json") else { throw RideArchiveFileError.invalidManifest }
        object["favorite"] = favorite
        object["metadataUpdatedAt"] = ISO8601DateFormatter().string(from: now)
        let updated = try JSONSerialization.data(withJSONObject: object)
        try updated.write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return updated
    }

    /// Validate all three exact UUID paths before removing anything. The manifest
    /// is removed last: an I/O failure leaves a visible entry which can be retried.
    func deleteCompletedRide(_ id: UUID, activeID: UUID? = nil) throws {
        _ = try completedManifest(id, activeID: activeID)
        let paths = try Self.extensions.compactMap { try existingFile(id, extension: $0, optional: $0 != "json") }
        for path in paths {
            // Re-check immediately before removal, including after previous I/O.
            guard let checked = try existingFile(id, extension: path.pathExtension) else { continue }
            try FileManager.default.removeItem(at: checked)
        }
    }
}

struct RideExportSource {
    let id: UUID
    let manifest: Data
    let journal: URL
    let estimates: URL?
}

enum RideBatchExport {
    /// Stream each journal into a self-contained capture; Foundation creates the
    /// ZIP locally. Never run this on the BLE, recorder, or main queue.
    static func write(_ sources: [RideExportSource], version: String, build: String,
                      temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard !sources.isEmpty, Set(sources.map(\.id)).count == sources.count else {
            throw RideArchiveFileError.invalidManifest
        }
        let manager = FileManager.default
        let root = temporaryDirectory.appendingPathComponent("MotoLink-export-\(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("MotoLink-rides", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var succeeded = false
        defer {
            // Both paths are newly created private staging paths, never user input.
            try? manager.removeItem(at: succeeded ? staging : root)
        }
        let exportedAt = ISO8601DateFormatter().string(from: Date())
        for source in sources {
            let summary = try JSONSerialization.jsonObject(with: source.manifest)
            let header = try JSONSerialization.data(withJSONObject: [
                "kind": "capture_manifest", "schema": "motolink.capture/1",
                "appVersion": version, "appBuild": build, "exportedAt": exportedAt,
                "ride": summary,
                "rawEventsIncluded": (summary as? [String: Any])?["rawEventCount"] ?? 0
            ])
            let estimates = try source.estimates.map { try Data(contentsOf: $0) } ?? Data("[]".utf8)
            let footer = try JSONSerialization.data(withJSONObject: [
                "kind": "capture_end", "roadEstimatesNotGPS": try JSONSerialization.jsonObject(with: estimates)
            ])
            try CaptureJournalExport.write(to: staging.appendingPathComponent("MotoLink-\(source.id.uuidString).jsonl"),
                                           header: header, source: source.journal, footer: footer)
        }
        let output = root.appendingPathComponent("MotoLink-rides.zip")
        var coordinationError: NSError?
        var copyError: Error?
        // .forUploading provides a ZIP snapshot for a directory. It neither
        // contacts a server nor uploads data. Copy before the accessor returns.
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: staging, options: .forUploading,
                                       error: &coordinationError) { snapshot in
            do { try manager.copyItem(at: snapshot, to: output) }
            catch { copyError = error }
        }
        if let error = copyError ?? coordinationError { throw error }
        guard manager.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteUnknown) }
        succeeded = true
        return output
    }
}
