import Foundation

/// Compact estimated mileage, independent of optional detailed ride journals.
/// Feed validated wheel speed or accepted GPS speed in metres/second. No throttle,
/// engine RPM, guessed route, or old trip distance is converted into mileage.
/// The runtime owns persistence and decides when a selected bike is being tracked.
struct MileageLedger: Codable {
    enum SpeedSource: String, Codable { case motorcycle, gps }

    struct Day: Codable, Equatable {
        let day: String
        fileprivate(set) var totalMeters: Double = 0
        fileprivate(set) var bikeSourceMeters: Double = 0
        fileprivate(set) var gpsSourceMeters: Double = 0
    }

    struct OdometerAnchor: Codable, Equatable {
        let kilometers: Double
        let lifetimeMeters: Double
        let recordedAt: Date
    }

    struct Account: Codable, Equatable {
        fileprivate(set) var totalMeters: Double = 0
        fileprivate(set) var bikeSourceMeters: Double = 0
        fileprivate(set) var gpsSourceMeters: Double = 0
        fileprivate(set) var foldedTotalMeters: Double = 0
        fileprivate(set) var foldedBikeSourceMeters: Double = 0
        fileprivate(set) var foldedGPSSourceMeters: Double = 0
        fileprivate(set) var foldedThroughDay: String?
        fileprivate(set) var days: [Day] = []
        fileprivate(set) var odometerAnchor: OdometerAnchor?
        fileprivate(set) var updatedAt: Date?
    }

    enum ValidationError: Error, Equatable {
        case invalidConfiguration, invalidIdentifier, invalidTotals, invalidDay, invalidAnchor
    }

    static let maximumSpeedMetersPerSecond = 100.0
    static let sampleFreshnessSeconds = 2.0
    static let maximumIntegrationGapSeconds = 3.0
    static let maximumSampleAgeSeconds = 3.0
    private static let maximumTotalMeters = 1_000_000_000_000.0

    private(set) var accounts: [UUID: Account] = [:]
    let maximumDailyBuckets: Int
    let timeZoneIdentifier: String

    private struct Sample {
        let time: Date
        let speed: Double
    }
    private struct Tracking {
        var cursor: Date?
        var bike: Sample?
        var gps: Sample?
    }
    // Deliberately not Codable: a restart never integrates across downtime.
    private var tracking: [UUID: Tracking] = [:]

    init(timeZone: TimeZone = .current, maximumDailyBuckets: Int = 400) {
        self.timeZoneIdentifier = timeZone.identifier
        self.maximumDailyBuckets = min(400, max(1, maximumDailyBuckets))
    }

    /// Call at a new physical tracking boundary, not at every speed callback.
    /// A repeated begin intentionally discards the old integration baseline.
    mutating func beginTracking(bikeID: UUID) { tracking[bikeID] = Tracking() }
    mutating func endTracking(bikeID: UUID) { tracking.removeValue(forKey: bikeID) }
    func isTracking(bikeID: UUID) -> Bool { tracking[bikeID] != nil }
    func totalMeters(bikeID: UUID) -> Double { accounts[bikeID]?.totalMeters ?? 0 }

