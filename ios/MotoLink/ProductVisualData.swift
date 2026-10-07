#if targetEnvironment(simulator)
import Foundation
import UIKit
import SwiftUI
import CoreLocation

/// Fictional visual fixtures, excluded from every device build. Never sent to BLE
/// or written to a user's ride journal. Used by the actual dashboard renderers.
enum ProductVisualData {
    static func connectionState(arguments: [String] = ProcessInfo.processInfo.arguments) -> RideConnectionPresentation.State {
        if arguments.contains("--review-gps-recording") { return .disconnected }
        if arguments.contains("--review-bike-waiting") {
            return .waitingForData
        }
        if arguments.contains("--review-bike-stale") { return .stale }
        return .receiving
    }

    private static let previewRecordingStart = Date().addingTimeInterval(-742)

    /// Read-only view state. It never starts the recorder, changes a setting,
    /// requests GPS, writes a ride, or becomes a candidate for export.
    static func recordingPreview(arguments: [String] = ProcessInfo.processInfo.arguments) -> RideSummary? {
        guard arguments.contains("--review-gps-recording") else { return nil }
        var ride = RideSummary(id: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
                               startedAt: previewRecordingStart, endedAt: nil,
                               lastSavedAt: Date(), trigger: "simulator")
        ride.distanceMeters = 6_420
        ride.pointCount = 143
        return ride
    }

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
        if arguments.contains("--review-bike-waiting") || arguments.contains("--review-gps-recording") {
            return []
        }
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
        if arguments.contains("--review-gps-recording") { return (64, nil, nil) }
        if arguments.contains("--review-bike-waiting") { return (nil, nil, nil) }
        if arguments.contains("--review-bike-stale") { return (nil, nil, nil) }
        if arguments.contains("--review-bike-idle") { return (0, 0, 0) }
        if arguments.contains("--review-bike-high-speed") { return (160, 164, 4) }
        return (64, 68, 4)
    }
    static func bikeActivitySnapshot(at now: Date = Date()) -> BikeActivitySnapshot {
        let state = connectionState()
        return BikeActivitySnapshot.sample(connected: state != .disconnected,
            ready: state != .waitingForData && state != .disconnected
                && !ProcessInfo.processInfo.arguments.contains("--review-bike-partial"),
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

/// Exercises the real recorder and real append-only files, including recovery
/// callbacks. This code is absent from device builds. The capture runner invokes
/// it only after all screenshots, in its disposable, initially empty container.
/// No user files are removed, no Bluetooth packets are transmitted, and location
/// access must be absent/denied before this test is allowed to begin.
@MainActor
final class SimulatorRideLifecycleAudit {
    private static var running: SimulatorRideLifecycleAudit?
    private let recorder: RideRecorder
    private let runID = UUID()
    private let bikeID = UUID()
    private let startedAt = Date()
    private let launchToken: String
    private var checks: [[String: Any]] = []
    private var failures: [String] = []
    private var retainedRecorders: [RideRecorder] = []
    private var completed = false
    private var timeout: Task<Void, Never>?

    static func start(recorder: RideRecorder) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--audit-ride-lifecycle"), running == nil else { return }
        let tokenIndex = arguments.firstIndex(of: "--visual-review-token")
        let token = tokenIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? ""
        let audit = SimulatorRideLifecycleAudit(recorder: recorder, launchToken: token)
        running = audit
        audit.timeout = Task { [weak audit] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let audit, !audit.completed else { return }
            audit.failures.append("Actual recorder/archive callbacks exceeded 30 seconds")
            audit.writeReport()
        }
        Task { await audit.run() }
    }

    private init(recorder: RideRecorder, launchToken: String) {
        self.recorder = recorder
        self.launchToken = launchToken
    }

    private struct AuditFailure: Error { let message: String }

    @discardableResult
    private func check(_ condition: Bool, _ name: String) -> Bool {
        checks.append(["name": name, "passed": condition])
        if !condition { failures.append(name) }
        return condition
    }

    private func require(_ condition: Bool, _ name: String) throws {
        if !check(condition, name) { throw AuditFailure(message: name) }
    }

    private func run() async {
        do {
            let directory = try rideDirectory()
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            try require(!launchToken.isEmpty && recorder.active == nil && recorder.history.isEmpty
                && !files.contains { ["json", "jsonl"].contains($0.pathExtension) }, "empty_disposable_container")
            try require(recorder.authorization == .notDetermined || recorder.authorization == .denied
                || recorder.authorization == .restricted, "gps_unavailable_precondition")

            recorder.bluetoothReadyForCapture()
            try require(recorder.active == nil, "no_auto_record_without_selected_connected_bike")
            recorder.observeBluetoothPeripheral(bikeID)
            recorder.bluetoothChanged(true)
            try require(recorder.active == nil, "connection_waits_for_capture_readiness")
            recorder.bluetoothReadyForCapture()
            try require(recorder.active == nil && !recorder.autoRecord,
                        "compact_default_does_not_create_detailed_journal")
            recorder.setAutoRecord(true)
            guard let first = recorder.active else { throw AuditFailure(message: "automatic ride did not start") }
            try require(first.trigger == "bluetooth" && first.pointCount == 0, "gps_unavailable_auto_capture")

            recorder.bluetoothReadyForCapture()
            try require(recorder.active?.id == first.id, "repeated_ready_keeps_active_ride")
            injectSample(into: recorder, value: 2_100)
            try await Task.sleep(nanoseconds: 120_000_000)
            recorder.confirmedBluetoothBoundary(bikeID)
            recorder.bluetoothChanged(false)
            try require(recorder.active?.id == first.id, "transport_drop_keeps_recording_identity")
            recorder.bluetoothChanged(true)
            recorder.bluetoothReadyForCapture()
            injectSample(into: recorder, value: 2_300)
            try require(recorder.active?.id == first.id && recorder.active?.telemetryCount == 4,
                        "reconnect_continues_same_journal")

            let firstSaved = await finish(recorder)
            try require(recorder.active == nil && recorder.history.filter { $0.id == first.id }.count == 1,
                        "rapid_finish_has_single_completed_ride")
            try require(firstSaved.streamCoverage?.frameCount == 2,
                        "stream_coverage_survives_transport_drop_and_finish")
            try verifySaved(firstSaved, expectedMeasurements: 4, minimumRawEvents: 2)
            let loaded = try await load(firstSaved, using: recorder)
            try require(loaded.filter { $0.kind == "motorcycle" }.count == 4
                && loaded.filter { $0.kind == "finished" }.count == 1,
                        "actual_archive_load_preserves_measurements_and_finish")

            recorder.observeBluetoothPeripheral(bikeID) // Same connection, e.g. service repair.
            recorder.bluetoothChanged(true)
            recorder.bluetoothReadyForCapture()
            // The readiness path itself must not request GPS. The runner uses
            // denied permission; accepting notDetermined must not open a prompt.
            if recorder.authorization != .notDetermined { recorder.prepareAutomaticCapture() }
            try require(recorder.active == nil, "same_connection_gatt_ready_respects_finish")
            recorder.confirmedBluetoothBoundary(bikeID)
            recorder.bluetoothChanged(false)
            recorder.bluetoothChanged(true)
            recorder.bluetoothReadyForCapture()
            guard let second = recorder.active else { throw AuditFailure(message: "physical boundary did not start next ride") }
            try require(second.id != first.id, "new_physical_connection_starts_new_ride")
            let secondSaved = await finish(recorder)
            try verifySaved(secondSaved, expectedMeasurements: 0, minimumRawEvents: 0)
            try await verifyExport(firstSaved)

            // A finished request arrives synchronously before the real archive's
            // asynchronous recovery callback. A new physical connection arrives
            // between those events. Neither the old Finish nor the new trip may
            // be lost, and neither may inherit the other's recording identity.
            let recoverySeed = try await seedUnfinishedRide()
            let recovering = RideRecorder()
            retainedRecorders.append(recovering)
            try require(recovering.restoringRoute && recovering.active?.id == recoverySeed.id,
                        "actual_unfinished_journal_enters_async_recovery")
            recovering.observeBluetoothPeripheral(bikeID)
            recovering.bluetoothChanged(true)
            var requestedAt: Date?
            let recoveredSaved = await finish(recovering) {
                let intent = RideFinishIntent.load(UserDefaults.standard)
                requestedAt = intent?.requestedAt
                self.check(intent?.rideID == recoverySeed.id && recovering.finishRequested
                    && UserDefaults.standard.string(forKey: "MotoLink.autoRecordFinishedPeripheral") == self.bikeID.uuidString,
                           "finish_intent_durable_before_recovery_callback")
                let before = recovering.active
                self.injectSample(into: recovering, value: 9_900)
                self.check(recovering.active?.telemetryCount == before?.telemetryCount
                    && recovering.active?.rawEventCount == before?.rawEventCount,
                           "pending_finish_rejects_late_capture")
                recovering.confirmedBluetoothBoundary(self.bikeID)
                recovering.bluetoothChanged(false)
                recovering.bluetoothChanged(true)
                recovering.bluetoothReadyForCapture()
            }
            try require(recoveredSaved.id == recoverySeed.id && requestedAt != nil
                && abs((recoveredSaved.endedAt ?? .distantPast).timeIntervalSince(requestedAt ?? .distantFuture)) < 0.002,
                        "recovery_finish_preserves_button_time")
            try verifySaved(recoveredSaved, expectedMeasurements: 1, minimumRawEvents: 1)
            guard let afterRecovery = recovering.active else {
                throw AuditFailure(message: "new physical connection was suppressed by deferred Finish")
            }
            try require(afterRecovery.id != recoverySeed.id,
                        "connection_during_recovery_starts_next_ride_after_save")
            let afterRecoverySaved = await finish(recovering)
            try verifySaved(afterRecoverySaved, expectedMeasurements: 0, minimumRawEvents: 0)

            // Simulate process death after the persistent Finish intent, before
            // the finished line. The next real recorder must replay that intent,
            // never append fresh telemetry to the abandoned trip, and honor its
            // original end time without a second user action.
            let crashSeed = try await seedUnfinishedRide()
            let crashFinishAt = crashSeed.startedAt.addingTimeInterval(3)
            RideFinishIntent(rideID: crashSeed.id, requestedAt: crashFinishAt).save(UserDefaults.standard)
            UserDefaults.standard.set(bikeID.uuidString, forKey: "MotoLink.autoRecordFinishedPeripheral")
            let crashed = RideRecorder()
            retainedRecorders.append(crashed)
            try require(crashed.restoringRoute && crashed.finishRequested && crashed.active?.id == crashSeed.id,
                        "persisted_finish_intent_suppresses_capture_on_relaunch")
            let beforeCrashInjection = crashed.active
            injectSample(into: crashed, value: 9_999)
            try require(crashed.active?.telemetryCount == beforeCrashInjection?.telemetryCount
                && crashed.active?.rawEventCount == beforeCrashInjection?.rawEventCount,
                        "relaunch_finish_intent_rejects_late_capture")
            crashed.observeBluetoothPeripheral(bikeID)
            crashed.bluetoothChanged(true)
            crashed.bluetoothReadyForCapture()
            // Observe automatic completion, without pressing Finish a second time.
            try await waitUntil { crashed.active == nil && !crashed.restoringRoute && !crashed.finishingRide }
            guard let crashSaved = crashed.history.first(where: { $0.id == crashSeed.id }) else {
                throw AuditFailure(message: "persisted Finish was not automatically completed")
            }
            try require(abs((crashSaved.endedAt ?? .distantPast).timeIntervalSince(crashFinishAt)) < 0.002
                && RideFinishIntent.load(UserDefaults.standard) == nil,
                        "persisted_finish_completes_without_second_user_action")
            try verifySaved(crashSaved, expectedMeasurements: 1, minimumRawEvents: 1)

            let finalRecorder = RideRecorder()
            retainedRecorders.append(finalRecorder)
            let expectedIDs = Set([firstSaved.id, secondSaved.id, recoveredSaved.id,
                                   afterRecoverySaved.id, crashSaved.id])
            try require(finalRecorder.active == nil && Set(finalRecorder.history.map(\.id)) == expectedIDs,
                        "completed_history_survives_fresh_recorder")
            finalRecorder.observeBluetoothPeripheral(bikeID)
            finalRecorder.bluetoothChanged(true)
            finalRecorder.bluetoothReadyForCapture()
            try require(finalRecorder.active == nil, "finish_suppression_survives_fresh_recorder")
            try require([recorder, recovering, crashed, finalRecorder].allSatisfy { $0.error == nil },
                        "no_archive_error_during_lifecycle_audit")
            try await verifyCompactMileage()
            try await verifyGPSRecovery()
            try await verifyParkingPause()
        } catch {
            let message = (error as? AuditFailure)?.message ?? error.localizedDescription
            if !failures.contains(message) { failures.append(message) }
        }
        writeReport()
    }

    private func verifyCompactMileage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MileageAudit-" + runID.uuidString)
        let tracker = MileageTracker(directory: directory)
        let id = UUID()
        var estimate: Double?
        var distance = 0.0
        tracker.onUpdate = { estimate = $0; distance = $1 }
        tracker.observeBike(id)
        var garage = CompanionData(bikeName: "Audit", fuelEntries: [FuelEntry(
            date: Date().addingTimeInterval(-86_400), odometerKm: 26_000,
            liters: nil, cost: nil, fullTank: true)])
        tracker.updateCompanion(garage, initialEstimate: nil)
        tracker.bluetoothChanged(true)
        tracker.onLiveGPSSpeed = { [weak self] speed, date in self?.recorder.updateLiveGPSSpeed(speed, at: date) }
        let start = Date().addingTimeInterval(-1)
        for offset in [0.0, 0.5, 1.0] {
            tracker.recordMeasurements([.init(id: "wheel_speed", label: "Скорость", value: 36,
                unit: "км/ч", timestamp: start.addingTimeInterval(offset), source: "simulator audit")])
        }
        tracker.recordGPSSpeed(10, at: start.addingTimeInterval(1), receivedAt: Date(), forDashboard: true)
        try require(recorder.active == nil && recorder.speedMS == 10,
                    "compact_gps_updates_dashboard_without_creating_journal")
        tracker.bluetoothChanged(false)
        try await waitUntil { !tracker.checkpointPendingForAudit }
        try require(abs(distance - 0.01) < 0.00001 && abs((estimate ?? 0) - 26_000.01) < 0.00001,
                    "compact_mileage_counts_without_detailed_journal")
        garage.fuelEntries[0].odometerKm = 25_000
        tracker.updateCompanion(garage, initialEstimate: nil)
        try require(abs((estimate ?? 0) - 25_000.01) < 0.00001,
                    "compact_corrected_historical_reading_preserves_new_mileage")
        tracker.observeBike(UUID())
        tracker.bluetoothChanged(true)
        let otherStart = Date().addingTimeInterval(-1)
        for offset in [0.0, 1.0] {
            tracker.recordMeasurements([.init(id: "wheel_speed", label: "Скорость", value: 72,
                unit: "км/ч", timestamp: otherStart.addingTimeInterval(offset), source: "simulator audit")])
        }
        tracker.bluetoothChanged(false)
        try await waitUntil { !tracker.checkpointPendingForAudit }
        try require(abs(distance - 0.01) < 0.00001 && abs((estimate ?? 0) - 25_000.01) < 0.00001,
                    "compact_other_bike_does_not_change_garage_mileage")
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try require(entries.map(\.lastPathComponent) == ["MotoLink-mileage.json"],
                    "compact_mileage_only_one_aggregate_file")
        let payload = try Data(contentsOf: entries[0])
        try require(payload.count < 8_192 && !String(decoding: payload, as: UTF8.self).contains("latitude"),
                    "compact_mileage_has_no_coordinate_or_packet_archive")
        let export = try tracker.exportSnapshot()
        let exported = try JSONSerialization.jsonObject(with: export) as? [String: Any]
        try require(exported?["ledger"] != nil && export.count < 8_192,
                    "compact_export_includes_current_aggregate")
        let restored = MileageTracker(directory: directory)
        restored.onUpdate = { estimate = $0; distance = $1 }
        restored.observeBike(id)
        restored.updateCompanion(garage, initialEstimate: nil)
        restored.bluetoothChanged(true)
        let now = Date()
        restored.recordMeasurements([.init(id: "wheel_speed", label: "Скорость", value: 36,
            unit: "км/ч", timestamp: now, source: "simulator audit")])
        restored.bluetoothChanged(false)
        try require(abs(distance - 0.01) < 0.00001 && abs((estimate ?? 0) - 25_000.01) < 0.00001 && restored.error == nil,
                    "compact_restore_does_not_bridge_process_gap")
        restored.setEnabled(false)
        let disabled = MileageTracker(directory: directory)
        try require(!disabled.enabled, "compact_disabled_preference_survives_restart")
        restored.setEnabled(true)
        recorder.setAutoRecord(false)
        let manualOnly = RideRecorder()
        retainedRecorders.append(manualOnly)
        try require(!manualOnly.autoRecord, "detailed_off_survives_fresh_recorder")

        let floorTracker = MileageTracker(directory: directory.appendingPathComponent("conflicting-readings"))
        let floorID = UUID()
        var floorEstimate: Double?
        var floorDistance = 0.0
        floorTracker.onUpdate = { floorEstimate = $0; floorDistance = $1 }
        floorTracker.observeBike(floorID)
        let conflict = CompanionData(odometerKm: 1_000, odometerRecordedAt: Date().addingTimeInterval(-10),
            fuelEntries: [FuelEntry(date: Date().addingTimeInterval(-30), odometerKm: 1_600)])
        floorTracker.updateCompanion(conflict, initialEstimate: 1_000)
        try require(floorEstimate == 1_600 && floorDistance == 0,
                    "compact_stale_profile_cannot_hide_new_confirmed_reading")
        floorTracker.bluetoothChanged(true)
        let floorStart = Date().addingTimeInterval(-1)
        for offset in [0.0, 1.0] {
            floorTracker.recordMeasurements([.init(id: "wheel_speed", label: "Скорость", value: 36,
                unit: "км/ч", timestamp: floorStart.addingTimeInterval(offset), source: "simulator audit")])
        }
        floorTracker.bluetoothChanged(false)
        floorTracker.updateCompanion(conflict, initialEstimate: 1_000)
        try require(abs((floorEstimate ?? 0) - 1_600.01) < 0.00001 && abs(floorDistance - 0.01) < 0.00001,
                    "compact_confirmed_floor_never_counts_phantom_distance_or_reapplies")
        try await waitUntil { !floorTracker.checkpointPendingForAudit }
    }

    private func verifyGPSRecovery() async throws {
        let gpsRecorder = RideRecorder()
        retainedRecorders.append(gpsRecorder)
        gpsRecorder.observeBluetoothPeripheral(UUID())
        gpsRecorder.bluetoothChanged(true)
        gpsRecorder.bluetoothReadyForCapture()
        gpsRecorder.setAutoRecord(true)
        try require(gpsRecorder.active != nil, "gps_recovery_test_has_active_recorder")
        // Inject into the real callback after the real start time, without
        // enabling CoreLocation or using any real coordinates in the fixture.
        try await Task.sleep(nanoseconds: 800_000_000)
        let base = Date().addingTimeInterval(-0.7)
        let samples: [(Double, Double)] = [(10, 3), (10, 3), (64, 180), (63.7, 25), (63, 180), (11, 3), (11, 3)]
        var accepted: [Double] = []
        gpsRecorder.onAcceptedGPSSpeed = { speed, _, _ in accepted.append(speed) }
        let locations = samples.enumerated().map { index, sample in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1 + Double(index) * 0.00001, longitude: 1),
                altitude: 5, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0,
                courseAccuracy: sample.1, speed: sample.0, speedAccuracy: 1,
                timestamp: base.addingTimeInterval(Double(index) * 0.1))
        }
        gpsRecorder.locationManager(CLLocationManager(), didUpdateLocations: locations)
        injectSample(into: gpsRecorder, value: 2_400)
        try require(accepted == [10, 11] && gpsRecorder.active?.maxSpeedMS == 11
            && gpsRecorder.active?.distanceMeters == 0 && gpsRecorder.points.count == 2,
                    "gps_recovery_rejects_island_without_inventing_distance")
        try require(gpsRecorder.active?.telemetryCount == 2 && gpsRecorder.gaps.count == 2,
                    "gps_recovery_keeps_bike_capture_and_marks_route_gaps")
        let finished = await finish(gpsRecorder)
        // The route loader deliberately omits raw observations to bound RAM.
        // Verify the actual journal, not that filtered presentation view.
        let records = try rawRecords(finished)
        try require(records.filter { $0.kind == "gps_observation" }.count == samples.count
            && records.filter { $0.kind == "gps" }.count == 2,
                    "gps_recovery_preserves_all_original_observations")
        gpsRecorder.setAutoRecord(false)
    }

    private func verifyParkingPause() async throws {
        let parked = RideRecorder()
        retainedRecorders.append(parked)
        parked.observeBluetoothPeripheral(UUID())
        parked.bluetoothChanged(true)
        parked.bluetoothReadyForCapture()
        parked.setAutoRecord(true)
        guard let ride = parked.active else { throw AuditFailure(message: "parking fixture did not start") }
        let sampleAt = Date()
        parked.recordStreamFrame(at: sampleAt)
        parked.recordMeasurements([
            .init(id: "wheel_speed", label: "Скорость", value: 0, unit: "км/ч", timestamp: sampleAt, source: "simulator audit")
        ])
        parked.bluetoothChanged(false)
        try require(parked.recordingPaused, "parking_stopped_disconnect_pauses_actual_recorder")
        let before = parked.active
        try await Task.sleep(nanoseconds: 100_000_000)
        let now = Date()
        let idleLocations = [-0.04, -0.02].map { offset in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1),
                altitude: 5, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0,
                courseAccuracy: 3, speed: 0, speedAccuracy: 1, timestamp: now.addingTimeInterval(offset))
        }
        parked.locationManager(CLLocationManager(), didUpdateLocations: idleLocations)
        parked.recordDiagnostic(DiagnosticEvent(kind: "parking_idle_audit", detail: "must not fill the ride"))
        try require(parked.recordingPaused && parked.points.isEmpty
            && parked.active?.telemetryCount == before?.telemetryCount
            && parked.active?.rawEventCount == before?.rawEventCount,
                    "parking_idle_callbacks_do_not_grow_track_or_diagnostics")
        parked.bluetoothChanged(true)
        try require(parked.recordingPaused, "parking_transport_icon_alone_does_not_resume_capture")
        parked.recordStreamFrame(at: Date())
        try require(!parked.recordingPaused && parked.active?.id == ride.id
            && parked.active?.pauseState?.excluded.count == 1,
                    "parking_real_frame_resumes_same_ride")
        let finished = await finish(parked)
        let excluded = finished.pauseState?.excluded.first
        let removed = excluded.map { $0.endedAt.timeIntervalSince($0.startedAt) } ?? 0
        try require(removed > 0 && abs(finished.elapsed
            - ((finished.endedAt ?? .distantPast).timeIntervalSince(finished.startedAt) - removed)) < 0.002,
                    "parking_saved_duration_excludes_short_stop")
        let records = try rawRecords(finished)
        try require(records.filter { $0.kind == "pause" }.count == 1
            && records.filter { $0.kind == "pause_resumed" }.count == 1
            && !records.contains { $0.kind == "gps_observation" || $0.diagnostic?.kind == "parking_idle_audit" },
                    "parking_journal_has_boundaries_without_stationary_spam")
        parked.setAutoRecord(false)

        let timed = RideRecorder()
        retainedRecorders.append(timed)
        timed.observeBluetoothPeripheral(UUID())
        timed.bluetoothChanged(true)
        timed.bluetoothReadyForCapture()
        timed.setAutoRecord(true)
        let timedSample = Date()
        timed.recordStreamFrame(at: timedSample)
        timed.recordMeasurements([
            .init(id: "wheel_speed", label: "Скорость", value: 0, unit: "км/ч",
                  timestamp: timedSample, source: "simulator audit")
        ])
        timed.bluetoothChanged(false)
        guard let timedID = timed.active?.id, let cutoff = timed.active?.pauseState?.pausedAt else {
            throw AuditFailure(message: "timer pause fixture did not pause")
        }
        // The icon/GATT can return without a single useful frame. Finishing
        // this pause must not immediately start another empty ride.
        timed.bluetoothChanged(true)
        timed.bluetoothReadyForCapture()
        timed.evaluateAutomaticPause(at: cutoff.addingTimeInterval(900))
        timed.evaluateAutomaticPause(at: cutoff.addingTimeInterval(901))
        injectSample(into: timed, value: 9_999)
        try await waitUntil { timed.active == nil && !timed.finishingRide }
        guard let timerSaved = timed.history.first(where: { $0.id == timedID }) else {
            throw AuditFailure(message: "timer did not save the parked ride")
        }
        try require(abs((timerSaved.endedAt ?? .distantPast).timeIntervalSince(cutoff)) < 0.002
            && timerSaved.telemetryCount == 1,
                    "parking_live_timeout_uses_stop_boundary_and_rejects_late_packets")
        try require(try rawRecords(timerSaved).filter { $0.kind == "finished" }.count == 1,
                    "parking_repeated_timeout_does_not_duplicate_finish")
        timed.bluetoothReadyForCapture()
        let waiting = RideRecorder()
        retainedRecorders.append(waiting)
        waiting.observeBluetoothPeripheral(UUID())
        waiting.bluetoothChanged(true)
        waiting.bluetoothReadyForCapture()
        try require(timed.active == nil && waiting.active == nil && waiting.autoRecord,
                    "parking_timeout_does_not_create_empty_rides_even_after_relaunch")
        waiting.setAutoRecord(false)
        timed.recordStreamFrame(at: Date())
        try require(timed.active != nil && timed.active?.id != timedID,
                    "parking_next_real_frame_starts_new_automatic_ride")
        _ = await finish(timed)
        timed.setAutoRecord(false)

        let archive = try RideArchive()
        let recoveryStart = Date().addingTimeInterval(-360)
        let recoveryStop = recoveryStart.addingTimeInterval(240)
        var recoveryPause = RidePausePolicy()
        recoveryPause.recordActivity(at: recoveryStop)
        recoveryPause.observeBikeSpeed(0, at: recoveryStop)
        recoveryPause.transportDisconnected(at: recoveryStop)
        var recoverySeed = RideSummary(id: UUID(), startedAt: recoveryStart,
                                       lastSavedAt: recoveryStop, trigger: "manual")
        recoverySeed.pauseState = recoveryPause
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            archive.append([RideRecord(kind: "started", timestamp: recoveryStart),
                            RideRecord(kind: "pause", timestamp: recoveryStop)],
                           summary: recoverySeed, forceCheckpoint: true) { continuation.resume(with: $0) }
        }
        let recovering = RideRecorder()
        retainedRecorders.append(recovering)
        try require(recovering.restoringRoute && recovering.recordingPaused,
                    "parking_short_pause_is_restored_before_route_load")
        let resumedAt = Date()
        recovering.recordStreamFrame(at: resumedAt)
        recovering.recordMeasurements([
            .init(id: "engine_speed", label: "Обороты", value: 1_500, unit: "об/мин",
                  timestamp: resumedAt, source: "simulator audit")
        ])
        try await waitUntil { !recovering.restoringRoute }
        try require(recovering.active?.id == recoverySeed.id && !recovering.recordingPaused
            && recovering.active?.telemetryCount == 1
            && recovering.active?.pauseState?.excluded.count == 1,
                    "parking_live_resume_survives_concurrent_route_recovery")
        let recoveryFinished = await finish(recovering)
        try require(abs(recoveryFinished.recordingSeconds(at: resumedAt) - 240) < 0.002,
                    "parking_recovery_keeps_real_dates_and_compressed_clock")

        // A real manifest/checkpoint from a pause already older than 15 minutes.
        // Startup must close it without another button press or a live GPS fix.
        let start = Date().addingTimeInterval(-4_000)
        let stoppedAt = start.addingTimeInterval(3_000)
        var policy = RidePausePolicy()
        policy.recordActivity(at: stoppedAt)
        policy.observeBikeSpeed(0, at: stoppedAt)
        policy.transportDisconnected(at: stoppedAt)
        var seed = RideSummary(id: UUID(), startedAt: start, lastSavedAt: stoppedAt, trigger: "manual")
        seed.pauseState = policy
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            archive.append([RideRecord(kind: "started", timestamp: start),
                            RideRecord(kind: "pause", timestamp: stoppedAt)],
                           summary: seed, forceCheckpoint: true) { continuation.resume(with: $0) }
        }
        let restored = RideRecorder()
        retainedRecorders.append(restored)
        try require(restored.finishRequested && restored.active?.id == seed.id,
                    "parking_expired_pause_blocks_capture_during_relaunch")
        injectSample(into: restored, value: 9_999)
        try await waitUntil { restored.active == nil && !restored.finishingRide && !restored.restoringRoute }
        guard let saved = restored.history.first(where: { $0.id == seed.id }) else {
            throw AuditFailure(message: "expired parking ride did not finish after recovery")
        }
        try require(abs((saved.endedAt ?? .distantPast).timeIntervalSince(stoppedAt)) < 0.002
            && abs(saved.elapsed - 3_000) < 0.002 && saved.telemetryCount == 0
            && RideFinishIntent.load(UserDefaults.standard) == nil,
                    "parking_relaunch_trims_fifteen_minute_tail_at_original_stop")
        let savedRecords = try rawRecords(saved)
        try require(savedRecords.filter { $0.kind == "finished" }.count == 1
            && !savedRecords.contains { $0.timestamp.timeIntervalSince(stoppedAt) > 0.002 && $0.kind != "summary_checkpoint" },
                    "parking_timeout_is_saved_once_without_waiting_tail")

        // History, graph clock and map-gap derivation must agree on a stop.
        var short = RidePausePolicy()
        short.recordActivity(at: start.addingTimeInterval(2_400))
        short.observeBikeSpeed(0, at: start.addingTimeInterval(2_400))
        short.transportDisconnected(at: start.addingTimeInterval(2_400))
        short.streamReturned(at: start.addingTimeInterval(2_780))
        var chartRide = RideSummary(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(2_840),
                                   lastSavedAt: start.addingTimeInterval(2_840), trigger: "simulator")
        chartRide.pauseState = short
        let boundaryPoints = [2_400.0, 2_780.0].enumerated().map { index, offset in
            TrackPoint(timestamp: start.addingTimeInterval(offset), latitude: 1, longitude: 1,
                       altitude: nil, accuracy: 5, speed: 0, segment: index)
        }
        let boundaryRecords = boundaryPoints.map { RideRecord(kind: "gps", timestamp: $0.timestamp, point: $0) }
        try require(chartRide.elapsed == 2_460 && chartRide.recordingSeconds(at: boundaryPoints[1].timestamp) == 2_400
            && !gpsGaps(in: boundaryRecords, ride: chartRide).contains {
                $0.startedAt == boundaryPoints[0].timestamp && $0.endedAt == boundaryPoints[1].timestamp
            }, "parking_history_graph_and_route_share_compressed_timeline")
        try require(restored.error == nil && parked.error == nil && recovering.error == nil && timed.error == nil
            && waiting.error == nil,
                    "parking_archive_remains_error_free")
    }

    private func rawRecords(_ summary: RideSummary) throws -> [RideRecord] {
        let path = try rideDirectory().appendingPathComponent(summary.id.uuidString + ".jsonl")
        let decoder = RideJournalDates.decoder()
        var records: [RideRecord] = []
        try CaptureJournalExport.forEachLine(in: path) { records.append(try decoder.decode(RideRecord.self, from: $0)) }
        return records
    }

    private func injectSample(into recorder: RideRecorder, value: Double) {
        let now = Date()
        recorder.recordStreamFrame(at: now)
        recorder.recordMeasurements([
            .init(id: "engine_speed", label: "Обороты", value: value, unit: "об/мин", timestamp: now, source: "simulator audit"),
            .init(id: "wheel_speed", label: "Скорость", value: 12, unit: "км/ч", timestamp: now, source: "simulator audit")
        ])
        recorder.recordDiagnostic(DiagnosticEvent(kind: "simulator_audit", detail: "synthetic recorder integration sample",
                                                   data: Data([0x4A, 0x00])))
    }

    private func finish(_ recorder: RideRecorder, afterRequest: (() -> Void)? = nil) async -> RideSummary {
        await withCheckedContinuation { continuation in
            recorder.stop { continuation.resume(returning: $0) }
            recorder.stop() // A second tap must not enqueue another finished line.
            afterRequest?()
        }
    }

    private func load(_ summary: RideSummary, using recorder: RideRecorder) async throws -> [RideRecord] {
        try await withCheckedThrowingContinuation { continuation in
            recorder.load(summary) { continuation.resume(with: $0) }
        }
    }

    private func seedUnfinishedRide() async throws -> RideSummary {
        let start = Date().addingTimeInterval(-10)
        let sample = MotoProtocol.Measurement(id: "engine_speed", label: "Обороты", value: 1_800,
            unit: "об/мин", timestamp: start.addingTimeInterval(1), source: "simulator audit")
        let raw = DiagnosticEvent(kind: "simulator_audit", detail: "unfinished fixture")
        var summary = RideSummary(id: UUID(), startedAt: start, lastSavedAt: start.addingTimeInterval(1), trigger: "bluetooth")
        summary.telemetryCount = 1
        summary.rawEventCount = 1
        let archive = try RideArchive()
        let records = [RideRecord(kind: "started", timestamp: start),
                       RideRecord(kind: "motorcycle", timestamp: sample.timestamp, measurement: sample),
                       RideRecord(kind: "diagnostic", timestamp: sample.timestamp, diagnostic: raw)]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            archive.append(records, summary: summary, forceCheckpoint: true) { continuation.resume(with: $0) }
        }
        return summary
    }

    private func verifySaved(_ summary: RideSummary, expectedMeasurements: Int, minimumRawEvents: Int) throws {
        let directory = try rideDirectory()
        let decoder = RideJournalDates.decoder()
        let manifest = try decoder.decode(RideSummary.self,
            from: Data(contentsOf: directory.appendingPathComponent(summary.id.uuidString + ".json")))
        var records: [RideRecord] = []
        try CaptureJournalExport.forEachLine(in: directory.appendingPathComponent(summary.id.uuidString + ".jsonl")) {
            records.append(try decoder.decode(RideRecord.self, from: $0))
        }
        try require(manifest.id == summary.id && manifest.endedAt != nil
            && records.filter { $0.kind == "started" }.count == 1
            && records.filter { $0.kind == "finished" }.count == 1,
                    "saved_journal_boundaries_\(summary.id.uuidString)")
        let measurements = records.filter { $0.kind == "motorcycle" }.count
        let rawEvents = records.filter { $0.kind == "diagnostic" }.count
        try require(measurements == expectedMeasurements && manifest.telemetryCount == measurements
            && rawEvents >= minimumRawEvents && (manifest.rawEventCount ?? 0) == rawEvents
            && manifest.pointCount == 0,
                    "saved_manifest_matches_actual_records_\(summary.id.uuidString)")
    }

    private func verifyExport(_ summary: RideSummary) async throws {
        let archive = try RideArchive()
        let files: [URL] = try await withCheckedThrowingContinuation { continuation in
            archive.export(summary) { continuation.resume(with: $0) }
        }
        guard let file = files.first else { throw AuditFailure(message: "capture export returned no file") }
        var kinds: [String: Int] = [:]
        var exportedID: String?
        try CaptureJournalExport.forEachLine(in: file) { line in
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
            let kind = object?["kind"] as? String ?? ""
            kinds[kind, default: 0] += 1
            if kind == "capture_manifest" { exportedID = (object?["ride"] as? [String: Any])?["id"] as? String }
        }
        try require(exportedID == summary.id.uuidString && kinds["capture_manifest"] == 1
            && kinds["capture_end"] == 1 && kinds["finished"] == 1
            && kinds["motorcycle"] == summary.telemetryCount,
                    "actual_capture_export_matches_completed_journal")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AuditFailure(message: "Archive did not complete within 5 seconds")
    }

    private func rideDirectory() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MotoLinkRides", isDirectory: true)
    }

    private func writeReport() {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        let evidence: [String: Any] = [
            "schema": "motolink.simulator-ride-lifecycle/1", "launchToken": launchToken,
            "runID": runID.uuidString, "startedAt": startedAt.timeIntervalSince1970,
            "finishedAt": Date().timeIntervalSince1970, "passed": failures.isEmpty,
            "gpsAuthorization": recorder.authorization.rawValue,
            "checks": checks, "failures": failures,
            "scope": "Actual RideRecorder/RideArchive in disposable simulator; fresh-recorder recovery and synthetic BLE callbacks, not OS process-kill or radio validation"
        ]
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("MotoLinkRideLifecycleAudit.json"), options: .atomic)
        } catch { print("Ride lifecycle audit evidence failed: \(error)") }
    }
}
#endif
