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
        var bytes = try JSONEncoder().encode(setupSnapshot)
        while bytes.count > 1024 * 1024 && !setupSnapshot.events.isEmpty {
            setupSnapshot.events.removeFirst()
            bytes = try JSONEncoder().encode(setupSnapshot)
        }
        try bytes.write(to: setupURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func rotate() throws {
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
