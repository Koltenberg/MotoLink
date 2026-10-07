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

/// One apparently good fix surrounded by uncertain observations is not a
/// recovered GPS signal. Require two consecutive good, ordered fixes after
/// startup, a bad observation, or a silence. No speed cap tied to a bike model,
/// interpolation, or smoothing: once recovered, return every current value.
struct GPSSpeedRecovery {
    static let version = 2
    static let maximumGap: TimeInterval = 15
    private var previousObservationAt: Date?
    private var candidateAt: Date?

    mutating func reset() { previousObservationAt = nil; candidateAt = nil }

    mutating func accept(speed: Double, speedAccuracy: Double, horizontalAccuracy: Double,
                         courseAccuracy: Double, at date: Date) -> Double? {
        guard date.timeIntervalSince1970.isFinite else { candidateAt = nil; return nil }
        // A duplicated/cached fix is never the second confirmation and cannot
        // destroy a newer live baseline.
        guard previousObservationAt == nil || date > previousObservationAt! else { return nil }
        previousObservationAt = date
        guard let value = GPSSpeedQuality.accepted(speed: speed, speedAccuracy: speedAccuracy,
            horizontalAccuracy: horizontalAccuracy, courseAccuracy: courseAccuracy) else {
            candidateAt = nil
            return nil
        }
        let previous = candidateAt
        candidateAt = date
        guard let previous, date.timeIntervalSince(previous) <= Self.maximumGap else { return nil }
        return value
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

    /// Callbacks may arrive while a previous journal is replayed off the main
    /// queue. Add only observations captured since its initial manifest was
    /// loaded; never bridge the process restart into the old stream segment.
    mutating func mergeLiveDelta(_ current: Self, since baseline: Self?) {
        let additionalFrames = max(0, current.frameCount - (baseline?.frameCount ?? 0))
        guard additionalFrames > 0 else { return }
        frameCount += additionalFrames
        observedSeconds += max(0, current.observedSeconds - (baseline?.observedSeconds ?? 0))
        if firstFrameAt == nil { firstFrameAt = current.firstFrameAt }
        if let liveLast = current.lastFrameAt, lastFrameAt == nil || liveLast > lastFrameAt! {
            lastFrameAt = liveLast
        }
        previousFrameAt = current.previousFrameAt
    }
}

/// A bounded chart summary. A missing interval or an explicit interruption
/// starts a new stroke, even when its two samples land in neighboring bins.
/// If a gap fits inside one bin, keep only its newest segment in that bin so
/// its average cannot mix observations from both sides of the outage.
struct RideChartSeries {
    struct Bucket {
        private(set) var count = 0
        private(set) var sum = 0.0
        private(set) var last = 0.0
        private(set) var minimum = Double.infinity
        private(set) var maximum = -Double.infinity

        var mean: Double { count > 0 ? sum / Double(count) : 0 }

        mutating func append(_ value: Double) {
            count += 1
            sum += value
            last = value
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
    }

    let span: TimeInterval
    let maximumSilence: TimeInterval
    private(set) var buckets: [Bucket]
    private(set) var breakBefore: [Bool]
    private(set) var gapCount = 0
    private var previousOffset: TimeInterval?
    private var previousBin: Int?

    init(binCount: Int, span: TimeInterval, maximumSilence: TimeInterval) {
        precondition(binCount > 0 && span.isFinite && span > 0 &&
                     maximumSilence.isFinite && maximumSilence > 0)
        self.span = span
        self.maximumSilence = maximumSilence
        buckets = Array(repeating: Bucket(), count: binCount)
        breakBefore = Array(repeating: false, count: binCount)
    }

    @discardableResult
    mutating func append(offset: TimeInterval, value: Double, interrupted: Bool = false) -> Bool {
        guard offset.isFinite, (0...span).contains(offset), value.isFinite,
              previousOffset.map({ offset >= $0 }) ?? true else { return false }
        let index = min(buckets.count - 1, Int(offset / span * Double(buckets.count)))
        let startsNewSegment: Bool
        if let previousOffset {
            startsNewSegment = interrupted || offset - previousOffset > maximumSilence
        } else {
            startsNewSegment = offset > maximumSilence
        }
        if startsNewSegment {
            gapCount += 1
            breakBefore[index] = true
            if previousBin == index { buckets[index] = Bucket() }
        }
        buckets[index].append(value)
        previousOffset = offset
        previousBin = index
        return true
    }

    func connects(_ previousBin: Int?, to currentBin: Int) -> Bool {
        guard let previousBin, buckets.indices.contains(previousBin),
              buckets.indices.contains(currentBin),
              buckets[previousBin].count > 0, buckets[currentBin].count > 0 else { return false }
        return currentBin == previousBin + 1 && !breakBefore[currentBin]
    }
}
