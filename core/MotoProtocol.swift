import Foundation

/// Copies an arbitrarily long ride without loading its raw packets into memory.
/// A newline isolates a possibly truncated final record after process termination.
enum CaptureJournalExport {
    static func forEachLine(in source: URL, _ consume: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var pending = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if !line.isEmpty { try consume(line) }
            }
        }
        if !pending.isEmpty { try consume(pending) }
    }

    static func write(to destination: URL, header: Data, source: URL, footer: Data) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try output.write(contentsOf: header + Data([10]))
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data([10]) + footer + Data([10]))
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

// Protocol mappings adapted from Zen3515/homeassistant-kawasaki-rideology-ble.
// Apache-2.0. See THIRD_PARTY_NOTICES.md and LICENSES/Apache-2.0.txt.
// Diagnostics only. A valid GATT link is not proof of a valid telemetry stream.
enum MotoProtocol {
    static let advertisedService = "99EB13AC-42C9-4745-8B76-C30141401CE5"
    static let service = "92FAEC07-C075-4B7C-A6C2-BBD1D1A150F5"
    static let control = "ACF1B15C-10F9-4942-A32D-F9E019B95402"
    static let notify = [
        "3AABBB34-EAC0-40F5-9D50-3A1EE6787136",
        "02FAD1BD-358E-441C-B296-FE874AF38A7E",
        "5E119EBA-35A7-4463-A7AF-7FA40A302350"
    ]

