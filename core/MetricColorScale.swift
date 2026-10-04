import Foundation

enum MetricColorKind: String, CaseIterable, Codable, Identifiable {
    case speed, engineSpeed, coolantTemperature, inletTemperature, throttle, gear, voltage

    var id: String { rawValue }
    var title: String {
        switch self {
        case .speed: return "Скорость"
        case .engineSpeed: return "Обороты двигателя"
        case .coolantTemperature: return "Температура охлаждения"
        case .inletTemperature: return "Воздух на впуске"
        case .throttle: return "Дроссель"
        case .gear: return "Передача"
        case .voltage: return "Напряжение ЭБУ"
        }
    }
    var unit: String {
        switch self {
        case .speed: return "км/ч"
        case .engineSpeed: return "об/мин"
        case .coolantTemperature, .inletTemperature: return "°C"
        case .throttle: return "%"
        case .gear: return ""
        case .voltage: return "В"
        }
    }

    /// Integer settings cover the complete format currently decoded by
    /// MotoProtocol, including −40 °C. Voltage's fractional byte range reaches
    /// 19.84375 V, so its integer display ceiling is 20 V.
    var settingRange: ClosedRange<Int> {
        switch self {
        case .speed: return 0...511
        case .engineSpeed: return 0...32767
        case .coolantTemperature, .inletTemperature: return -40...214
        case .throttle: return 0...100
        case .gear: return 0...6
        case .voltage: return 0...20
        }
    }

    var defaultScale: MetricColorScale {
        switch self {
        case .speed: return MetricColorScale(orangeStart: 130, redStart: 190, maximum: 210)
        case .engineSpeed: return MetricColorScale(orangeStart: 8800, redStart: 11000, maximum: 11880)
        case .coolantTemperature: return MetricColorScale(orangeStart: 100, redStart: 110, maximum: 120)
        case .inletTemperature: return MetricColorScale(orangeStart: 30, redStart: 40, maximum: 60)
        case .throttle: return MetricColorScale(orangeStart: 70, redStart: 90, maximum: 100)
        case .gear: return MetricColorScale(orangeStart: 5, redStart: 6, maximum: 6)
        case .voltage: return MetricColorScale(orangeStart: 16, redStart: 18, maximum: 20)
        }
    }

    static func forMetric(_ id: String) -> Self? {
        switch id {
        case "wheel_speed", "gps_speed": return .speed
        case "engine_speed": return .engineSpeed
        case "engine_water_temperature": return .coolantTemperature
        case "inlet_air_temperature": return .inletTemperature
        case "throttle_position": return .throttle
        case "gear_position": return .gear
        case "ecu_battery12V": return .voltage
        default: return nil
        }
    }
}

enum MetricColorField: String, CaseIterable, Identifiable, Hashable {
    case orangeStart, redStart, maximum
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orangeStart: return "Оранжевый от"
        case .redStart: return "Красный от"
        case .maximum: return "Максимум шкалы"
        }
    }
}

enum MetricColorZone: Equatable { case green, orange, red }

struct MetricColorScale: Codable, Equatable {
    var orangeStart: Int
    var redStart: Int
    var maximum: Int

    /// Both boundaries are inclusive. Equal boundaries deliberately remove
    /// the orange interval; red wins starting at that exact value.
    func zone(at value: Double) -> MetricColorZone? {
        guard value.isFinite else { return nil }
        if value >= Double(redStart) { return .red }
        if value >= Double(orangeStart) { return .orange }
        return .green
    }

    func progress(at value: Double, for kind: MetricColorKind) -> Double? {
        guard value.isFinite, errors(for: kind).isEmpty else { return nil }
        let minimum = Double(kind.settingRange.lowerBound)
        return min(1, max(0, (value - minimum) / (Double(maximum) - minimum)))
    }

    func errors(for kind: MetricColorKind) -> [MetricColorField: String] {
        var result: [MetricColorField: String] = [:]
        let values: [(MetricColorField, Int)] = [(.orangeStart, orangeStart), (.redStart, redStart), (.maximum, maximum)]
        for (field, value) in values where !kind.settingRange.contains(value) {
            result[field] = "От \(kind.settingRange.lowerBound) до \(kind.settingRange.upperBound)\(kind.unit.isEmpty ? "" : " " + kind.unit)."
        }
        if result[.redStart] == nil, result[.orangeStart] == nil, redStart < orangeStart {
            result[.redStart] = "Не ниже оранжевого порога."
        }
        if result[.maximum] == nil {
            if maximum <= kind.settingRange.lowerBound {
                result[.maximum] = "Больше \(kind.settingRange.lowerBound)."
            } else if result[.redStart] == nil, maximum < redStart {
                result[.maximum] = "Не ниже красного порога."
            }
        }
        return result
    }
}

