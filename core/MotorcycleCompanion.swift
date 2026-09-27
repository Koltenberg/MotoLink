import Foundation

enum CompanionValidationError: Error, LocalizedError, Equatable {
    case missingName, invalidDate, invalidOdometer, invalidLiters, invalidCost
    case nonIncreasingOdometer, duplicateIdentifier, invalidInterval

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
        }
    }
}

struct FuelEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var odometerKm: Double
    var liters: Double
    var cost: Double?
    var fullTank: Bool

    init(id: UUID = UUID(), date: Date = Date(), odometerKm: Double,
         liters: Double, cost: Double? = nil, fullTank: Bool = true) {
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
        guard liters.isFinite, liters > 0 else { throw CompanionValidationError.invalidLiters }
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
    var lastDoneAt: Date
    var lastDoneOdometerKm: Double
    var intervalKm: Double?
    var intervalMonths: Int?

    init(id: UUID = UUID(), title: String, lastDoneAt: Date = Date(),
         lastDoneOdometerKm: Double, intervalKm: Double? = nil, intervalMonths: Int? = nil) {
        self.id = id
        self.title = title
        self.lastDoneAt = lastDoneAt
        self.lastDoneOdometerKm = lastDoneOdometerKm
        self.intervalKm = intervalKm
        self.intervalMonths = intervalMonths
    }

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompanionValidationError.missingName
        }
        guard lastDoneAt.timeIntervalSince1970.isFinite else { throw CompanionValidationError.invalidDate }
        guard lastDoneOdometerKm.isFinite, lastDoneOdometerKm >= 0 else {
            throw CompanionValidationError.invalidOdometer
        }
        guard intervalKm != nil || intervalMonths != nil else {
            throw CompanionValidationError.invalidInterval
        }
        if let intervalKm, !intervalKm.isFinite || intervalKm <= 0 || !(lastDoneOdometerKm + intervalKm).isFinite {
            throw CompanionValidationError.invalidInterval
        }
        if let intervalMonths, intervalMonths <= 0 || dueDate() == nil {
            throw CompanionValidationError.invalidInterval
        }
    }

    var dueOdometerKm: Double? {
        guard lastDoneOdometerKm.isFinite, lastDoneOdometerKm >= 0,
              let intervalKm, intervalKm.isFinite, intervalKm > 0 else { return nil }
        let result = lastDoneOdometerKm + intervalKm
        return result.isFinite ? result : nil
    }

    func dueDate(calendar: Calendar = .current) -> Date? {
        guard lastDoneAt.timeIntervalSince1970.isFinite,
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
            accumulatedLiters += entry.liters
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
}
