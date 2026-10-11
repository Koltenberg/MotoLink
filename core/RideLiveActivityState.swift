import Foundation

/// The lock-screen card is a read-only snapshot. It never drives Bluetooth,
/// recording, GPS, or reconnection and it contains no route coordinates.
struct RideLiveActivityState: Codable, Hashable {
    enum Connection: String, Codable, Hashable { case live, waiting, disconnected, paused }
    let motorcycleName: String
    let connection: Connection
    let recording: Bool
    let elapsedSeconds: Int
    let distanceMeters: Double
    let speedKmh: Int?
    let updatedAt: Date
    let staleDate: Date

    static let freshness: TimeInterval = 10
    static let updateInterval: TimeInterval = 5

    static func snapshot(name: String, connected: Bool, lastStreamAt: Date?,
                         recording: Bool, paused: Bool, elapsed: TimeInterval,
                         distance: Double, speed: Double?, speedAt: Date?, now: Date) -> Self {
        let streamFresh = connected && isFresh(lastStreamAt, at: now)
        let speedFresh = streamFresh && isFresh(speedAt, at: now)
        let cleanSpeed = speedFresh ? speed.flatMap { value -> Int? in
            guard value.isFinite, (0...360).contains(value) else { return nil }
            return Int(value.rounded())
        } : nil
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var expires = now.addingTimeInterval(freshness)
        if streamFresh, let lastStreamAt { expires = min(expires, lastStreamAt.addingTimeInterval(freshness)) }
        if cleanSpeed != nil, let speedAt { expires = min(expires, speedAt.addingTimeInterval(freshness)) }
        return Self(motorcycleName: title.isEmpty ? "Мой мотоцикл" : String(title.prefix(60)),
            connection: paused && recording ? .paused : !connected ? .disconnected : streamFresh ? .live : .waiting,
            recording: recording, elapsedSeconds: elapsed.isFinite ? Int(min(604_800, max(0, elapsed))) : 0,
            distanceMeters: distance.isFinite ? min(100_000_000, max(0, distance)) : 0,
            speedKmh: paused ? nil : cleanSpeed, updatedAt: now, staleDate: expires)
    }

    static func shouldDisplay(enabled: Bool, connected: Bool, recording: Bool,
                              hasActivity: Bool, dismissed: Bool) -> Bool {
        enabled && !dismissed && (connected || (hasActivity && recording))
    }

    static func isFresh(_ date: Date?, at now: Date) -> Bool {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age.isFinite && (0...freshness).contains(age)
    }

    func statusText(stale: Bool) -> String {
        if stale { return "Открой Moto Link для обновления" }
        switch connection {
        case .live: return recording ? "Запись идёт · байк на связи" : "Байк на связи"
        case .waiting: return "Подключён · ждём данные"
        case .disconnected: return "Ждём связь · запись продолжается"
        case .paused: return "Пауза · ждём байк"
        }
    }

    var durationText: String {
        if elapsedSeconds >= 3_600 {
            return String(format: "%d:%02d:%02d", elapsedSeconds / 3_600,
                elapsedSeconds / 60 % 60, elapsedSeconds % 60)
        }
        return String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}