/// Editor text remains a draft until all three integer fields validate. A
/// partially typed minus sign or a decimal can never replace saved thresholds.
struct MetricColorDraft {
    var orangeStart: String
    var redStart: String
    var maximum: String

    init(_ scale: MetricColorScale) {
        orangeStart = String(scale.orangeStart)
        redStart = String(scale.redStart)
        maximum = String(scale.maximum)
    }

    subscript(_ field: MetricColorField) -> String {
        get {
            switch field {
            case .orangeStart: return orangeStart
            case .redStart: return redStart
            case .maximum: return maximum
            }
        }
        set {
            switch field {
            case .orangeStart: orangeStart = newValue
            case .redStart: redStart = newValue
            case .maximum: maximum = newValue
            }
        }
    }

    static func integer(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        guard !text.isEmpty else { return nil }
        return Int(text)
    }

    func validation(for kind: MetricColorKind) -> (scale: MetricColorScale?, errors: [MetricColorField: String]) {
        var errors: [MetricColorField: String] = [:]
        for field in MetricColorField.allCases where Self.integer(self[field]) == nil {
            errors[field] = "Введите целое число."
        }
        guard errors.isEmpty, let orange = Self.integer(orangeStart), let red = Self.integer(redStart),
              let limit = Self.integer(maximum) else { return (nil, errors) }
        let scale = MetricColorScale(orangeStart: orange, redStart: red, maximum: limit)
        errors = scale.errors(for: kind)
        return (errors.isEmpty ? scale : nil, errors)
    }
}

struct MetricColorPreferences: Codable, Equatable {
    static let storageKey = "MotoLink.visual.scales.v2"
    private var scales: [String: MetricColorScale] = [:]
    init() {}

    subscript(_ kind: MetricColorKind) -> MetricColorScale {
        get {
            if let scale = scales[kind.rawValue], scale.errors(for: kind).isEmpty { return scale }
            return kind.defaultScale
        }
        set { scales[kind.rawValue] = newValue }
    }

    static func decoded(_ data: Data) -> Self? {
        try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Migrates once from the three old values without their 10/500 steps or
    /// display clamps. Existing new preferences always win over legacy keys.
    static func load(from defaults: UserDefaults = .standard, persistMigration: Bool = true) -> Self {
        let savedData = defaults.data(forKey: storageKey)
        if let data = savedData, let existing = decoded(data) { return existing }
        var preferences = Self()
        func legacy(_ key: String, fallback: Int, range: ClosedRange<Int>) -> Int {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: key)))
        }
        let rpm = legacy("MotoLink.visual.rpmRedline", fallback: 11000, range: MetricColorKind.engineSpeed.settingRange)
        preferences[.engineSpeed] = MetricColorScale(orangeStart: Int(Double(rpm) * 0.8), redStart: rpm,
            maximum: min(32767, max(1, Int(ceil(Double(rpm) * 1.08)))))
        let orange = legacy("MotoLink.visual.speedWarm", fallback: 130, range: MetricColorKind.speed.settingRange)
        let red = max(orange, legacy("MotoLink.visual.speedHot", fallback: 190, range: MetricColorKind.speed.settingRange))
        preferences[.speed] = MetricColorScale(orangeStart: orange, redStart: red, maximum: min(511, max(1, red + 20)))
        // AppStorage can register an empty Data default before this migration.
        // Preserve a nonempty corrupt/unknown payload until an explicit Save.
        if persistMigration, savedData == nil || savedData?.isEmpty == true { try? preferences.save(to: defaults) }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) throws {
        for kind in MetricColorKind.allCases {
            if let scale = scales[kind.rawValue], !scale.errors(for: kind).isEmpty {
                throw NSError(domain: "MotoLink.MetricColorScale", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Проверьте границы цветовой шкалы."])
            }
        }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }
}
