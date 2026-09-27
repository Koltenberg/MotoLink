import Foundation

enum CompanionValidationError: Error, LocalizedError, Equatable {
    case missingName, invalidDate, invalidOdometer, invalidLiters, invalidCost
    case nonIncreasingOdometer, duplicateIdentifier, invalidInterval, invalidIntervalRange, missingServiceDate

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
        }
    }
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

    init(id: UUID = UUID(), date: Date = Date(), odometerKm: Double,
         liters: Double? = nil, cost: Double? = nil, fullTank: Bool = true) {
        self.id = id
        self.date = date
        self.odometerKm = odometerKm
        self.liters = liters
        self.cost = cost
        self.fullTank = fullTank
    }

    func validate() throws {
        guard date.timeIntervalSince1970.isFinite else { throw CompanionValidationError.invalidDate }
        guard odometerKm.isFinite, odometerKm >= 0 else { throw CompanionValidationError.invalidOdometer }
        if let liters {
            guard liters.isFinite, liters > 0 else { throw CompanionValidationError.invalidLiters }
        } else if !fullTank { throw CompanionValidationError.invalidLiters }
        if let cost, !cost.isFinite || cost < 0 { throw CompanionValidationError.invalidCost }
    }
}

struct FuelConsumption: Identifiable, Equatable {
    let fromEntryID: UUID
    let toEntryID: UUID
    let distanceKm: Double
    let liters: Double
    var id: UUID { toEntryID }
    var litersPer100Km: Double { liters / distanceKm * 100 }
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

/// Manual records stay separate from BLE telemetry and GPS distance estimates.
struct CompanionData: Codable, Identifiable, Equatable {
    var id: UUID
    var bikeName: String
    var odometerKm: Double?
    var fuelEntries: [FuelEntry]
    var serviceTasks: [ServiceTask]

    init(id: UUID = UUID(), bikeName: String = "Мой мотоцикл", odometerKm: Double? = nil,
         fuelEntries: [FuelEntry] = [], serviceTasks: [ServiceTask] = []) {
        self.id = id
        self.bikeName = bikeName
        self.odometerKm = odometerKm
        self.fuelEntries = fuelEntries
        self.serviceTasks = serviceTasks
    }

    /// Maximum explicitly entered reading; ride distance is never added to it.
    var currentOdometerKm: Double? {
        var readings: [Double] = []
        if let odometerKm, odometerKm.isFinite, odometerKm >= 0 { readings.append(odometerKm) }
        readings += fuelEntries.filter { (try? $0.validate()) != nil }.map(\.odometerKm)
        readings += serviceTasks.filter { (try? $0.validate()) != nil }.map(\.lastDoneOdometerKm)
        return readings.max()
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
                                              distanceKm: distance, liters: accumulatedLiters))
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
