import Foundation
import Combine
import CoreLocation
import UIKit

/// Compact accounting is independent of RideRecorder and cannot create a
/// journey or raw packet journal. The ledger never stores coordinates.
final class MileageTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var enabled: Bool
    @Published private(set) var error: String?
    var onUpdate: ((Double?, Double) -> Void)?
    private static let enabledKey = "MotoLink.compactMileageEnabled"
    private struct Saved: Codable {
        var ledger = MileageLedger()
        var readingKeys: [String: String] = [:]
        var readingDates: [String: Date] = [:]
        var garageBikeID: UUID?
    }
    private var saved = Saved()
    private var bikeID: UUID?
    private var connected = false
    private var detailed = false
    private var recorderSuppliesGPS = false
    private var tracking = false
    private var locationRunning = false
    private let location = CLLocationManager()
    private var companion = CompanionData()
    private var companionLoaded = false
    private var initialOdometer: Double?
    private var subscriptions = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "app.motolink.compact-mileage", qos: .utility)
    private var file: URL?
    private var readable = false
    private var dirty = false
    private var saving = false
    private var forcedCheckpointPending = false
    private var revision: UInt64 = 0
    private var lastCheckpoint = -Double.infinity
    private var lastPublication = -Double.infinity

    init(directory overrideDirectory: URL? = nil) {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        bikeID = defaults.string(forKey: "MotoLink.peripheralIdentifier").flatMap(UUID.init(uuidString:))
        super.init()
        do {
            let directory = try overrideDirectory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("MotoLink-mileage.json")
            file = destination
            if FileManager.default.fileExists(atPath: destination.path) {
                saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: destination))
                try saved.ledger.validate()
            }
            readable = true
        } catch { self.error = "Не удалось открыть счётчик пробега. Исходный файл сохранён." }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        location.distanceFilter = 10
        location.activityType = .automotiveNavigation
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                self?.checkpoint(force: true)
            }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            self?.updateLocationUse()
            self?.publish(force: true)
        }.store(in: &subscriptions)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        updateTracking()
    }

    func observeBike(_ id: UUID) {
        guard bikeID != id else { return }
        if let old = bikeID, tracking { saved.ledger.endTracking(bikeID: old) }
        tracking = false
        checkpoint(force: true)
        bikeID = id
        syncAnchor()
        updateTracking()
        publish(force: true)
    }

    func bluetoothChanged(_ value: Bool) {
        if connected && !value, let bikeID, tracking {
            saved.ledger.endTracking(bikeID: bikeID)
            tracking = false
        }
        connected = value
        updateTracking()
    }

    func detailedRecordingChanged(_ value: Bool, suppliesGPS: Bool = true) {
        detailed = value
        recorderSuppliesGPS = value && suppliesGPS
        updateTracking()
    }

    func updateCompanion(_ data: CompanionData, initialEstimate: Double?) {
        companion = data
        companionLoaded = true
        initialOdometer = initialEstimate
        syncAnchor()
        publish(force: true)
    }

    private func syncAnchor() {
        guard readable, companionLoaded, let bikeID else { return }
        // One garage currently has one bike. Do not apply its manual odometer
        // to a newly selected friend's motorcycle; those totals stay separate.
        if saved.garageBikeID == nil { saved.garageBikeID = bikeID; changed() }
        guard saved.garageBikeID == bikeID else { return }
        struct Reading { let value: Double; let date: Date; let key: String }
        var candidates: [Reading] = []
        if let value = companion.odometerKm, let date = companion.odometerRecordedAt, date <= Date() {
            candidates.append(Reading(value: value, date: date, key: "profile:\(date.timeIntervalSince1970):\(value)"))
        }
        candidates += companion.fuelEntries.filter { $0.hasInstrumentOdometer && $0.date <= Date() }.map {
            Reading(value: $0.odometerKm, date: $0.date, key: "fuel:\($0.id):\($0.date.timeIntervalSince1970):\($0.odometerKm)")
        }
        candidates += companion.serviceTasks.compactMap { task in
            guard let date = task.lastDoneAt, date <= Date() else { return nil }
            return Reading(value: task.lastDoneOdometerKm, date: date,
                           key: "service:\(task.id):\(date.timeIntervalSince1970):\(task.lastDoneOdometerKm)")
        }
        let latest = candidates.max { $0.date == $1.date ? $0.value < $1.value : $0.date < $1.date }
        let key = latest?.key ?? companion.currentOdometerKm.map { "undated:\($0)" } ?? "none"
        let id = bikeID.uuidString
        guard saved.readingKeys[id] != key else { return }
        let first = saved.readingKeys[id] == nil
        let value = first ? (initialOdometer ?? latest?.value ?? companion.currentOdometerKm)
                          : (latest?.value ?? companion.currentOdometerKm)
        let observedAt = latest?.date ?? Date.distantPast
        if first || value == nil || observedAt >= (saved.readingDates[id] ?? .distantPast) {
          if let value {
            // A newly entered dated reading is an observation of the instrument
            // at that time. Old retrospective entries must not erase mileage
            // accumulated after a newer anchor.
            do { try saved.ledger.setOdometer(kilometers: value, bikeID: bikeID, at: Date()) }
            catch { self.error = "Не удалось применить показание одометра."; return }
          } else { saved.ledger.clearOdometer(bikeID: bikeID) }
          saved.readingDates[id] = Date()
        }
        saved.readingKeys[id] = key
        changed()
        checkpoint(force: true)
    }

    private func updateTracking() {
        let shouldTrack = readable && enabled && (connected || detailed) && bikeID != nil
        if shouldTrack != tracking, let bikeID {
            if shouldTrack { saved.ledger.beginTracking(bikeID: bikeID) }
            else { saved.ledger.endTracking(bikeID: bikeID) }
            tracking = shouldTrack
        }
        updateLocationUse()
        if !tracking { checkpoint(force: true) }
        publish(force: true)
    }

    private func updateLocationUse() {
        let allowed = location.authorizationStatus == .authorizedAlways ||
            (location.authorizationStatus == .authorizedWhenInUse && UIApplication.shared.applicationState == .active)
        let needed = tracking && !recorderSuppliesGPS && allowed
        guard needed != locationRunning else { return }
        locationRunning = needed
        if needed { location.startUpdatingLocation() } else { location.stopUpdatingLocation() }
    }

    func recordMeasurements(_ values: [MotoProtocol.Measurement]) {
        for value in values where value.id == "wheel_speed" && value.unit == "км/ч" {
            record(speed: value.value / 3.6, source: .motorcycle, at: value.timestamp, receivedAt: Date())
        }
    }

    func recordGPSSpeed(_ speed: Double, at date: Date, receivedAt: Date) {
        record(speed: speed < 1.5 ? 0 : speed, source: .gps, at: date, receivedAt: receivedAt)
    }

    private func record(speed: Double, source: MileageLedger.SpeedSource, at date: Date, receivedAt: Date) {
        guard tracking, let bikeID else { return }
        let added = saved.ledger.recordSpeed(bikeID: bikeID, source: source,
            metersPerSecond: speed, timestamp: date, receivedAt: receivedAt)
        if added > 0 { changed(); checkpoint(force: false) }
        publish(force: false)
    }

    private func changed() { revision &+= 1; dirty = true }

    private func publish(force: Bool) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard force || uptime - lastPublication >= 5 else { return }
        lastPublication = uptime
        guard let bikeID else { onUpdate?(nil, 0); return }
        let estimate = saved.garageBikeID == bikeID ? saved.ledger.estimatedOdometerKilometers(bikeID: bikeID) : nil
        onUpdate?(estimate, saved.ledger.totalMeters(bikeID: bikeID) / 1000)
    }

    /// One coalesced atomic file; never queue one disk operation per BLE frame.
    private func checkpoint(force: Bool) {
        let uptime = ProcessInfo.processInfo.systemUptime
        forcedCheckpointPending = forcedCheckpointPending || force
        guard readable, dirty, !saving, let file,
              forcedCheckpointPending || uptime - lastCheckpoint >= 10 else { return }
        forcedCheckpointPending = false
        lastCheckpoint = uptime
        saving = true
        let snapshot = saved
        let savedRevision = revision
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Save mileage", expirationHandler: nil)
        queue.async { [weak self] in
            let result: Result<Void, Error> = Result {
                try snapshot.ledger.validate()
                try JSONEncoder().encode(snapshot).write(to: file,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            DispatchQueue.main.async {
                defer { if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) } }
                guard let self else { return }
                self.saving = false
                switch result {
                case .success:
                    self.dirty = self.revision != savedRevision
                    self.error = nil
                    if self.dirty { self.checkpoint(force: !self.tracking || self.forcedCheckpointPending) }
                case .failure:
                    self.dirty = true
                    self.error = "Пробег ещё не сохранён. Проверь свободное место на iPhone."
                }
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateLocationUse() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locationRunning else { return }
        let receivedAt = Date()
        for fix in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let speed = GPSSpeedQuality.accepted(speed: fix.speed, speedAccuracy: fix.speedAccuracy,
                horizontalAccuracy: fix.horizontalAccuracy, courseAccuracy: fix.courseAccuracy) else { continue }
            recordGPSSpeed(speed, at: fix.timestamp, receivedAt: receivedAt)
        }
    }

    #if targetEnvironment(simulator)
    var checkpointPendingForAudit: Bool { dirty || saving }
    #endif
}
