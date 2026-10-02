import Foundation

enum CompanionValidationError: Error, LocalizedError, Equatable {
    case missingName, invalidDate, invalidOdometer, invalidLiters, invalidCost
    case nonIncreasingOdometer, duplicateIdentifier, invalidInterval, invalidIntervalRange, missingServiceDate
    case invalidRideSnapshot

    var errorDescription: String? {
        switch self {
        case .missingName: return "Введите название."
        case .invalidDate: return "Проверьте дату записи."
        case .invalidOdometer: return "Пробег должен быть конечным числом не меньше нуля."
        case .invalidLiters: return "Объём заправки должен быть больше нуля."
        case .invalidCost: return "Стоимость должна быть числом не меньше нуля."
        case .nonIncreasingOdometer: return "Пробег заправок должен увеличиваться по датам. Проверьте одинаковые и меньшие значения."
        case .duplicateIdentifier: return "Такая запись уже существует."
        case .invalidInterval: return "Укажите хотя бы один интервал обслуживания больше нуля."
        case .invalidIntervalRange: return "Начало диапазона должно быть больше нуля и меньше его конца."
        case .missingServiceDate: return "Для интервала в месяцах нужна дата последнего обслуживания. Для пробега дата не обязательна."
        case .invalidRideSnapshot: return "Проверьте точку отсчёта поездки для пробега."
        }
    }
}

/// Distance already included in a physical odometer reading taken during a ride.
/// Only the later part of that same ride can be added to an estimate.
struct RideDistanceSnapshot: Codable, Equatable {
    var rideID: UUID
    var distanceMeters: Double

    func validate() throws {
        guard distanceMeters.isFinite, distanceMeters >= 0 else {
            throw CompanionValidationError.invalidRideSnapshot
        }
    }
}

/// A fuel entry can use a GPS-based odometer estimate when the instrument
/// reading was unavailable. A missing value means instrument for legacy data.
enum FuelOdometerSource: String, Codable {
    case instrument
    case gpsEstimate
}

struct FuelEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var odometerKm: Double
    /// Nil means the amount added is unknown, never zero or the tank capacity.
    /// Older numeric records decode unchanged with synthesized Codable.
    var liters: Double?
    var cost: Double?
    var fullTank: Bool
    var odometerSource: FuelOdometerSource?
    var rideSnapshot: RideDistanceSnapshot?

    var hasInstrumentOdometer: Bool { odometerSource != .gpsEstimate }

    init(id: UUID = UUID(), date: Date = Date(), odometerKm: Double,
         liters: Double? = nil, cost: Double? = nil, fullTank: Bool = true,
         odometerSource: FuelOdometerSource? = nil, rideSnapshot: RideDistanceSnapshot? = nil) {
        self.id = id
        self.date = date
        self.odometerKm = odometerKm
        self.liters = liters
        self.cost = cost
        self.fullTank = fullTank
        self.odometerSource = odometerSource
        self.rideSnapshot = rideSnapshot
    }

    func validate() throws {
        guard date.timeIntervalSince1970.isFinite else { throw CompanionValidationError.invalidDate }
        guard odometerKm.isFinite, odometerKm >= 0 else { throw CompanionValidationError.invalidOdometer }
        if let liters {
            guard liters.isFinite, liters > 0 else { throw CompanionValidationError.invalidLiters }
        } else if !fullTank { throw CompanionValidationError.invalidLiters }
        if let cost, !cost.isFinite || cost < 0 { throw CompanionValidationError.invalidCost }
        if let rideSnapshot { try rideSnapshot.validate() }
        if !hasInstrumentOdometer && rideSnapshot != nil { throw CompanionValidationError.invalidRideSnapshot }
    }
}

struct FuelConsumption: Identifiable, Equatable {
    let fromEntryID: UUID
    let toEntryID: UUID
    let distanceKm: Double
    let liters: Double
    let usesEstimatedOdometer: Bool
    var id: UUID { toEntryID }
    var litersPer100Km: Double { liters / distanceKm * 100 }
}

