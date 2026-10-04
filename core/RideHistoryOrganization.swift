import Foundation

protocol RideHistoryItem {
    var id: UUID { get }
    var startedAt: Date { get }
    var isFavorite: Bool { get }
}

/// Calendar boundaries, not fixed 24-hour/7-day durations, keep day groups
/// correct across time zones and daylight-saving changes. Favorites occur once.
enum RideHistoryOrganization {
    enum Bucket: Hashable {
        case favorites, day(Date), previousWeek(Date), month(Date)

        var id: String {
            switch self {
            case .favorites: return "favorites"
            case .day(let date): return "day:\(date.timeIntervalSince1970)"
            case .previousWeek(let date): return "week:\(date.timeIntervalSince1970)"
            case .month(let date): return "month:\(date.timeIntervalSince1970)"
            }
        }
        var initiallyExpanded: Bool {
            switch self {
            case .favorites, .day: return true
            case .previousWeek, .month: return false
            }
        }
    }

    struct Group<Item: RideHistoryItem>: Identifiable {
        let bucket: Bucket
        let rides: [Item]
        var id: String { bucket.id }
    }

    static func groups<Item: RideHistoryItem>(_ rides: [Item], at now: Date = Date(),
                                              calendar: Calendar = .current) -> [Group<Item>] {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let previous = week.flatMap { calendar.date(byAdding: .weekOfYear, value: -1, to: $0.start) }
            .flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
        var grouped: [Bucket: [Item]] = [:]
        for ride in rides {
            let bucket: Bucket
            if ride.isFavorite { bucket = .favorites }
            else if let week, ride.startedAt >= week.start, ride.startedAt < week.end {
                bucket = .day(calendar.startOfDay(for: ride.startedAt))
            } else if let previous, ride.startedAt >= previous.start, ride.startedAt < previous.end {
                bucket = .previousWeek(previous.start)
            } else {
                bucket = .month(calendar.dateInterval(of: .month, for: ride.startedAt)?.start ?? ride.startedAt)
            }
            grouped[bucket, default: []].append(ride)
        }
        return grouped.map { bucket, items in
            Group(bucket: bucket, rides: items.sorted {
                $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
            })
        }.sorted { lhs, rhs in
            if lhs.bucket == .favorites { return rhs.bucket != .favorites }
            if rhs.bucket == .favorites { return false }
            return lhs.rides[0].startedAt > rhs.rides[0].startedAt
        }
    }
}