    /// Credits only time supported by a previously received, still-fresh speed.
    /// A new value is never applied backwards. Equal-time source ordering cannot
    /// double-count an interval. Fresh motorcycle speed wins; GPS fills only the
    /// remaining intervals. Long gaps are not bridged, even at equal endpoint speeds.
    @discardableResult
    mutating func recordSpeed(bikeID: UUID, source: SpeedSource, metersPerSecond: Double,
                              timestamp: Date, receivedAt: Date) -> Double {
        guard var state = tracking[bikeID], Self.validDate(timestamp), Self.validDate(receivedAt),
              Self.validDay(dayKey(timestamp)),
              metersPerSecond.isFinite, (0...Self.maximumSpeedMetersPerSecond).contains(metersPerSecond),
              (0...Self.maximumSampleAgeSeconds).contains(receivedAt.timeIntervalSince(timestamp)),
              state.cursor == nil || timestamp >= state.cursor! else { return 0 }
        let previousSource = source == .motorcycle ? state.bike : state.gps
        guard previousSource == nil || timestamp > previousSource!.time else { return 0 }

        var additions: [(Date, Date, Double, SpeedSource)] = []
        if let cursor = state.cursor {
            let elapsed = timestamp.timeIntervalSince(cursor)
            if elapsed > Self.maximumIntegrationGapSeconds {
                // Do not let a second cached source bridge a recording blackout.
                state.bike = nil; state.gps = nil
            } else if elapsed > 0 {
                var position = cursor
                while position < timestamp {
                    let selected: (Sample, SpeedSource)?
                    if let bike = state.bike, position < bike.time.addingTimeInterval(Self.sampleFreshnessSeconds) {
                        selected = (bike, .motorcycle)
                    } else if let gps = state.gps, position < gps.time.addingTimeInterval(Self.sampleFreshnessSeconds) {
                        selected = (gps, .gps)
                    } else { selected = nil }
                    guard let (sample, selectedSource) = selected else { break }
                    let end = min(timestamp, sample.time.addingTimeInterval(Self.sampleFreshnessSeconds))
                    guard end > position else { break }
                    if sample.speed > 0 { additions.append((position, end, sample.speed, selectedSource)) }
                    position = end
                }
            }
        }
        state.cursor = timestamp
        let sample = Sample(time: timestamp, speed: metersPerSecond)
        if source == .motorcycle { state.bike = sample } else { state.gps = sample }
        tracking[bikeID] = state

        let added = additions.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) * $1.2 }
        guard added > 0, added.isFinite, totalMeters(bikeID: bikeID) + added <= Self.maximumTotalMeters else { return 0 }
        var account = accounts[bikeID] ?? Account()
        for (start, end, speed, usedSource) in additions {
            add(start: start, end: end, speed: speed, source: usedSource, to: &account)
        }
        account.updatedAt = max(account.updatedAt ?? timestamp, timestamp)
        accounts[bikeID] = account
        return added
    }

    /// The reading becomes a current anchor at the lifetime estimate at this call.
    /// Historical service/fuel readings must not be fed as current corrections.
    /// An older correction cannot overwrite a newer anchor. Resetting the live
    /// baseline avoids adding a pre-correction partial interval after the anchor.
    @discardableResult
    mutating func setOdometer(kilometers: Double, bikeID: UUID, at date: Date) throws -> Bool {
        guard kilometers.isFinite, (0...1_000_000_000.0).contains(kilometers), Self.validDate(date) else {
            throw ValidationError.invalidAnchor
        }
        var account = accounts[bikeID] ?? Account()
        if let existing = account.odometerAnchor, date < existing.recordedAt { return false }
        account.odometerAnchor = OdometerAnchor(kilometers: kilometers, lifetimeMeters: account.totalMeters, recordedAt: date)
        account.updatedAt = max(account.updatedAt ?? date, date)
        accounts[bikeID] = account
        if tracking[bikeID] != nil { tracking[bikeID] = Tracking() }
        return true
    }

    mutating func clearOdometer(bikeID: UUID) {
        guard var account = accounts[bikeID] else { return }
        account.odometerAnchor = nil
        accounts[bikeID] = account
    }

    func estimatedOdometerKilometers(bikeID: UUID) -> Double? {
        guard let account = accounts[bikeID], let anchor = account.odometerAnchor else { return nil }
        return anchor.kilometers + max(0, account.totalMeters - anchor.lifetimeMeters) / 1_000
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        return result
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func add(start: Date, end: Date, speed: Double, source: SpeedSource, to account: inout Account) {
        var position = start
        while position < end {
            let dayStart = calendar.startOfDay(for: position)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let stop = min(end, nextDay)
            guard stop > position else { break }
            let meters = stop.timeIntervalSince(position) * speed
            let day = dayKey(position)
            account.totalMeters += meters
            if source == .motorcycle { account.bikeSourceMeters += meters }
            else { account.gpsSourceMeters += meters }
            if let folded = account.foldedThroughDay, day <= folded {
                account.foldedTotalMeters += meters
                if source == .motorcycle { account.foldedBikeSourceMeters += meters }
                else { account.foldedGPSSourceMeters += meters }
            } else {
                if let index = account.days.firstIndex(where: { $0.day == day }) {
                    account.days[index].totalMeters += meters
                    if source == .motorcycle { account.days[index].bikeSourceMeters += meters }
                    else { account.days[index].gpsSourceMeters += meters }
                } else {
                    account.days.append(Day(day: day, totalMeters: meters,
                        bikeSourceMeters: source == .motorcycle ? meters : 0,
                        gpsSourceMeters: source == .gps ? meters : 0))
                    account.days.sort { $0.day < $1.day }
                }
                while account.days.count > maximumDailyBuckets {
                    let old = account.days.removeFirst()
                    account.foldedTotalMeters += old.totalMeters
                    account.foldedBikeSourceMeters += old.bikeSourceMeters
                    account.foldedGPSSourceMeters += old.gpsSourceMeters
                    account.foldedThroughDay = old.day
                }
            }
            position = stop
        }
    }

    func validate() throws {
        guard (1...400).contains(maximumDailyBuckets), TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw ValidationError.invalidConfiguration
        }
        for account in accounts.values {
            guard Self.validTotals(account.totalMeters, account.bikeSourceMeters, account.gpsSourceMeters),
                  Self.validTotals(account.foldedTotalMeters, account.foldedBikeSourceMeters, account.foldedGPSSourceMeters),
                  account.updatedAt.map(Self.validDate) ?? true else { throw ValidationError.invalidTotals }
            guard account.days.count <= maximumDailyBuckets else { throw ValidationError.invalidDay }
            var previous = account.foldedThroughDay
            if let previous, !Self.validDay(previous) { throw ValidationError.invalidDay }
            for day in account.days {
                guard Self.validDay(day.day), previous == nil || day.day > previous!,
                      Self.validTotals(day.totalMeters, day.bikeSourceMeters, day.gpsSourceMeters) else {
                    throw ValidationError.invalidDay
                }
                previous = day.day
            }
            guard Self.close(account.totalMeters, account.foldedTotalMeters + account.days.reduce(0) { $0 + $1.totalMeters }),
                  Self.close(account.bikeSourceMeters, account.foldedBikeSourceMeters + account.days.reduce(0) { $0 + $1.bikeSourceMeters }),
                  Self.close(account.gpsSourceMeters, account.foldedGPSSourceMeters + account.days.reduce(0) { $0 + $1.gpsSourceMeters }),
                  account.foldedTotalMeters == 0 || account.foldedThroughDay != nil else {
                throw ValidationError.invalidTotals
            }
            if let anchor = account.odometerAnchor {
                guard anchor.kilometers.isFinite, (0...1_000_000_000.0).contains(anchor.kilometers),
                      anchor.lifetimeMeters.isFinite, (0...account.totalMeters).contains(anchor.lifetimeMeters),
                      Self.validDate(anchor.recordedAt) else { throw ValidationError.invalidAnchor }
            }
        }
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite && abs(lhs - rhs) <= max(0.000_01, max(abs(lhs), abs(rhs)) * 1e-9)
    }
    private static func validTotals(_ total: Double, _ bike: Double, _ gps: Double) -> Bool {
        [total, bike, gps].allSatisfy { $0.isFinite && (0...maximumTotalMeters).contains($0) } && close(total, bike + gps)
    }
    private static func validDate(_ date: Date) -> Bool {
        let time = date.timeIntervalSince1970
        return time.isFinite && (0..<253_402_300_800.0).contains(time)
    }
    private static func validDay(_ day: String) -> Bool {
        let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let number = Int(pieces[2]),
              (1970...9999).contains(year), (1...12).contains(month), (1...31).contains(number) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: number)) else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == number
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, maximumDailyBuckets, timeZoneIdentifier, accounts }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else { throw ValidationError.invalidConfiguration }
        maximumDailyBuckets = try values.decode(Int.self, forKey: .maximumDailyBuckets)
        timeZoneIdentifier = try values.decode(String.self, forKey: .timeZoneIdentifier)
        let saved = try values.decode([String: Account].self, forKey: .accounts)
        for (key, account) in saved {
            guard let identifier = UUID(uuidString: key), accounts[identifier] == nil else { throw ValidationError.invalidIdentifier }
            accounts[identifier] = account
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schemaVersion)
        try values.encode(maximumDailyBuckets, forKey: .maximumDailyBuckets)
        try values.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try values.encode(Dictionary(uniqueKeysWithValues: accounts.map { ($0.key.uuidString, $0.value) }), forKey: .accounts)
    }
}