/// A completed or currently recording ride. Distance is accepted GPS distance;
/// missing GPS sections are unknown and must not be manufactured here.
struct RecordedTripDistance: Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var distanceMeters: Double
}

struct OdometerEstimate: Equatable {
    enum AnchorSource: Equatable { case profile, fuel(UUID), service(UUID) }

    let kilometers: Double
    let anchorKilometers: Double
    let anchorDate: Date
    let anchorSource: AnchorSource
    let addedGPSKilometers: Double
    let rideCount: Int
    let includesActiveRide: Bool
    let skippedOverlappingRide: Bool
}

struct ServiceTask: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    /// Unknown is preserved as nil; a mileage record must not acquire today's date.
    /// Synthesized Codable accepts the dates stored by 0.4.9 and missing/null dates.
    var lastDoneAt: Date?
    var lastDoneOdometerKm: Double
    var intervalKm: Double?
    /// Optional lower bound; intervalKm remains the upper bound and preserves
    /// the meaning of every fixed interval stored by earlier app versions.
    var intervalStartKm: Double?
    var intervalMonths: Int?

    init(id: UUID = UUID(), title: String, lastDoneAt: Date? = nil,
         lastDoneOdometerKm: Double, intervalKm: Double? = nil,
         intervalStartKm: Double? = nil, intervalMonths: Int? = nil) {
        self.id = id
        self.title = title
        self.lastDoneAt = lastDoneAt
        self.lastDoneOdometerKm = lastDoneOdometerKm
        self.intervalKm = intervalKm
        self.intervalStartKm = intervalStartKm
        self.intervalMonths = intervalMonths
    }

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanionValidationError.missingName
        }
        if let lastDoneAt, !lastDoneAt.timeIntervalSince1970.isFinite {
            throw CompanionValidationError.invalidDate
        }
        guard lastDoneOdometerKm.isFinite, lastDoneOdometerKm >= 0 else {
            throw CompanionValidationError.invalidOdometer
        }
        guard intervalKm != nil || intervalMonths != nil else {
            throw CompanionValidationError.invalidInterval
        }
        if let intervalKm, !intervalKm.isFinite || intervalKm <= 0 || !(lastDoneOdometerKm + intervalKm).isFinite {
            throw CompanionValidationError.invalidInterval
        }
        if let intervalStartKm {
            guard intervalStartKm.isFinite, intervalStartKm > 0,
                  let intervalKm, intervalStartKm < intervalKm,
                  (lastDoneOdometerKm + intervalStartKm).isFinite else {
                throw CompanionValidationError.invalidIntervalRange
            }
        }
        if let intervalMonths {
            guard intervalMonths > 0 else { throw CompanionValidationError.invalidInterval }
            guard lastDoneAt != nil else { throw CompanionValidationError.missingServiceDate }
            guard dueDate() != nil else { throw CompanionValidationError.invalidInterval }
        }
    }

    var dueOdometerKm: Double? {
        guard lastDoneOdometerKm.isFinite, lastDoneOdometerKm >= 0,
              let intervalKm, intervalKm.isFinite, intervalKm > 0 else { return nil }
        let result = lastDoneOdometerKm + intervalKm
        return result.isFinite ? result : nil
    }

    var rangeStartOdometerKm: Double? {
        guard let intervalStartKm, (try? validate()) != nil else { return nil }
        return lastDoneOdometerKm + intervalStartKm
    }

    /// Fraction of the selected mileage interval, based on a manual reading.
    /// Unknown mileage has no progress; an overdue record never exceeds 100%.
    func mileageProgress(odometerKm: Double?) -> Double? {
        guard (try? validate()) != nil, let intervalKm,
              let odometerKm, odometerKm.isFinite, odometerKm >= 0 else { return nil }
        return min(1, max(0, (odometerKm - lastDoneOdometerKm) / intervalKm))
    }

    func dueDate(calendar: Calendar = .current) -> Date? {
        guard let lastDoneAt, lastDoneAt.timeIntervalSince1970.isFinite,
              let intervalMonths, intervalMonths > 0,
              let date = calendar.date(byAdding: .month, value: intervalMonths, to: lastDoneAt),
              date.timeIntervalSince1970.isFinite else { return nil }
        return date
    }

    /// Whichever user-defined limit comes first; dates are due for the whole local day.
    func isDue(odometerKm: Double?, on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard (try? validate()) != nil, date.timeIntervalSince1970.isFinite else { return false }
        if let odometerKm, odometerKm.isFinite, let dueOdometerKm, odometerKm >= dueOdometerKm { return true }
        if let due = dueDate(calendar: calendar) {
            return calendar.startOfDay(for: date) >= calendar.startOfDay(for: due)
        }
        return false
    }

    /// Difference from the last manually entered odometer, never GPS distance.
    func kilometersRemaining(odometerKm: Double?) -> Double? {
        guard let odometerKm, odometerKm.isFinite, odometerKm >= 0,
              let dueOdometerKm else { return nil }
        return dueOdometerKm - odometerKm
    }

    /// A range starts its reminder at the selected lower bound. A fixed interval
    /// retains the last-10% warning (at most 500 km); dates warn seven days ahead.
    func isDueSoon(odometerKm: Double?, on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard (try? validate()) != nil, date.timeIntervalSince1970.isFinite,
              !isDue(odometerKm: odometerKm, on: date, calendar: calendar) else { return false }
        if let intervalStartKm, let odometerKm, odometerKm.isFinite,
           odometerKm >= lastDoneOdometerKm + intervalStartKm { return true }
        if intervalStartKm == nil,
           let remaining = kilometersRemaining(odometerKm: odometerKm), let intervalKm,
           remaining > 0, remaining <= min(500, intervalKm * 0.1) { return true }
        if let due = dueDate(calendar: calendar),
           let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: due)).day {
            return (1...7).contains(days)
        }
        return false
    }
}

