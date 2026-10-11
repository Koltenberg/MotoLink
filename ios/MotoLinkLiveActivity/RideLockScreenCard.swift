import SwiftUI

struct RideLockScreenCard: View {
    let state: RideLiveActivityState
    let stale: Bool
    private var statusColor: Color {
        stale ? .gray : state.connection == .live ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "speedometer")
                    .font(.system(size: 26, weight: .medium)).foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.motorcycleName).font(.system(.headline, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("Moto Link").font(.system(.caption2, design: .rounded)).foregroundStyle(.gray)
                }
                Spacer(minLength: 5)
                if !stale, let speed = state.speedKmh {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(speed)").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("км/ч · байк").font(.system(.caption2, design: .rounded)).foregroundStyle(.gray)
                    }.accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(state.statusText(stale: stale))
                    .font(.system(.caption, design: .rounded)).foregroundStyle(statusColor)
                    .lineLimit(2)
            }
            if state.recording {
                HStack {
                    Label(state.durationText, systemImage: state.connection == .paused ? "pause.fill" : "record.circle")
                    Spacer()
                    Text(state.distanceMeters / 1_000, format: .number.precision(.fractionLength(1))) + Text(" км")
                }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit().foregroundStyle(stale ? Color.gray : Color.white)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

#if targetEnvironment(simulator)
struct RideLockScreenVisualCheck: View {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func sample(_ connected: Bool, _ paused: Bool, _ age: Double) -> RideLiveActivityState {
        RideLiveActivityState.snapshot(name: "Takihiro", connected: connected,
            lastStreamAt: now.addingTimeInterval(-age), recording: true, paused: paused,
            elapsed: 2_470, distance: 37_500, speed: 72, speedAt: now, now: now)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Экран блокировки").font(.title2.bold()).foregroundStyle(.white)
                RideLockScreenCard(state: sample(true, false, 0), stale: false)
                RideLockScreenCard(state: sample(true, false, 30), stale: false)
                RideLockScreenCard(state: sample(false, true, 30), stale: false)
                RideLockScreenCard(state: sample(true, false, 0), stale: true)
            }
            .padding(18)
        }
        .background(Color(red: 0.06, green: 0.065, blue: 0.08))
        .preferredColorScheme(.dark)
    }
}
#endif
