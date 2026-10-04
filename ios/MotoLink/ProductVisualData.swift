#if targetEnvironment(simulator)
import Foundation
import UIKit
import SwiftUI

/// Fictional visual fixtures, excluded from every device build. Never sent to BLE
/// or written to a user's ride journal. Used by the actual dashboard renderers.
enum ProductVisualData {
    /// Record the actual scene geometry. Headless simctl can capture the
    /// physical portrait buffer even when the interface has rotated inside it.
    @MainActor static func prepareLandscapeReview() {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = directory.appendingPathComponent("MotoLinkVisualOrientation.json")
        try? FileManager.default.removeItem(at: file)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
            let window = scene.windows.first(where: { $0.isKeyWindow })
            window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            var failure: String?
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                failure = error.localizedDescription
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let bounds = window?.bounds ?? .zero
                let evidence: [String: Any] = [
                    "interfaceLandscape": scene.interfaceOrientation.isLandscape,
                    "interfaceOrientation": scene.interfaceOrientation.rawValue,
                    "windowWidth": Double(bounds.width), "windowHeight": Double(bounds.height),
                    "sceneWidth": Double(scene.coordinateSpace.bounds.width),
                    "sceneHeight": Double(scene.coordinateSpace.bounds.height),
                    "capturedAt": Date().timeIntervalSince1970,
                    "error": failure.map { $0 as Any } ?? NSNull()
                ]
                do { try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: file, options: .atomic) }
                catch { print("Visual orientation evidence failed: \(error)") }
            }
        }
    }

    static func measurements(at now: Date = Date()) -> [MotoProtocol.Measurement] {
        let arguments = ProcessInfo.processInfo.arguments
        let idle = arguments.contains("--review-bike-idle")
        let fast = arguments.contains("--review-bike-high-speed")
        let timestamp = arguments.contains("--review-bike-stale") ? now.addingTimeInterval(-31) : now
        return [("wheel_speed", "Скорость", idle ? 0.0 : fast ? 164.0 : 68.0, "км/ч"),
         ("gear_position", "Передача", idle ? 0.0 : fast ? 6.0 : 3.0, ""),
         ("engine_speed", "Обороты", idle ? 1200.0 : fast ? 9000.0 : 5300.0, "об/мин"),
         ("engine_water_temperature", "Температура", idle ? 42.0 : fast ? 96.0 : 92.0, "°C")].map {
            MotoProtocol.Measurement(id: $0.0, label: $0.1, value: $0.2, unit: $0.3,
                                     timestamp: timestamp, source: "Simulator example")
        }
    }
    static func speedComparison() -> (gps: Double?, bike: Double?, difference: Double?) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--review-bike-stale") { return (nil, nil, nil) }
        if arguments.contains("--review-bike-idle") { return (0, 0, 0) }
        if arguments.contains("--review-bike-high-speed") { return (160, 164, 4) }
        return (64, 68, 4)
    }
    static func bikeActivitySnapshot(at now: Date = Date()) -> BikeActivitySnapshot {
        BikeActivitySnapshot.sample(connected: true,
            ready: !ProcessInfo.processInfo.arguments.contains("--review-bike-partial"),
            measurements: measurements(at: now), now: now)
    }
    static func catalogue(at now: Date = Date()) -> TelemetryPresentation {
        let readings = measurements(at: now)
        var value = TelemetryPresentation()
        value.configure(readings.map {
            MotoProtocol.Capability(id: $0.id, label: $0.label, mode: $0.id == "engine_speed" ? 0 : 1)
        })
        value.receive(Data(), decoded: readings)
        return value
    }

    static let graphRide: RideSummary = {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return RideSummary(id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                           startedAt: start, endedAt: start.addingTimeInterval(900),
                           lastSavedAt: start.addingTimeInterval(900), trigger: "simulator")
    }()

    /// Synthetic bike values with a real empty interval. A graph must leave the
    /// interval blank rather than visually joining both sides of an outage.
    static let graphRecords: [RideRecord] = {
        let start = graphRide.startedAt
        var records: [RideRecord] = []
        for second in stride(from: 0, through: 900, by: 5) {
            let at = start.addingTimeInterval(TimeInterval(second))
            if second == 350 {
                records.append(RideRecord(kind: "bluetooth", timestamp: at, detail: "disconnected"))
            }
            if (350...430).contains(second) { continue }
            let progress = Double(second) / 900
            let values: [(String, String, Double, String)] = [
                ("wheel_speed", "Скорость байка", 35 + 55 * abs(sin(progress * 12)), "км/ч"),
                ("engine_speed", "Обороты", 2500 + 4500 * abs(sin(progress * 12 + 0.2)), "об/мин"),
                ("throttle_position", "Дроссель", 12 + 60 * abs(sin(progress * 12 + 0.6)), "%")
            ]
            for value in values {
                records.append(RideRecord(kind: "telemetry", timestamp: at,
                    measurement: MotoProtocol.Measurement(id: value.0, label: value.1,
                        value: value.2, unit: value.3, timestamp: at, source: "Simulator example")))
            }
        }
        return records
    }()

    /// Public-place coordinates generated for simulator screenshots. No phone
    /// location or journal is read, and the middle interval is deliberately blank.
    static let routePoints: [TrackPoint] = {
        let start = graphRide.startedAt
        let first: [TrackPoint] = (0..<35).map { index -> TrackPoint in
            let offset = Double(index)
            let latitude: Double = 37.7749 + offset * 0.00011 + sin(offset / 4.0) * 0.00005
            let longitude: Double = -122.4194 + offset * 0.00017
            return TrackPoint(timestamp: start.addingTimeInterval(offset * 5.0),
                latitude: latitude,
                longitude: longitude,
                altitude: nil, accuracy: 6, speed: nil, segment: 0)
        }
        let second: [TrackPoint] = (0..<35).map { index -> TrackPoint in
            let offset = Double(index)
            let latitude: Double = 37.7810 + offset * 0.00009 + sin(offset / 5.0) * 0.00004
            let longitude: Double = -122.4080 + offset * 0.00016
            return TrackPoint(timestamp: start.addingTimeInterval(400.0 + offset * 5.0),
                latitude: latitude,
                longitude: longitude,
                altitude: nil, accuracy: 6, speed: nil, segment: 1)
        }
        return first + second
    }()

    static let routeRide: RideSummary = {
        var ride = graphRide
        ride.distanceMeters = 5_430
        ride.pointCount = routePoints.count
        return ride
    }()

    static let routeGaps: [GPSGap] = {
        guard routePoints.count >= 36 else { return [] }
        let from = routePoints[34], to = routePoints[35]
        return [GPSGap(id: "simulator-gap", startedAt: from.timestamp, endedAt: to.timestamp,
                       from: from.gpsCoordinate, to: to.gpsCoordinate,
                       reason: "Вымышленный пропуск GPS для проверки интерфейса")]
    }()

    static let routeEstimates: [GPSRouteEstimate] = {
        guard let gap = routeGaps.first, let from = gap.from, let to = gap.to else { return [] }
        let coordinates = (0...12).map { index -> GPSCoordinate in
            let fraction = Double(index) / 12
            return GPSCoordinate(latitude: from.latitude + (to.latitude - from.latitude) * fraction
                                     + sin(fraction * .pi) * 0.0005,
                                 longitude: from.longitude + (to.longitude - from.longitude) * fraction)
        }
        return [GPSRouteEstimate(gapID: gap.id, calculatedAt: graphRide.startedAt,
            coordinates: coordinates, distanceMeters: 1_850, expectedTravelTime: 300,
            source: "Вымышленный вариант, не запись GPS")]
    }()
}