/// Instrument readings stay separate from BLE telemetry and GPS estimates.
struct CompanionData: Codable, Identifiable, Equatable {
    var id: UUID
    var bikeName: String
    var odometerKm: Double?
    /// Nil for legacy undated readings: their historical GPS distance cannot
    /// be added safely until the rider confirms a new instrument reading.
    var odometerRecordedAt: Date?
    var odometerRideSnapshot: RideDistanceSnapshot?
    var fuelEntries: [FuelEntry]
    var serviceTasks: [ServiceTask]

    init(id: UUID = UUID(), bikeName: String = "Мой мотоцикл", odometerKm: Double? = nil,
         odometerRecordedAt: Date? = nil, odometerRideSnapshot: RideDistanceSnapshot? = nil,
         fuelEntries: [FuelEntry] = [], serviceTasks: [ServiceTask] = []) {
        self.id = id
        self.bikeName = bikeName
        self.odometerKm = odometerKm
        self.odometerRecordedAt = odometerRecordedAt
        self.odometerRideSnapshot = odometerRideSnapshot
        self.fuelEntries = fuelEntries
        self.serviceTasks = serviceTasks
    }

    /// Maximum explicitly entered reading; ride distance is never added to it.
    var currentOdometerKm: Double? {
        var readings: [Double] = []
        if let odometerKm, odometerKm.isFinite, odometerKm >= 0 { readings.append(odometerKm) }
        readings += fuelEntries.filter { (try? $0.validate()) != nil && $0.hasInstrumentOdometer }.map(\.odometerKm)
        readings += serviceTasks.filter { (try? $0.validate()) != nil }.map(\.lastDoneOdometerKm)
        return readings.max()
    }

