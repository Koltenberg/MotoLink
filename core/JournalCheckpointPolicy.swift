import Foundation

/// A ride must be discoverable before its first raw line can reach disk. The
/// small initial manifest is committed first; later append/checkpoint calls do
/// not replace an existing manifest with an uncommitted in-memory summary.
enum JournalInitialManifest {
    static func prepare(at url: URL, contents: @autoclosure () throws -> Data) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try contents().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

/// New recordings retain milliseconds; whole-second ISO 8601 journals from
/// earlier releases remain readable. Never round high-rate charts to seconds.
enum RideJournalDates {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let legacy = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            guard let date = precise.date(from: text) ?? legacy.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ride timestamp")
            }
            return date
        }
        return decoder
    }

    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

protocol JournalRecoverableSummary {
    var id: UUID { get }
    var startedAt: Date { get }
    var endedAt: Date? { get set }
    var lastSavedAt: Date { get set }
    var distanceMeters: Double { get set }
    var maxSpeedMS: Double { get set }
    var pointCount: Int { get set }
    var telemetryCount: Int { get set }
    var rawEventCount: Int? { get set }
    var acceptedSpeedCount: Int? { get set }
}

/// Reconcile a small atomic manifest with complete records committed after it.
/// The caller streams one line at a time; a truncated tail is never replayed.
/// Explicit distance totals come from accepted GPS only, never gap endpoints.
struct JournalReplayRecovery<Summary: JournalRecoverableSummary> {
    private(set) var summary: Summary
    private var gpsCount = 0
    private var telemetryCount = 0
    private var rawCount = 0
    private var acceptedSpeedCount = 0
    private var distanceTotal = 0.0
    private var maximumSpeed = 0.0
    private var lastRecordAt: Date?
    private var finishedAt: Date?

    init(summary: Summary) { self.summary = summary }

    mutating func observe(kind: String, at date: Date, checkpoint: Summary? = nil,
                          distanceMeters: Double? = nil, gpsSpeed: Double? = nil) {
        guard date.timeIntervalSince1970.isFinite, date >= summary.startedAt else { return }
        // A restored process can have queued new packets before it discovers
        // the old finish boundary. Preserve those raw bytes, but don't count
        // them as observations made during the completed trip.
        if let finishedAt, date > finishedAt, kind != "summary_checkpoint" { return }
        if lastRecordAt == nil || date > lastRecordAt! { lastRecordAt = date }
        if let checkpoint, checkpoint.id == summary.id,
           checkpoint.startedAt == summary.startedAt,
           checkpoint.lastSavedAt.timeIntervalSince1970.isFinite,
           checkpoint.lastSavedAt >= summary.lastSavedAt,
           checkpoint.distanceMeters.isFinite, checkpoint.distanceMeters >= 0,
           checkpoint.maxSpeedMS.isFinite, checkpoint.maxSpeedMS >= 0,
           checkpoint.pointCount >= 0, checkpoint.telemetryCount >= 0,
           finishedAt == nil || checkpoint.endedAt != nil,
           checkpoint.endedAt.map({ $0 >= checkpoint.startedAt }) ?? true {
            summary = checkpoint
        }
        switch kind {
        case "gps":
            gpsCount += 1
            if let distanceMeters, distanceMeters.isFinite, distanceMeters >= 0 {
                distanceTotal = max(distanceTotal, distanceMeters)
            }
            if let gpsSpeed, gpsSpeed.isFinite, (0...100).contains(gpsSpeed) {
                acceptedSpeedCount += 1
                maximumSpeed = max(maximumSpeed, gpsSpeed)
            }
        case "motorcycle": telemetryCount += 1
        case "diagnostic": rawCount += 1
        case "finished": if finishedAt == nil { finishedAt = date }
        default: break
        }
    }

    var recovered: Summary {
        var result = summary
        result.pointCount = max(result.pointCount, gpsCount)
        result.telemetryCount = max(result.telemetryCount, telemetryCount)
        result.rawEventCount = max(result.rawEventCount ?? 0, rawCount)
        result.acceptedSpeedCount = max(result.acceptedSpeedCount ?? 0, acceptedSpeedCount)
        result.distanceMeters = max(result.distanceMeters, distanceTotal)
        result.maxSpeedMS = max(result.maxSpeedMS, maximumSpeed)
        if let lastRecordAt { result.lastSavedAt = max(result.lastSavedAt, lastRecordAt) }
        if result.endedAt == nil { result.endedAt = finishedAt }
        return result
    }
}

/// Sample the two fast instruments at up to 10 Hz without resampling slow
/// sensors or manufacturing intermediate values. Throttle is capped at 5 Hz;
/// other channels remain 1 Hz.
struct RideMeasurementSampling {
    private var lastTimes: [String: Date] = [:]

    mutating func accepts(id: String, at date: Date) -> Bool {
        guard date.timeIntervalSince1970.isFinite else { return false }
        let interval: TimeInterval
        if ["engine_speed", "wheel_speed"].contains(id) { interval = 0.1 }
        else if id == "throttle_position" { interval = 0.2 }
        else { interval = 1 }
        guard lastTimes[id].map({ date.timeIntervalSince($0) >= interval - 0.000_001 }) ?? true else { return false }
        lastTimes[id] = date
        return true
    }
}

/// Raw records are written on every append. Only fsync and the atomic summary
/// checkpoint are coalesced; explicit boundaries always force persistence.
struct JournalCheckpointPolicy {
    private(set) var lastCheckpointUptime: TimeInterval?
    let interval: TimeInterval = 1

    func shouldCheckpoint(at uptime: TimeInterval, forced: Bool = false) -> Bool {
        guard !forced, let previous = lastCheckpointUptime else { return true }
        return !uptime.isFinite || uptime < previous || uptime - previous >= interval
    }

    /// Call only after both synchronization and the manifest write succeed.
    mutating func checkpointSucceeded(at uptime: TimeInterval) {
        lastCheckpointUptime = uptime.isFinite ? uptime : nil
    }
}

/// A finishing batch may fail after its first complete line or during the
/// subsequent fsync/manifest checkpoint. Retry only the still-unwritten lines;
/// keep the progress until the caller confirms that checkpoint succeeded.
struct JournalFinishWriteProgress {
    private var writtenCounts: [UUID: Int] = [:]

    mutating func append(_ records: [Data], rideID: UUID,
                         write: (Data) throws -> Void) throws {
        let alreadyWritten = writtenCounts[rideID] ?? 0
        for (index, record) in records.enumerated() where index >= alreadyWritten {
            try write(record)
            writtenCounts[rideID] = index + 1
        }
    }

    mutating func checkpointSucceeded(rideID: UUID) {
        writtenCounts.removeValue(forKey: rideID)
    }
}