    static func request(_ command: UInt8) -> Data? {
        if command == 0x08 {
            return Data([0x08, 0x0C, 0x00, 0xFF, 0xFF, 0x0A, 0x08, 0x01, 0x78, 0x03, 0xE8, 0x00, 0xC8, 0x00, 0x64])
        }
        // Exact upstream compatibility requests; no arbitrary byte entry point.
        let compatibility: [UInt8: [UInt8]] = [
            0x0B: [0x0B, 0x20, 0x00, 0xFF, 0xFF, 0x05, 0x01, 0x4D, 0x6F, 0x74, 0x6F, 0x4C, 0x69, 0x6E, 0x6B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            0x1B: [0x1B, 0x0C, 0x00, 0xFF, 0xFF, 0x05, 0x0A, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            0x48: [0x48, 0x2A, 0x00, 0xFF, 0xFF, 0x05, 0x09, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            0x1E: [0x1E, 0x2A, 0x01, 0xFF, 0xFF, 0x05, 0x0C, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x05, 0x0D, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x05, 0x0E, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        ]
        if let bytes = compatibility[command] { return Data(bytes) }
        guard Set<UInt8>([0x03, 0x40, 0x41, 0x45, 0x1A, 0x1D, 0x47]).contains(command) else { return nil }
        return Data([command, 0, 0])
    }

    struct Capability: Codable, Identifiable {
        let id: String
        let label: String
        let mode: UInt8
        var supported: Bool { mode == 0 || mode == 1 }
    }

    // Mode 0/1: supported. Other values stay unknown/unsupported; never guess a scale.
    static let layout: [(String, String, Int, UInt8, UInt8)] = [
        ("total_distance_traveled", "Пройденное расстояние", 7, 0xC0, 6),
        ("total_fuel_consumed", "Израсходованное топливо", 7, 0x30, 4),
        ("engine_fuel_rate", "Подача топлива", 7, 0x0C, 2),
        ("ecu_battery12V", "Напряжение ЭБУ", 7, 0x03, 0),
        ("engine_water_temperature", "Температура охлаждения", 8, 0xC0, 6),
        ("engine_oil_temperature", "Температура масла", 8, 0x30, 4),
        ("inlet_air_temperature", "Температура впуска", 8, 0x0C, 2),
        ("boost_temperature", "Температура наддува", 8, 0x03, 0),
        ("boost_pressure", "Давление наддува", 9, 0xC0, 6),
        ("fuel_injection", "Впрыск топлива", 9, 0x30, 4),
        ("wheel_speed", "Скорость колеса", 9, 0x0C, 2),
        ("engine_speed", "Обороты двигателя", 9, 0x03, 0),
        ("gear_position", "Передача", 10, 0xF0, 4),
        ("throttle_position", "Дроссель", 10, 0x0C, 2),
        ("acceleration", "Ускорение", 10, 0x03, 0),
        ("lean_angle", "Угол наклона", 11, 0xC0, 6),
        ("wheelie_flag", "Подъём колеса", 11, 0x30, 4),
        ("wheelie_angle", "Угол подъёма колеса", 11, 0x0C, 2),
        ("tcs_level_hb", "TCS HB", 11, 0x03, 0),
        ("tcs_level_lb", "TCS LB", 12, 0xC0, 6),
        ("rider_torque_request", "Запрос момента водителем", 12, 0x30, 4),
        ("engine_torque_request", "Запрошенный момент", 12, 0x0C, 2),
        ("engine_torque_actual", "Фактический момент", 12, 0x03, 0),
        ("odometer", "Одометр", 27, 0xC0, 6),
        ("fuel_gauge", "Уровень топлива", 27, 0x30, 4),
        ("average_fuel_mileage", "Средний расход", 27, 0x0C, 2),
        ("meter_battery12V", "Напряжение приборки", 27, 0x03, 0),
        ("tripA", "Пробег A", 28, 0xC0, 6),
        ("tripB", "Пробег B", 28, 0x30, 4),
        ("average_speed", "Средняя скорость", 28, 0x0C, 2),
        ("outer_air_temperature", "Наружная температура", 28, 0x03, 0),
        ("range_symbol", "Символ запаса хода", 29, 0xC0, 6),
        ("range", "Запас хода", 29, 0x30, 4),
        ("fuel_consumption", "Расход топлива", 29, 0x0C, 2),
        ("total_time", "Общее время", 29, 0x03, 0),
        ("instant_fuel_consumption", "Мгновенный расход", 31, 0x0C, 2)
    ]

    static func capabilities(_ data: Data) -> [Capability]? {
        let b = Array(data)
        guard b.count == 35, b[0] == 0x40, b[1] == 32, b[3] == 0x40 else { return nil }
        let groups = [(5, 6, 14), (15, 16, 24), (25, 26, 34)]
        let hasBlocks = groups.contains { b[$0.0] != 0xFF || b[$0.1] != 0xFF }
        let retry = groups.contains { (b[$0.0] != 0xFF || b[$0.1] != 0xFF) && (b[$0.2] & 1) == 0 }
        guard hasBlocks, !retry else { return nil }
        return layout.map { id, label, index, mask, shift in
            Capability(id: id, label: label, mode: (b[index] & mask) >> shift)
        }
    }


    struct Measurement: Codable, Identifiable {
        let id: String
        let label: String
        let value: Double
        let unit: String
        let timestamp: Date
        let source: String
    }

    /// Strictly scoped to known block signatures and this connection's capabilities.
    /// A supported field alone never produces a measurement. Sentinels are field-specific.
    static func measurements(_ data: Data, capabilities: [Capability], at time: Date = Date()) -> [Measurement] {
        let b = Array(data)
        guard b.count >= 5, b.count == Int(b[1]) + 3 else { return [] }
        func supports(_ id: String, mode: UInt8) -> Bool {
            capabilities.contains { $0.id == id && $0.mode == mode }
        }
        var result: [Measurement] = []
        if b[0] == 0x41, b[3] == 0x41, b.count == 85,
           b[5] == 0x05, b[6] == 0x14, b[14] != 0xFF,
           supports("ecu_battery12V", mode: 0) {
            result.append(Measurement(id: "ecu_battery12V", label: "Напряжение ЭБУ",
                                      value: Double(b[14]) * 20 / 256, unit: "В",
                                      timestamp: time, source: "Kawasaki BLE · 0x41 · EX500G"))
        }
        if b[0] == 0x45, b.count == 55, b[15] == 0x05, b[16] == 0x17 {
            for (id, label, offset) in [("engine_water_temperature", "Охлаждение", 17),
                                         ("inlet_air_temperature", "Воздух на впуске", 20)] {
                if supports(id, mode: 1), b[offset] != 0xFF {
                    result.append(Measurement(id: id, label: label, value: Double(b[offset]) - 40,
                                              unit: "°C", timestamp: time,
                                              source: "Kawasaki BLE · 0x45 · экспериментальный формат"))
                }
            }
        }
        // Upstream 4A mapping has not yet been validated with an EX500G stream.
        // Retain provenance and the raw packet; do not present these as verified.
        if b[0] == 0x4A, b.count >= 15, b[5] == 0x05, b[6] != 0xFF {
            func add(_ id: String, _ label: String, _ value: Double, _ unit: String) {
                result.append(Measurement(id: id, label: label, value: value, unit: unit,
                    timestamp: time, source: "Kawasaki BLE · 0x4A · экспериментально"))
            }
            if supports("engine_speed", mode: 0), !(b[11] == 0xFF && b[12] == 0xFF) {
                add("engine_speed", "Обороты двигателя", Double((Int(b[11] & 0x7F) << 8) | Int(b[12])), "об/мин")
            }
            if supports("wheel_speed", mode: 1), !(b[9] == 0xFF && b[10] == 0xFF) {
                add("wheel_speed", "Скорость колеса", Double((Int(b[9] & 0x01) << 8) | Int(b[10])), "км/ч")
            }
            if supports("gear_position", mode: 1), (b[13] & 0x0F) <= 6 {
                add("gear_position", "Код передачи", Double(b[13] & 0x0F), "")
            }
            if supports("throttle_position", mode: 1) {
                add("throttle_position", "Дроссель", Double(b[14]) * 100 / 255, "%")
            }
        }
        return result
    }

    static func validEnvelope(_ data: Data, command: UInt8) -> Bool {
        let b = Array(data)
        guard b.count >= 5, b.count == Int(b[1]) + 3, b[0] == command else { return false }
        // 45 packets use tagged blocks and need not echo their command at byte 3.
        if command == 0x45 { return b.count == 55 }
        guard b[3] == command else { return false }
        if command == 0x03 { return b.count >= 8 }
        if command == 0x40 { return capabilities(data) != nil }
        if command == 0x41 { return b.count == 85 }
        return true
    }


    static func inspect(_ data: Data) -> String {
        let b = Array(data)
        guard b.count >= 3 else { return "Короткий пакет — сохранён без расшифровки" }
        guard b.count == Int(b[1]) + 3 else { return "Длина пакета не совпадает с заголовком — сохранён без расшифровки" }
        if b[0] == 0x40 {
            guard let all = capabilities(data) else { return "Список возможностей не готов или имеет неизвестный формат. Повторите запрос." }
            let supported = all.filter(\.supported)
            return "Доступно показателей: \(supported.count). " + supported.map(\.label).joined(separator: ", ")
        }
        if b[0] == 0x03 {
            var i = 5
            while i + 2 < b.count {
                guard b[i] == 2 else { i += 1; continue }
                let tag = b[i + 1]
                var end = i + 2
                while end < b.count && b[end] != 2 && b[end] != 0xFF { end += 1 }
                if tag == 0x71 {
                    let text = String(bytes: b[(i + 2)..<end].filter { $0 >= 32 && $0 <= 126 }, encoding: .ascii) ?? ""
                    if !text.isEmpty { return "Код из ответа мотоцикла: \(text)" }
                }
                i = end
            }
            return "Ответ модели сохранён; идентификатор не распознан"
        }
        if b[0] == 0x20, b.count >= 5 {
            let command = String(format: "%02X", b[3])
            let status = b.count == 5 ? (b[4] == 0 ? ": принята" : ": код \(b[4])") : ""
            return "Подтверждение команды 0x\(command)\(status). Это ещё не ответ с данными."
        }
        return String(format: "Ответ 0x%02X, %d байт — сохранён для разбора", b[0], b.count)
    }
}

// GPS continuity is independent of BLE and MapKit so it can be tested on the
// protocol package runner. An inferred road route never becomes a GPS sample.
struct GPSCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct GPSGap: Codable, Identifiable {
    let id: String
    let startedAt: Date
    let endedAt: Date
    let from: GPSCoordinate?
    let to: GPSCoordinate?
    let reason: String
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var isLong: Bool { duration >= 3600 }
}

struct GPSRouteEstimate: Codable, Identifiable, Equatable {
    var id: String { gapID }
    let gapID: String
    let calculatedAt: Date
    let coordinates: [GPSCoordinate]
    let distanceMeters: Double
    let expectedTravelTime: TimeInterval
    let source: String
}

enum GPSContinuity {
    enum Decision: Equatable { case continuous, newSegment, reject }
    static let gapInterval: TimeInterval = 60
    static let staleInterval: TimeInterval = 15

    static func decision(elapsed: TimeInterval, distance: Double, interrupted: Bool) -> Decision {
        guard elapsed > 0, elapsed.isFinite, distance.isFinite, distance >= 0,
              distance / elapsed <= 100 else { return .reject }
        return interrupted || elapsed > gapInterval ? .newSegment : .continuous
    }
}
