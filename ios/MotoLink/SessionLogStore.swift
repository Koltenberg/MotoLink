import Foundation

struct DiagnosticEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: String
    let kind: String
    let detail: String
    let characteristic: String?
    let hex: String?

    init(kind: String, detail: String, characteristic: String? = nil, data: Data? = nil) {
        id = UUID()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp = formatter.string(from: Date())
        self.kind = kind
        self.detail = detail
        self.characteristic = characteristic
        hex = data.map { $0.map { String(format: "%02X", $0) }.joined() }
    }
}

private struct SetupSnapshot: Codable {
    var schema = "motolink.setup/1"
    var updatedAt: String?
    var latestIdentity: DiagnosticEvent?
    var latestCapabilities: DiagnosticEvent?
    var events: [DiagnosticEvent] = []
}

/// Owns file I/O on a serial queue. JSONL is saved locally, without an account.
/// At most 5 files of approximately 10 MiB are retained. Export snapshots every
/// retained file, including sessions before an iOS process restart.
final class SessionLogStore {
    private let queue = DispatchQueue(label: "app.motolink.diagnostic-log")
    private let directory: URL
    private let setupURL: URL
    private var setupSnapshot = SetupSnapshot()
    // Queue-confined. A retry/error burst must not rewrite the entire 400-event
    // setup snapshot for every event. Raw JSONL still receives every event.
    private var setupCheckpoint = JournalCheckpointPolicy()
    private var setupDirty = false
    private var fileURL: URL
    private var handle: FileHandle
    private var bytesWritten = 0
    private let limit = 10 * 1024 * 1024
    var onError: ((String) -> Void)?

