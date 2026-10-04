import Foundation

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