/// A capture handshake from the mounted application view, not merely its PID.
/// This type and its files do not exist in iPhone builds.
struct ProductVisualReadyProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProductVisualReadyView { ProductVisualReadyView() }
    func updateUIView(_ uiView: ProductVisualReadyView, context: Context) {}
}

/// Evidence from the real panel timers, not a parallel test timer. Excluded from
/// physical-device builds and enabled only by a tokenized ride review launch.
enum ProductVisualRefreshProbe {
    private static let instanceToken = UUID().uuidString
    private static var observers: [NSObjectProtocol] = []
    private static var events: [[String: Any]] = []
    private static var nextSequence = 0

    private static var launchToken: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--review-ride"),
              let index = arguments.firstIndex(of: "--visual-review-token"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func sample(panel: String, fromTimer: Bool) {
        guard launchToken != nil else { return }
        if observers.isEmpty {
            for (name, kind) in [(UIApplication.didEnterBackgroundNotification, "background"),
                                 (UIApplication.didBecomeActiveNotification, "active")] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    append(kind: kind)
                })
            }
        }
        append(kind: fromTimer ? "timer" : "sample", panel: panel)
    }

    private static func append(kind: String, panel: String? = nil) {
        guard let launchToken else { return }
        assert(Thread.isMainThread)
        nextSequence += 1
        var event: [String: Any] = ["sequence": nextSequence, "kind": kind,
            "at": Date().timeIntervalSince1970, "uptime": ProcessInfo.processInfo.systemUptime,
            "appState": UIApplication.shared.applicationState.rawValue]
        if let panel { event["panel"] = panel }
        events.append(event)
        if events.count > 120 { events.removeFirst(events.count - 120) }
        let evidence: [String: Any] = ["launchToken": launchToken, "instanceToken": instanceToken,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "capturedAt": Date().timeIntervalSince1970, "events": events]
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("MotoLinkRefreshLifecycle.json"), options: .atomic)
        } catch { print("Visual refresh evidence failed: \(error)") }
    }
}