    /// Adds each saved ride at most once after the latest dated instrument
    /// reading. If the reading happened mid-ride, only GPS distance after the
    /// captured distance is counted. Undated legacy profile readings remain
    /// visible but cannot be used as a chronological anchor.
    func estimatedOdometer(from trips: [RecordedTripDistance], now: Date = Date()) -> OdometerEstimate? {
        struct Anchor {
            let kilometers: Double
            let date: Date
            let source: OdometerEstimate.AnchorSource
            let snapshot: RideDistanceSnapshot?
        }
        var anchors: [Anchor] = []
        if let odometerKm, odometerKm.isFinite, odometerKm >= 0,
           let odometerRecordedAt, odometerRecordedAt.timeIntervalSince1970.isFinite,
           odometerRecordedAt <= now {
            anchors.append(Anchor(kilometers: odometerKm, date: odometerRecordedAt,
                                  source: .profile, snapshot: odometerRideSnapshot))
        }
        anchors += fuelEntries.compactMap { entry in
            guard entry.hasInstrumentOdometer, (try? entry.validate()) != nil,
                  entry.date <= now else { return nil }
            return Anchor(kilometers: entry.odometerKm, date: entry.date,
                          source: .fuel(entry.id), snapshot: entry.rideSnapshot)
        }
        anchors += serviceTasks.compactMap { task in
            guard (try? task.validate()) != nil, let date = task.lastDoneAt,
                  date <= now else { return nil }
            return Anchor(kilometers: task.lastDoneOdometerKm, date: date,
                          source: .service(task.id), snapshot: nil)
        }
        guard let anchor = anchors.max(by: {
            $0.date == $1.date ? $0.kilometers < $1.kilometers : $0.date < $1.date
        }) else { return nil }
        // Higher undated physical readings cannot be placed before or after
        // the anchor. Suppress the estimate rather than show less than a
        // confirmed odometer value or count the same distance twice.
        if odometerRecordedAt == nil, let odometerKm, odometerKm.isFinite,
           odometerKm > anchor.kilometers { return nil }
        if serviceTasks.contains(where: { task in
            task.lastDoneAt == nil && (try? task.validate()) != nil
                && task.lastDoneOdometerKm > anchor.kilometers
        }) { return nil }

        var unique: [UUID: RecordedTripDistance] = [:]
        for trip in trips where trip.distanceMeters.isFinite && trip.distanceMeters >= 0
            && trip.startedAt.timeIntervalSince1970.isFinite && trip.startedAt <= now
            && (trip.endedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= trip.startedAt } ?? true) {
            if let previous = unique[trip.id], previous.distanceMeters >= trip.distanceMeters { continue }
            unique[trip.id] = trip
        }
        var distanceMeters = 0.0
        var rideCount = 0
        var includesActiveRide = false
        var skippedOverlappingRide = false
        for trip in unique.values {
            let additional: Double
            if trip.id == anchor.snapshot?.rideID, let snapshot = anchor.snapshot {
                additional = max(0, trip.distanceMeters - snapshot.distanceMeters)
            } else if trip.startedAt >= anchor.date {
                additional = trip.distanceMeters
            } else {
                if trip.endedAt.map({ $0 > anchor.date }) ?? true { skippedOverlappingRide = true }
                continue
            }
            if additional > 0 {
                distanceMeters += additional
                rideCount += 1
                includesActiveRide = includesActiveRide || trip.endedAt == nil
            }
        }
        let kilometers = anchor.kilometers + distanceMeters / 1000
        guard distanceMeters.isFinite, kilometers.isFinite else { return nil }
        return OdometerEstimate(kilometers: kilometers, anchorKilometers: anchor.kilometers,
                                anchorDate: anchor.date, anchorSource: anchor.source,
                                addedGPSKilometers: distanceMeters / 1000, rideCount: rideCount,
                                includesActiveRide: includesActiveRide,
                                skippedOverlappingRide: skippedOverlappingRide)
    }

    /// Input may be entered retrospectively. Equal timestamps are ordered by odometer.
    private var chronologicalFuelEntries: [FuelEntry] {
        fuelEntries.sorted {
            if $0.date == $1.date { return $0.odometerKm < $1.odometerKm }
            return $0.date < $1.date
        }
    }

    private func validateFuelEntries() throws {
        var ids = Set<UUID>()
        for entry in fuelEntries {
            try entry.validate()
            guard ids.insert(entry.id).inserted else { throw CompanionValidationError.duplicateIdentifier }
        }
        var previous: Double?
        for entry in chronologicalFuelEntries {
            if let previous, entry.odometerKm <= previous { throw CompanionValidationError.nonIncreasingOdometer }
            previous = entry.odometerKm
        }
    }

    func validate() throws {
        guard !bikeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanionValidationError.missingName
        }
        if let odometerKm, !odometerKm.isFinite || odometerKm < 0 { throw CompanionValidationError.invalidOdometer }
        if let odometerRecordedAt, !odometerRecordedAt.timeIntervalSince1970.isFinite {
            throw CompanionValidationError.invalidDate
        }
        if let odometerRideSnapshot { try odometerRideSnapshot.validate() }
        if odometerKm == nil && (odometerRecordedAt != nil || odometerRideSnapshot != nil) {
            throw CompanionValidationError.invalidRideSnapshot
        }
        if odometerRideSnapshot != nil && odometerRecordedAt == nil {
            throw CompanionValidationError.invalidRideSnapshot
        }
        try validateFuelEntries()
        var ids = Set<UUID>()
        for task in serviceTasks {
            try task.validate()
            guard ids.insert(task.id).inserted else { throw CompanionValidationError.duplicateIdentifier }
        }
    }

    mutating func addFuelEntry(_ entry: FuelEntry) throws {
        var candidate = self
        candidate.fuelEntries.append(entry)
        try candidate.validate()
        self = candidate
    }

    mutating func addServiceTask(_ task: ServiceTask) throws {
        var candidate = self
        candidate.serviceTasks.append(task)
        try candidate.validate()
        self = candidate
    }

    /// Full-to-full only. The starting fill establishes the baseline; every fill
    /// after it, including partial fills and the ending full fill, is counted.
    /// A malformed chronology invalidates the calculation instead of being skipped.
    /// Unknown added liters break that interval; an unknown full fill can still
    /// establish the baseline for a following interval with all amounts known.
    /// This estimates consumption from entered records only: an omitted/deleted
    /// real refill cannot be inferred, so a complete refill history is required.
    var fuelConsumptions: [FuelConsumption] {
        guard (try? validateFuelEntries()) != nil else { return [] }
        var result: [FuelConsumption] = []
        var baseline: FuelEntry?
        var accumulatedLiters = 0.0
        for entry in chronologicalFuelEntries {
            guard let start = baseline else {
                if entry.fullTank { baseline = entry }
                continue
            }
            guard let liters = entry.liters else {
                // This full tank has an unknown amount. Discard the incomplete
                // interval, but its full level is a valid new baseline.
                baseline = entry.fullTank ? entry : nil
                accumulatedLiters = 0
                continue
            }
            accumulatedLiters += liters
            guard accumulatedLiters.isFinite else { return [] }
            if entry.fullTank {
                let distance = entry.odometerKm - start.odometerKm
                let rate = accumulatedLiters / distance * 100
                guard distance > 0, distance.isFinite, rate.isFinite else { return [] }
                result.append(FuelConsumption(fromEntryID: start.id, toEntryID: entry.id,
                                              distanceKm: distance, liters: accumulatedLiters,
                                              usesEstimatedOdometer: !start.hasInstrumentOdometer || !entry.hasInstrumentOdometer))
                baseline = entry
                accumulatedLiters = 0
            }
        }
        return result
    }

    /// Do not present a historical estimate as the result of a newer unknown fill.
    var latestFullTankConsumption: FuelConsumption? {
        guard let latestFull = chronologicalFuelEntries.last(where: { $0.fullTank }),
              let consumption = fuelConsumptions.last,
              consumption.toEntryID == latestFull.id else { return nil }
        return consumption
    }
}
