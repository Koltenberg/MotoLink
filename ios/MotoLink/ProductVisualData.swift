#if targetEnvironment(simulator)
import Foundation
import UIKit
import SwiftUI

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
        } catch {
            let message = (error as? AuditFailure)?.message ?? error.localizedDescription
            if !failures.contains(message) { failures.append(message) }
        }
        writeReport()
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