final class ProductVisualReadyView: UIView {
    private var timer: Timer?
    private var visibleSince: TimeInterval?
    private var hasLayout = false

    override func layoutSubviews() { super.layoutSubviews(); hasLayout = true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate(); timer = nil; visibleSince = nil
        guard window != nil, token != nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkReady() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private var token: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--visual-review-token"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    private func checkReady() {
        guard let token, hasLayout, let window, window.isKeyWindow, !window.isHidden,
              window.alpha > 0, window.bounds.width > 0, window.bounds.height > 0,
              window.windowScene?.activationState == .foregroundActive,
              window.rootViewController?.viewIfLoaded?.window === window else {
            visibleSince = nil; return
        }
        let arguments = ProcessInfo.processInfo.arguments
        // The focused reading is a full-screen presentation. A visible root
        // dashboard alone must not satisfy its screenshot readiness handshake.
        if arguments.contains("--review-focus-rpm") || arguments.contains("--review-focus-gps") {
            guard let presented = window.rootViewController?.presentedViewController,
                  presented.viewIfLoaded?.window === window else {
                visibleSince = nil; return
            }
        }
        let expected: UIUserInterfaceStyle = arguments.contains("--review-light") ? .light
            : arguments.contains("--review-ride") || arguments.contains("--review-graphs")
                || arguments.contains("--review-route-fullscreen")
                || arguments.contains("--review-graphs-fullscreen") ? .dark : .unspecified
        // Simulator-only capture preference. Never changes the user's stored theme.
        if expected != .unspecified && window.overrideUserInterfaceStyle != expected {
            window.overrideUserInterfaceStyle = expected
            visibleSince = nil; return
        }
        guard expected == .unspecified || window.traitCollection.userInterfaceStyle == expected else {
            visibleSince = nil; return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let since = visibleSince else { visibleSince = now; return }
        guard now - since >= 2 else { return }
        let mode = arguments.contains("--review-ride") ? "ride"
            : arguments.contains("--review-route-fullscreen") ? "route"
            : arguments.contains("--review-graphs") || arguments.contains("--review-graphs-fullscreen") ? "graphs"
            : arguments.contains("--companion-visual-check") ? "companion" : "garage"
        let evidence: [String: Any] = [
            "ready": true, "launchToken": token, "mode": mode,
            "appearance": window.traitCollection.userInterfaceStyle == .dark ? "dark" : "light",
            "windowWidth": Double(window.bounds.width), "windowHeight": Double(window.bounds.height),
            "capturedAt": Date().timeIntervalSince1970, "visibleSeconds": now - since
        ]
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("MotoLinkVisualReady.json"), options: .atomic)
            timer?.invalidate(); timer = nil
        } catch { print("Visual readiness evidence failed: \(error)") }
    }
}
#endif