    init() throws {
        directory = try FileManager.default.url(for: .documentDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
            .appendingPathComponent("MotoLinkLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setupURL = directory.appendingPathComponent("MotoLink-setup.json")
        fileURL = Self.nextURL(in: directory)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
        handle = try FileHandle(forWritingTo: fileURL)
        if let bytes = try? Data(contentsOf: setupURL), bytes.count <= 1024 * 1024,
           let saved = try? JSONDecoder().decode(SetupSnapshot.self, from: bytes) { setupSnapshot = saved }
        try Self.prune(directory: directory, preserving: fileURL)
        // A previous process may have exited while a share sheet was open.
        // Only old, strictly validated export copies in tmp are eligible.
        queue.async { MotoLinkExportCleanup.removeStale() }
    }

    deinit { try? handle.close() }

    func append(_ event: DiagnosticEvent) {
        queue.async { [self] in
            do {
                var bytes = try JSONEncoder().encode(event)
                bytes.append(0x0A)
                if bytesWritten + bytes.count > limit {
                    try rotate()
                }
                try handle.write(contentsOf: bytes)
                bytesWritten += bytes.count
                try pinSetup(event)
                // Writes go to the OS on every event; synchronize only at export.
            } catch {
                report(error)
            }
        }
    }

    func export(completion: @escaping (Result<[URL], Error>) -> Void) {
        queue.async { [self] in
            do {
                try handle.synchronize()
                try checkpointSetup(forced: true)
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MotoLink-export-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                var files = try Self.logFiles(in: directory)
                if FileManager.default.fileExists(atPath: setupURL.path) { files.append(setupURL) }
                var copies: [URL] = []
                for source in files {
                    let copy = destination.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.copyItem(at: source, to: copy)
                    copies.append(copy)
                }
                DispatchQueue.main.async { completion(.success(copies)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Keep last identity/capabilities independently from the raw ring so a long
    /// ride cannot evict the setup needed to interpret the remaining packets.
    private func pinSetup(_ event: DiagnosticEvent) throws {
        let opcode = event.hex.map { String($0.prefix(2)) }
        let isIdentity = event.kind == "rx" && opcode == "03"
        let isCapabilities = event.kind == "rx" && opcode == "40"
        guard event.kind != "rx" || isIdentity || isCapabilities else { return }
        if isIdentity { setupSnapshot.latestIdentity = event }
        if isCapabilities { setupSnapshot.latestCapabilities = event }
        setupSnapshot.updatedAt = event.timestamp
        setupSnapshot.events.append(event)
        if setupSnapshot.events.count > 400 {
            setupSnapshot.events.removeFirst(setupSnapshot.events.count - 400)
        }
        setupDirty = true
        // Identity and capabilities must survive a crash even if received just
        // after a periodic checkpoint. Other setup events are coalesced.
        try checkpointSetup(forced: isIdentity || isCapabilities)
    }

    private func checkpointSetup(forced: Bool = false) throws {
        guard setupDirty else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard setupCheckpoint.shouldCheckpoint(at: uptime, forced: forced) else { return }
        var bytes = try JSONEncoder().encode(setupSnapshot)
        while bytes.count > 1024 * 1024 && !setupSnapshot.events.isEmpty {
            setupSnapshot.events.removeFirst()
            bytes = try JSONEncoder().encode(setupSnapshot)
        }
        try bytes.write(to: setupURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // A failed atomic write leaves the snapshot dirty for the next append,
        // export or rotation. Never acknowledge persistence before it succeeds.
        setupCheckpoint.checkpointSucceeded(at: uptime)
        setupDirty = false
    }

    private func rotate() throws {
        try checkpointSetup(forced: true)
        try handle.synchronize()
        try handle.close()
        fileURL = Self.nextURL(in: directory)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
        handle = try FileHandle(forWritingTo: fileURL)
        bytesWritten = 0
        try Self.prune(directory: directory, preserving: fileURL)
    }

    private func report(_ error: Error) {
        let callback = onError
        DispatchQueue.main.async { callback?(error.localizedDescription) }
    }

    private static func nextURL(in directory: URL) -> URL {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        return directory.appendingPathComponent("MotoLink-\(timestamp)-\(UUID().uuidString.prefix(8)).jsonl")
    }

    private static func logFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func prune(directory: URL, preserving current: URL) throws {
        let files = try logFiles(in: directory)
        for file in files.prefix(max(0, files.count - 5)) where file != current {
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// Export copies are disposable only after their activity has finished. Never
/// accept a Documents path, a generic prefix match, a nested root or a symlink.
enum MotoLinkExportCleanup {
    private static let prefixes = ["MotoLink-capture-", "MotoLink-ride-", "MotoLink-export-"]
    private static let gracePeriod: TimeInterval = 24 * 60 * 60

    private static func ownedDirectory(_ directory: URL, temporaryDirectory: URL) -> URL? {
        guard directory.isFileURL, temporaryDirectory.isFileURL else { return nil }
        let candidate = directory.standardizedFileURL
        let root = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == root.path,
              let prefix = prefixes.first(where: { candidate.lastPathComponent.hasPrefix($0) }),
              UUID(uuidString: String(candidate.lastPathComponent.dropFirst(prefix.count))) != nil,
              let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              candidate.resolvingSymlinksInPath().path == root.appendingPathComponent(candidate.lastPathComponent).path
        else { return nil }
        return candidate
    }

    static func removeCompletedExports(_ files: [URL],
                                       temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        let directories = Set(files.filter(\.isFileURL).map { $0.deletingLastPathComponent() })
        for directory in directories {
            guard let owned = ownedDirectory(directory, temporaryDirectory: temporaryDirectory) else { continue }
            try? FileManager.default.removeItem(at: owned)
        }
    }

    static func removeStale(temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                            now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: temporaryDirectory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        for directory in contents {
            guard let owned = ownedDirectory(directory, temporaryDirectory: temporaryDirectory),
                  let values = try? owned.resourceValues(forKeys: keys),
                  let created = values.creationDate, let modified = values.contentModificationDate,
                  now.timeIntervalSince(max(created, modified)) > gracePeriod else { continue }
            try? FileManager.default.removeItem(at: owned)
        }
    }
}
