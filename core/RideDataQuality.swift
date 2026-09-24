import Foundation

/// Conservative display/summary filter, not proof of true ground speed. Keep
/// every original CLLocation observation in the raw journal for later review.
enum GPSSpeedQuality {
    static func accepted(speed: Double, speedAccuracy: Double,
                         horizontalAccuracy: Double, courseAccuracy: Double) -> Double? {
        guard speed.isFinite, (0...100).contains(speed),
              speedAccuracy.isFinite, (0...8).contains(speedAccuracy),
              horizontalAccuracy.isFinite, (0...25).contains(horizontalAccuracy) else { return nil }
        // New road logs contained 313 km/h with apparently good speed accuracy
        // but 180-degree direction uncertainty after a long outage. Direction
        // is not meaningful when stationary, so apply this only above 18 km/h.
        if speed >= 5 {
            guard courseAccuracy.isFinite, (0...45).contains(courseAccuracy) else { return nil }
        }
        return speed
    }
}

/// Counts observed stream intervals, not the duration of the Bluetooth icon.
/// Missing intervals and app restarts must never be reported as captured data.
struct RideTelemetryCoverage: Codable, Equatable {
    private(set) var frameCount = 0
    private(set) var observedSeconds: TimeInterval = 0
    private(set) var firstFrameAt: Date?
    private(set) var lastFrameAt: Date?
    private var previousFrameAt: Date?

    private enum CodingKeys: String, CodingKey {
        case frameCount, observedSeconds, firstFrameAt, lastFrameAt
    }

    mutating func receive(at date: Date) {
        guard date.timeIntervalSince1970.isFinite,
              lastFrameAt == nil || date > lastFrameAt! else { return }
        if let previousFrameAt {
            let interval = date.timeIntervalSince(previousFrameAt)
            if interval <= 15 { observedSeconds += interval }
        }
        frameCount += 1
        if firstFrameAt == nil { firstFrameAt = date }
        lastFrameAt = date
        previousFrameAt = date
    }

    mutating func endSegment() { previousFrameAt = nil }
}
