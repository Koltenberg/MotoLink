import ActivityKit

@available(iOS 16.2, *)
struct RideActivityAttributes: ActivityAttributes {
    typealias ContentState = RideLiveActivityState
    let sessionID: String
}
