import Foundation

/// The motorcycle's 0x4A notifications arrive about every 0.2 seconds in
/// recorded rides. Keep the live dashboard close to that rate while avoiding
/// an unlimited stream of SwiftUI publications, especially in the background.
enum TelemetryDisplayCadence {
    // 150 ms follows roughly 90–95% of the recorded 4A frames while capping
    // rapid bursts at 6.7 display publications/s. The stream itself is untouched.
    static let foregroundInterval: TimeInterval = 0.15
    static let backgroundInterval: TimeInterval = 0.5

    static func shouldPublish(at now: TimeInterval, after last: TimeInterval?,
                              force: Bool, foreground: Bool) -> Bool {
        if force || last == nil { return true }
        guard now.isFinite, let last, last.isFinite else { return true }
        let elapsed = now - last
        return elapsed < 0 || elapsed >= (foreground ? foregroundInterval : backgroundInterval)
    }
}

/// A stable catalogue is separate from transient packet values. Missing values
/// invalidate the reading, never the identity or position of its dashboard row.
struct TelemetryPresentation {
    struct Field: Identifiable {
        let id: String
        let label: String
        let unit: String
        let maximumAge: TimeInterval
        let decoded: Bool
    }

    enum State: Equatable { case receiving, waiting, stale, disconnected, notDecoded, unavailable }

    struct Row: Identifiable {
        let field: Field
        let measurement: MotoProtocol.Measurement?
        let state: State
        var id: String { field.id }
        var value: Double? { state == .receiving ? measurement?.value : nil }
    }

    private(set) var fields: [Field] = []
    private var readings: [String: MotoProtocol.Measurement] = [:]
    private var supportedIDs: Set<String> = []
    private var supportedModes: [String: UInt8] = [:]
    private var hasCapabilities = false

    static let primaryIDs = ["wheel_speed", "gear_position", "engine_speed", "engine_water_temperature"]
    private static let order = primaryIDs + ["throttle_position", "ecu_battery12V", "inlet_air_temperature", "fuel_injection_raw"]
    private static let known: [String: (String, String, TimeInterval)] = [
        "wheel_speed": ("Скорость колеса", "км/ч", 3),
        "gear_position": ("Передача", "", 3),
        "engine_speed": ("Обороты двигателя", "об/мин", 3),
        "engine_water_temperature": ("Охлаждение", "°C", 30),
        "throttle_position": ("Дроссель", "%", 3),
        "ecu_battery12V": ("Напряжение ЭБУ", "В", 90),
        "inlet_air_temperature": ("Воздух на впуске", "°C", 30),
        "fuel_injection_raw": ("Впрыск: исходное значение", "без единиц", 3)
    ]

    static func placeholder(_ id: String) -> Field {
        let metadata = known[id] ?? (id, "", 3)
        return Field(id: id, label: metadata.0, unit: metadata.1, maximumAge: metadata.2, decoded: known[id] != nil)
    }

    private static func canDecode(_ capability: MotoProtocol.Capability) -> Bool {
        switch capability.id {
        case "fuel_injection": return capability.supported
        case "engine_speed", "ecu_battery12V": return capability.mode == 0
        case "wheel_speed", "gear_position", "throttle_position", "engine_water_temperature", "inlet_air_temperature": return capability.mode == 1
        default: return false
        }
    }

    var measurements: [MotoProtocol.Measurement] { fields.compactMap { readings[$0.id] } }

    /// Called only for a successfully parsed capability response. Malformed
    /// responses must not reset a catalogue that the bike already confirmed.
    mutating func configure(_ capabilities: [MotoProtocol.Capability]) {
        hasCapabilities = true
        let supported = capabilities.filter(\.supported)
        let newModes = Dictionary(supported.map { capability in
            (capability.id == "fuel_injection" ? "fuel_injection_raw" : capability.id, capability.mode)
        }, uniquingKeysWith: { _, latest in latest })
        // A routine capability requery must not blank fresh readings. If a
        // field disappears or its wire format changes, its old value is no
        // longer safe to display. Disconnects invalidate readings separately.
        readings = readings.filter { supportedModes[$0.key] == newModes[$0.key] }
        supportedModes = newModes
        supportedIDs = Set(newModes.keys)
        var additions: [Field] = supported.map { capability in
            let id = capability.id == "fuel_injection" ? "fuel_injection_raw" : capability.id
            if let metadata = Self.known[id] {
                return Field(id: id, label: metadata.0, unit: metadata.1, maximumAge: metadata.2, decoded: Self.canDecode(capability))
            }
            return Field(id: id, label: capability.label, unit: "", maximumAge: 3, decoded: false)
        }
        additions.sort {
            let left = Self.order.firstIndex(of: $0.id) ?? Int.max
            let right = Self.order.firstIndex(of: $1.id) ?? Int.max
            return left == right ? $0.id < $1.id : left < right
        }
        // Existing rows retain their positions even if a later response changes
        // capabilities. An unavailable row stays visible with no numeric value.
        for field in additions {
            if let index = fields.firstIndex(where: { $0.id == field.id }) { fields[index] = field }
            else { fields.append(field) }
        }
    }

    mutating func invalidateReadings() { readings.removeAll() }

    mutating func receive(_ data: Data, decoded: [MotoProtocol.Measurement]) {
        let bytes = Array(data)
        if bytes.count >= 3, bytes.count == Int(bytes[1]) + 3 {
            let invalidated: [String]
            switch bytes[0] {
            case 0x41: invalidated = ["ecu_battery12V"]
            case 0x45: invalidated = ["engine_water_temperature", "inlet_air_temperature"]
            case 0x4A: invalidated = ["engine_speed", "wheel_speed", "gear_position", "throttle_position", "fuel_injection_raw"]
            default: invalidated = []
            }
            for id in invalidated { readings.removeValue(forKey: id) }
        }
        // Apply invalidation and replacement to a private value before publishing
        // once. Never emit remove/append mutations of @Published arrays per field.
        for sample in decoded where supportedIDs.contains(sample.id) && sample.value.isFinite {
            readings[sample.id] = sample
        }
    }

    func row(_ field: Field, connected: Bool, ready: Bool, now: Date) -> Row {
        let sample = readings[field.id]
        let state: State
        if !connected { state = .disconnected }
        else if !ready {
            // A failed subscription on one channel must not hide fresh,
            // decoded packets still arriving on another channel of the same
            // connected bike. `ready` continues to gate vendor writes, not
            // the validity of a value already received from the bike.
            if supportedIDs.contains(field.id), field.decoded, let sample {
                let age = now.timeIntervalSince(sample.timestamp)
                state = sample.value.isFinite && age >= 0 && age <= field.maximumAge ? .receiving : .stale
            } else { state = .waiting }
        }
        else if !supportedIDs.contains(field.id) { state = hasCapabilities ? .unavailable : .waiting }
        else if !field.decoded { state = .notDecoded }
        else if let sample {
            let age = now.timeIntervalSince(sample.timestamp)
            state = sample.value.isFinite && age >= 0 && age <= field.maximumAge ? .receiving : .stale
        } else { state = .waiting }
        return Row(field: field, measurement: sample, state: state)
    }

    func rows(connected: Bool, ready: Bool, now: Date) -> [Row] {
        fields.map { row($0, connected: connected, ready: ready, now: now) }
    }
}
