import Foundation

/// A parked-bike A/B/A signal check. Readings are transient and belong to one
/// observed connection session; old or cross-session samples cannot form a result.
struct SignalComparisonPolicy {
    static let maximumAge: TimeInterval = 120
    static let minimumSamplesPerPhase = 2

    struct Reading: Equatable {
        let dBm: Int
        let measuredAt: Date
        let sessionID: UUID
    }

    struct Summary: Equatable {
        let dashMedianDBm: Double
        let seatMedianDBm: Double
        /// Positive means the signal was stronger at the front of the seat.
        let seatImprovementDB: Double
    }

    /// CoreBluetooth can report 127 when RSSI is unavailable. Treat only
    /// plausible negative dBm values as measurements.
    static func isValidRSSI(_ dBm: Int) -> Bool { (-127 ... -1).contains(dBm) }

    static func isRecent(_ reading: Reading, at now: Date, sessionID: UUID) -> Bool {
        let age = now.timeIntervalSince(reading.measuredAt)
        return isValidRSSI(reading.dBm) && reading.sessionID == sessionID &&
            age.isFinite && age >= 0 && age <= maximumAge
    }

    static func hasEnoughRecentReadings(_ readings: [Reading], at now: Date, sessionID: UUID) -> Bool {
        readings.filter { isRecent($0, at: now, sessionID: sessionID) }.count >= minimumSamplesPerPhase
    }

    static func summary(firstDash: [Reading], seat: [Reading], returnDash: [Reading],
                        at now: Date, sessionID: UUID, connected: Bool) -> Summary? {
        guard connected else { return nil }
        let phases = [firstDash, seat, returnDash]
        guard phases.allSatisfy({ phase in phase.allSatisfy { $0.sessionID == sessionID } }) else { return nil }
        let recent = phases.map { phase in phase.filter { isRecent($0, at: now, sessionID: sessionID) } }
        guard recent.allSatisfy({ $0.count >= minimumSamplesPerPhase }) else { return nil }

        // The return to the dash must bracket the seat measurement. A repeated
        // screenshot or a sample taken out of order cannot complete A/B/A.
        guard let firstDashEnd = recent[0].map(\.measuredAt).max(),
              let seatStart = recent[1].map(\.measuredAt).min(),
              let seatEnd = recent[1].map(\.measuredAt).max(),
              let returnDashStart = recent[2].map(\.measuredAt).min(),
              firstDashEnd <= seatStart, seatEnd <= returnDashStart else { return nil }

        let dashMedian = median((recent[0] + recent[2]).map(\.dBm))
        let seatMedian = median(recent[1].map(\.dBm))
        return Summary(dashMedianDBm: dashMedian, seatMedianDBm: seatMedian,
                       seatImprovementDB: seatMedian - dashMedian)
    }

    private static func median(_ values: [Int]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2
        }
        return Double(sorted[middle])
    }
}
