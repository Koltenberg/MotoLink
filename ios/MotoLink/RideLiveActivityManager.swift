import ActivityKit
import Foundation
import UIKit

/// All callers are the existing main-queue controller callbacks. No new radio
/// reads, audio session, location manager, background task, or network service.
final class RideLiveActivityManager {
    static let enabledKey = "MotoLink.lockScreenCard"
    private var implementation: Any?
    private var lastRefreshUptime: TimeInterval?

    func refresh(force: Bool = false, snapshot: () -> RideLiveActivityState) {
        guard #available(iOS 16.2, *) else { return }
        #if targetEnvironment(simulator)
        // Product screenshots/recorder regression fixtures must not start real
        // activities or leave a card from synthetic review data.
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--review-")
            || $0 == "--companion-visual-check" || $0 == "--ride-audit" }) else { return }
        #endif
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let lastRefreshUptime, now - lastRefreshUptime < RideLiveActivityState.updateInterval { return }
        lastRefreshUptime = now
        let driver: RideLiveActivityDriver
        if let existing = implementation as? RideLiveActivityDriver { driver = existing }
        else { driver = RideLiveActivityDriver(); implementation = driver }
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        driver.refresh(snapshot(), enabled: enabled)
    }
}

@available(iOS 16.2, *)
private final class RideLiveActivityDriver {
    private var activity: Activity<RideActivityAttributes>?
    private var observer: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var pending: (RideLiveActivityState, Bool)?
    private var dismissed = false
    private var wasConnected = false
    private var lastEnabled: Bool?
    private var duplicateActivities: [Activity<RideActivityAttributes>] = []
    private var lastRequestAttemptUptime: TimeInterval?

    init() {
        // Reuse the system's current card after a process restoration.
        activity = Activity<RideActivityAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
        duplicateActivities = Activity<RideActivityAttributes>.activities.filter { $0.id != activity?.id }
        if let activity { observe(activity) }
    }

    deinit { observer?.cancel(); worker?.cancel() }

    func refresh(_ state: RideLiveActivityState, enabled: Bool) {
        // Coalesce updates: only one ActivityKit operation is awaited at a
        // time, and a later disconnected/off snapshot replaces pending data.
        pending = (state, enabled)
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while let next = self.pending {
                self.pending = nil
                await self.apply(next.0, enabled: next.1)
            }
            self.worker = nil
        }
    }

    @MainActor private func apply(_ state: RideLiveActivityState, enabled: Bool) async {
        for duplicate in duplicateActivities { await duplicate.end(nil, dismissalPolicy: .immediate) }
        duplicateActivities.removeAll()
        if enabled && lastEnabled == false { dismissed = false }
        lastEnabled = enabled
        let connected = state.connection == .live || state.connection == .waiting
        // A swipe dismisses this connection's card. Do not recreate it every
        // five seconds; a later disconnected-to-connected session may start it.
        if connected && !wasConnected { dismissed = false }
        wasConnected = connected
        if let existing = activity, existing.activityState == .dismissed {
            dismissed = true
            activity = nil
        } else if let existing = activity, existing.activityState == .ended {
            activity = nil
        }
        let display = RideLiveActivityState.shouldDisplay(enabled: enabled, connected: connected,
            recording: state.recording, hasActivity: activity != nil, dismissed: dismissed)
        guard display, ActivityAuthorizationInfo().areActivitiesEnabled else {
            if let existing = activity {
                activity = nil
                observer?.cancel(); observer = nil
                await existing.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        let content = ActivityContent(state: state, staleDate: state.staleDate)
        if let existing = activity {
            await existing.update(content)
            return
        }
        // Starting local Live Activities in the background is not permitted.
        // Existing cards still receive BLE/recording snapshots in the background.
        guard UIApplication.shared.applicationState == .active else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if let lastRequestAttemptUptime, uptime - lastRequestAttemptUptime < 30 { return }
        lastRequestAttemptUptime = uptime
        do {
            let new = try Activity.request(attributes: RideActivityAttributes(sessionID: UUID().uuidString),
                content: content, pushType: nil)
            activity = new
            lastRequestAttemptUptime = nil
            observe(new)
        } catch {
            // A denied/unavailable card must never interrupt the ride or radio.
            // The next foreground callback can retry after the bounded cooldown.
        }
    }

    private func observe(_ observed: Activity<RideActivityAttributes>) {
        observer?.cancel()
        observer = Task { @MainActor [weak self] in
            for await state in observed.activityStateUpdates {
                guard !Task.isCancelled, let self, self.activity?.id == observed.id else { return }
                if state == .dismissed {
                    self.dismissed = true
                    self.activity = nil
                    return
                }
                if state == .ended { self.activity = nil; return }
            }
        }
    }
}
