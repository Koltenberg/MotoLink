import Combine
import CoreLocation
import Foundation
import MapKit
import UIKit

struct TrackPoint: Codable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let accuracy: Double
    let speed: Double?
    let segment: Int
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var gpsCoordinate: GPSCoordinate { GPSCoordinate(latitude: latitude, longitude: longitude) }
}

/// Defensive segmentation also applies to older saved tracks. Never bridge a
/// time gap or impossible jump merely because an old file shares a segment ID.
func continuousTrackSegments(_ points: [TrackPoint]) -> [[TrackPoint]] {
    var result: [[TrackPoint]] = []
    for point in points {
        if let previous = result.last?.last {
            let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            let decision = GPSContinuity.decision(elapsed: point.timestamp.timeIntervalSince(previous.timestamp),
                                                  distance: distance, interrupted: point.segment != previous.segment)
            if decision == .continuous { result[result.count - 1].append(point) }
            else { result.append([point]) }
        } else { result.append([point]) }
    }
    return result
}

struct RideSummary: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var lastSavedAt: Date
    let trigger: String
    var distanceMeters: Double = 0
    var maxSpeedMS: Double = 0
    var pointCount: Int = 0
    var telemetryCount: Int = 0
    var interruptionCount: Int = 0
    var rawEventCount: Int? = nil
    var elapsed: TimeInterval { max(0, (endedAt ?? Date()).timeIntervalSince(startedAt)) }
}

struct RideRecord: Codable {
    let kind: String
    let timestamp: Date
    var point: TrackPoint? = nil
    var measurement: MotoProtocol.Measurement? = nil
    var detail: String? = nil
    // Optional to keep JSONL written by versions before GPS-gap support readable.
    var gap: GPSGap? = nil
    var diagnostic: DiagnosticEvent? = nil
}

/// Older JSONL has only segment IDs. Derive missing gap descriptions with stable
/// IDs so a user-requested estimate can still be saved and found on the next visit.
func gpsGaps(in records: [RideRecord], ride: RideSummary) -> [GPSGap] {
    var gaps = records.compactMap(\.gap)
    let points = records.compactMap(\.point)
    func add(_ start: Date, _ end: Date, _ from: GPSCoordinate?, _ to: GPSCoordinate?, _ reason: String) {
        guard end > start, !gaps.contains(where: {
            abs($0.startedAt.timeIntervalSince(start)) < 1 && abs($0.endedAt.timeIntervalSince(end)) < 1
        }) else { return }
        let identifier = "legacy-\(ride.id.uuidString)-\(Int64(start.timeIntervalSince1970 * 1000))-\(Int64(end.timeIntervalSince1970 * 1000))"
        gaps.append(GPSGap(id: identifier, startedAt: start, endedAt: end, from: from, to: to, reason: reason))
    }
    if let first = points.first {
        if first.timestamp.timeIntervalSince(ride.startedAt) > GPSContinuity.gapInterval {
            add(ride.startedAt, first.timestamp, nil, first.gpsCoordinate, "Ожидание первой точки GPS")
        }
        for (previous, point) in zip(points, points.dropFirst()) {
            let distance = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            if GPSContinuity.decision(elapsed: point.timestamp.timeIntervalSince(previous.timestamp),
                                     distance: distance, interrupted: previous.segment != point.segment) != .continuous {
                add(previous.timestamp, point.timestamp, previous.gpsCoordinate, point.gpsCoordinate,
                    "Пропуск или разрыв сохранённого маршрута")
            }
        }
        if let last = points.last, let end = ride.endedAt,
           end.timeIntervalSince(last.timestamp) > GPSContinuity.gapInterval {
            add(last.timestamp, end, last.gpsCoordinate, nil, "Поездка завершена без восстановления GPS")
        }
    } else if let end = ride.endedAt {
        add(ride.startedAt, end, nil, nil, "За поездку не получено точных точек GPS")
    }
    return gaps.sorted { $0.startedAt < $1.startedAt }
}

/// Append-only track journal plus a small atomic manifest. Completed tracks are
/// loaded on demand, and routes are never silently uploaded or pruned.
final class RideArchive {
    private let queue = DispatchQueue(label: "app.motolink.rides")
    private let directory: URL
    var onError: ((String) -> Void)?

    init() throws {
        directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            .appendingPathComponent("MotoLinkRides", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: directory.path)
    }

    private func url(_ id: UUID, _ ext: String) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }

    func summaries() throws -> [RideSummary] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(RideSummary.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func records(_ id: UUID) throws -> [RideRecord] {
        var records: [RideRecord] = []
        // Raw diagnostics stay on disk; loading the map must not load hours of packets.
        try CaptureJournalExport.forEachLine(in: url(id, "jsonl")) { line in
            if let record = try? Self.decoder.decode(RideRecord.self, from: line),
               record.kind != "diagnostic", record.kind != "gps_observation" {
                records.append(record)
            }
        }
        return records
    }

    func append(_ records: [RideRecord], summary: RideSummary) {
        queue.async { [self] in
            do {
                let log = url(summary.id, "jsonl")
                if !FileManager.default.fileExists(atPath: log.path) {
                    guard FileManager.default.createFile(atPath: log.path, contents: nil,
                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size > 0 {
                    let reader = try FileHandle(forReadingFrom: log)
                    defer { try? reader.close() }
                    try reader.seek(toOffset: size - 1)
                    if try reader.read(upToCount: 1) != Data([10]) {
                        try handle.write(contentsOf: Data([10]))
                    }
                }
                for record in records {
                    var bytes = try Self.encoder.encode(record)
                    bytes.append(0x0A)
                    try handle.write(contentsOf: bytes)
                }
                try handle.synchronize()
                try Self.encoder.encode(summary).write(to: url(summary.id, "json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { DispatchQueue.main.async { self.onError?(error.localizedDescription) } }
        }
    }

    func load(_ id: UUID, completion: @escaping (Result<[RideRecord], Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try records(id) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func loadEstimates(_ id: UUID, completion: @escaping (Result<[GPSRouteEstimate], Error>) -> Void) {
        queue.async { [self] in
            let result = Result { () throws -> [GPSRouteEstimate] in
                let path = url(id, "route-estimates")
                guard FileManager.default.fileExists(atPath: path.path) else { return [] }
                return try Self.decoder.decode([GPSRouteEstimate].self, from: Data(contentsOf: path))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func saveEstimate(_ estimate: GPSRouteEstimate, rideID: UUID,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { () throws -> Void in
                let path = url(rideID, "route-estimates")
                var estimates: [GPSRouteEstimate] = []
                if FileManager.default.fileExists(atPath: path.path) {
                    estimates = try Self.decoder.decode([GPSRouteEstimate].self, from: Data(contentsOf: path))
                }
                estimates.removeAll { $0.gapID == estimate.gapID }
                estimates.append(estimate)
                try Self.encoder.encode(estimates).write(to: path,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func export(_ summary: RideSummary, completion: @escaping (Result<[URL], Error>) -> Void) {
        queue.async { [self] in
            do {
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MotoLink-capture-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let output = root.appendingPathComponent("MotoLink-\(summary.id.uuidString).jsonl")
                let summaryData = try Self.encoder.encode(summary)
                let header = try JSONSerialization.data(withJSONObject: [
                    "kind": "capture_manifest", "schema": "motolink.capture/1", "appVersion": AppBuild.version, "appBuild": AppBuild.number,
                    "exportedAt": ISO8601DateFormatter().string(from: Date()),
                    "ride": try JSONSerialization.jsonObject(with: summaryData),
                    "rawEventsIncluded": summary.rawEventCount ?? 0,
                    "engineStopDetection": "unavailable; capture requires manual finish"
                ])
                let estimateURL = url(summary.id, "route-estimates")
                let estimates = FileManager.default.fileExists(atPath: estimateURL.path)
                    ? try Data(contentsOf: estimateURL) : Data("[]".utf8)
                let footer = try JSONSerialization.data(withJSONObject: [
                    "kind": "capture_end", "roadEstimatesNotGPS": try JSONSerialization.jsonObject(with: estimates)
                ])
                try CaptureJournalExport.write(to: output, header: header,
                    source: url(summary.id, "jsonl"), footer: footer)
                DispatchQueue.main.async { completion(.success([output])) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func exportGPXDetails(_ summary: RideSummary, completion: @escaping (Result<[URL], Error>) -> Void) {
        queue.async { [self] in
            do {
                let records = try records(summary.id)
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MotoLink-ride-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let json = root.appendingPathComponent("ride.json")
                let raw = root.appendingPathComponent("track-and-telemetry.jsonl")
                let gpx = root.appendingPathComponent("phone-gps.gpx")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(summary).write(to: json)
                try FileManager.default.copyItem(at: url(summary.id, "jsonl"), to: raw)
                let formatter = ISO8601DateFormatter()
                var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"MotoLink\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>MotoLink phone GPS</name>"
                for segment in continuousTrackSegments(records.compactMap(\.point)) {
                    xml += "<trkseg>"
                    for point in segment {
                        xml += "<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
                        if let altitude = point.altitude { xml += "<ele>\(altitude)</ele>" }
                        xml += "<time>\(formatter.string(from: point.timestamp))</time></trkpt>"
                    }
                    xml += "</trkseg>"
                }
                xml += "</trk></gpx>"
                try xml.write(to: gpx, atomically: true, encoding: .utf8)
                var files = [json, raw, gpx]
                let gaps = root.appendingPathComponent("gps-gaps.json")
                try encoder.encode(gpsGaps(in: records, ride: summary)).write(to: gaps)
                files.append(gaps)
                let estimateSource = url(summary.id, "route-estimates")
                if FileManager.default.fileExists(atPath: estimateSource.path) {
                    let estimates = root.appendingPathComponent("road-estimates-NOT-GPS.json")
                    try FileManager.default.copyItem(at: estimateSource, to: estimates)
                    files.append(estimates)
                }
                DispatchQueue.main.async { completion(.success(files)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}

final class RideRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var active: RideSummary?
    @Published private(set) var history: [RideSummary] = []
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var gaps: [GPSGap] = []
    @Published private(set) var speedMS: Double?
    @Published private(set) var lastLocationAt: Date?
    @Published private(set) var status = "Поездка не записывается"
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var autoRecord = UserDefaults.standard.bool(forKey: "MotoLink.autoRecord")
    @Published private(set) var error: String?
    @Published var exportedFiles: SharedFiles?
    @Published private(set) var exporting = false

    private let location = CLLocationManager()
    private var archive: RideArchive?
    private var bluetoothConnected = false
    private var disconnectedAt: Date?
    private var autoStopWork: DispatchWorkItem?
    private var pendingManualStart = false
    private var lastTelemetryTimes: [String: Date] = [:]
    private var previous: CLLocation?
    private var distanceAnchor: CLLocation?
    private var locationRunning = false
    private var segment = 0
    private var autoSuppressedForConnection = false
    private var cancellables = Set<AnyCancellable>()
    private var pendingGPSGapReason: String?

    override init() {
        super.init()
        do {
            archive = try RideArchive()
            archive?.onError = { [weak self] in self?.error = $0 }
            let all = try archive?.summaries() ?? []
            history = all.filter { $0.endedAt != nil }
            if var interrupted = all.first(where: { $0.endedAt == nil }) {
                active = interrupted
                if interrupted.trigger == "bluetooth" { disconnectedAt = interrupted.lastSavedAt }
                do {
                    let records = try archive?.records(interrupted.id) ?? []
                    points = records.compactMap(\.point)
                    gaps = gpsGaps(in: records, ride: interrupted)
                    lastLocationAt = points.last?.timestamp
                }
                catch { self.error = "Не удалось восстановить все точки поездки: \(error.localizedDescription)" }
                segment = points.last?.segment ?? 0
                interrupted.interruptionCount += 1
                interrupted.lastSavedAt = Date()
                active = interrupted
                append([RideRecord(kind: "gap", timestamp: Date(), detail: "Процесс перезапущен; маршрут возобновляется новым сегментом")])
                status = "Незавершённая поездка восстановлена"
                pendingGPSGapReason = "Приложение было перезапущено"
                // Do not silently bridge a killed app's GPS gap or auto-start GPS from a cold launch.
            }
        } catch { self.error = error.localizedDescription }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 10
        location.activityType = .automotiveNavigation
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        authorization = location.authorizationStatus
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.resumeOnForeground() }.store(in: &cancellables)
        for (notification, label) in [
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory_warning"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "protected_data_unavailable")
        ] {
            NotificationCenter.default.publisher(for: notification)
                .sink { [weak self] _ in self?.recordLifecycle(label) }.store(in: &cancellables)
        }
    }

    func setAutoRecord(_ enabled: Bool) {
        autoRecord = enabled
        UserDefaults.standard.set(enabled, forKey: "MotoLink.autoRecord")
        if enabled {
            if authorization == .notDetermined { location.requestWhenInUseAuthorization() }
            else if authorization == .authorizedWhenInUse { location.requestAlwaysAuthorization() }
            evaluateAutoStart()
        }
    }

    func requestBackgroundPermission() {
        if authorization == .notDetermined { location.requestWhenInUseAuthorization() }
        else { location.requestAlwaysAuthorization() }
    }

    func start() {
        guard active == nil else { resume(); return }
        if authorization == .notDetermined {
            pendingManualStart = true
            location.requestWhenInUseAuthorization()
        } else if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            begin(trigger: "manual")
        } else { status = "Разреши геопозицию в Настройках → MotoLink" }
    }

    func resume() {
        guard active != nil, !locationRunning else { return }
        guard authorization == .authorizedAlways ||
                (authorization == .authorizedWhenInUse && UIApplication.shared.applicationState == .active) else {
            status = "Для продолжения открой приложение и разреши геопозицию"; return
        }
        markGPSGap("Запись геопозиции возобновлена")
        previous = nil
        distanceAnchor = nil
        segment += 1
        locationRunning = true
        location.startUpdatingLocation()
        status = "Запись маршрута · GPS iPhone"
    }

    func stop() {
        guard var summary = active else { return }
        location.stopUpdatingLocation()
        locationRunning = false
        autoStopWork?.cancel(); autoStopWork = nil
        summary.endedAt = Date(); summary.lastSavedAt = Date()
        var ending = [RideRecord(kind: "finished", timestamp: Date())]
        if let last = points.last,
           pendingGPSGapReason != nil || Date().timeIntervalSince(last.timestamp) > GPSContinuity.gapInterval {
            let gap = GPSGap(id: UUID().uuidString, startedAt: last.timestamp, endedAt: Date(), from: last.gpsCoordinate,
                to: nil, reason: pendingGPSGapReason ?? "Поездка завершена без новых точек GPS")
            gaps.append(gap)
            ending.append(RideRecord(kind: "gps_gap", timestamp: gap.endedAt, gap: gap))
        } else if points.isEmpty {
            let gap = GPSGap(id: UUID().uuidString, startedAt: summary.startedAt, endedAt: Date(),
                            from: nil, to: nil, reason: "За поездку не получено ни одной точной точки GPS")
            gaps.append(gap)
            ending.append(RideRecord(kind: "gps_gap", timestamp: gap.endedAt, gap: gap))
        }
        archive?.append(ending, summary: summary)
        history.insert(summary, at: 0)
        active = nil
        previous = nil
        distanceAnchor = nil
        speedMS = nil
        pendingGPSGapReason = nil
        autoSuppressedForConnection = bluetoothConnected
        status = "Поездка сохранена на iPhone"
    }

    func bluetoothChanged(_ connected: Bool) {
        let changed = bluetoothConnected != connected
        bluetoothConnected = connected
        if connected {
            autoStopWork?.cancel(); autoStopWork = nil
            disconnectedAt = nil
            evaluateAutoStart()
            if active != nil { resume() }
        } else if changed {
            disconnectedAt = Date()
            autoSuppressedForConnection = false
            autoStopWork?.cancel()
            let item = DispatchWorkItem { [weak self] in _ = self?.finishAfterDisconnect() }
            autoStopWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: item)
        }
        if changed, active != nil {
            append([RideRecord(kind: "bluetooth", timestamp: Date(), detail: connected ? "connected" : "disconnected")])
        }
    }

    func recordMeasurements(_ measurements: [MotoProtocol.Measurement]) {
        guard active != nil, !measurements.isEmpty else { return }
        let sampled = measurements.filter { sample in
            guard sample.timestamp.timeIntervalSince(lastTelemetryTimes[sample.id] ?? .distantPast) >= 1 else { return false }
            lastTelemetryTimes[sample.id] = sample.timestamp
            return true
        }
        guard !sampled.isEmpty else { return }
        active?.telemetryCount += sampled.count
        append(sampled.map { RideRecord(kind: "motorcycle", timestamp: $0.timestamp, measurement: $0) })
    }

    /// Raw packets are never sampled or pruned from a ride, including malformed
    /// notifications which may become interpretable after the first road test.
    func recordDiagnostic(_ event: DiagnosticEvent) {
        guard active != nil else { return }
        active?.rawEventCount = (active?.rawEventCount ?? 0) + 1
        append([RideRecord(kind: "diagnostic", timestamp: Date(), diagnostic: event)])
    }

    func recordLifecycle(_ detail: String) {
        guard active != nil else { return }
        append([RideRecord(kind: "lifecycle", timestamp: Date(), detail: detail)])
    }

    /// Start the capture even without GPS permission: BLE evidence must survive
    /// a denied permission, unavailable satellites, or a long GPS outage.
    func startCapture() {
        guard active == nil else { resume(); return }
        begin(trigger: "capture")
        if authorization == .notDetermined { location.requestWhenInUseAuthorization() }
    }

    func finishAndExport() {
        guard active != nil else { return }
        stop()
        if let summary = history.first { export(summary) }
    }

    func load(_ summary: RideSummary, completion: @escaping (Result<[RideRecord], Error>) -> Void) {
        guard let archive else { completion(.failure(CocoaError(.fileReadUnknown))); return }
        archive.load(summary.id, completion: completion)
    }

    func loadEstimates(_ summary: RideSummary, completion: @escaping (Result<[GPSRouteEstimate], Error>) -> Void) {
        guard let archive else { completion(.failure(CocoaError(.fileReadUnknown))); return }
        archive.loadEstimates(summary.id, completion: completion)
    }

    func saveEstimate(_ estimate: GPSRouteEstimate, for summary: RideSummary,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        guard let archive else { completion(.failure(CocoaError(.fileWriteUnknown))); return }
        archive.saveEstimate(estimate, rideID: summary.id, completion: completion)
    }

    func export(_ summary: RideSummary) {
        guard !exporting, let archive else { return }
        exporting = true
        archive.export(summary) { [weak self] result in
            self?.exporting = false
            switch result {
            case .success(let urls): self?.exportedFiles = SharedFiles(urls: urls)
            case .failure(let error): self?.error = error.localizedDescription
            }
        }
    }

    func exportGPX(_ summary: RideSummary) {
        guard !exporting, let archive else { return }
        exporting = true
        archive.exportGPXDetails(summary) { [weak self] result in
            self?.exporting = false
            switch result {
            case .success(let urls): self?.exportedFiles = SharedFiles(urls: urls)
            case .failure(let error): self?.error = error.localizedDescription
            }
        }
    }

    private func begin(trigger: String) {
        guard archive != nil else { status = "Хранилище недоступно — запись не начата"; return }
        points = []; gaps = []; pendingGPSGapReason = nil
        segment = 0; previous = nil; distanceAnchor = nil; speedMS = nil; lastLocationAt = nil; lastTelemetryTimes = [:]
        active = RideSummary(id: UUID(), startedAt: Date(), lastSavedAt: Date(), trigger: trigger)
        append([RideRecord(kind: "started", timestamp: Date(), detail: "GPS и скорость: iPhone. BLE-подключение не доказывает работу двигателя.")])
        recordLifecycle("iOS \(UIDevice.current.systemVersion); locationPermission=\(authorization.rawValue); lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse {
            locationRunning = true
            location.startUpdatingLocation()
        }
        status = "Сеанс записывается на iPhone · GPS и доступные данные Bluetooth"
    }

    private func evaluateAutoStart() {
        guard autoRecord, bluetoothConnected, active == nil, !autoSuppressedForConnection else { return }
        guard authorization == .authorizedAlways else {
            status = "Для автозаписи выбери геопозицию «Всегда». Ручная запись доступна отдельно."; return
        }
        begin(trigger: "bluetooth")
    }

    private func resumeOnForeground() {
        authorization = location.authorizationStatus
        if finishAfterDisconnect() { return }
        if active != nil { resume() } else { evaluateAutoStart() }
    }

    @discardableResult private func finishAfterDisconnect() -> Bool {
        guard active?.trigger == "bluetooth", !bluetoothConnected,
              let disconnectedAt, Date().timeIntervalSince(disconnectedAt) >= 120 else { return false }
        stop()
        status = "Автопоездка завершена: связь отсутствовала 2 минуты"
        return true
    }

    private func append(_ records: [RideRecord]) {
        guard var summary = active else { return }
        summary.lastSavedAt = Date(); active = summary
        archive?.append(records, summary: summary)
    }

    func gpsStatus(at date: Date) -> String? {
        guard active != nil else { return nil }
        guard let lastLocationAt else { return "Нет GPS: ожидаем первую точную точку. Поездка продолжается." }
        guard pendingGPSGapReason != nil || date.timeIntervalSince(lastLocationAt) > GPSContinuity.staleInterval else { return nil }
        return "Нет свежих данных GPS. Последняя точка: \(lastLocationAt.formatted(date: .omitted, time: .standard)). Поездка и запись доступной телеметрии продолжаются."
    }

    private func markGPSGap(_ reason: String) {
        speedMS = nil
        distanceAnchor = nil
        guard active != nil, pendingGPSGapReason == nil else { return }
        pendingGPSGapReason = reason
        append([RideRecord(kind: "gps_gap_started", timestamp: Date(), detail: reason)])
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            if pendingManualStart { pendingManualStart = false; begin(trigger: "manual") }
            if active != nil { resume() }
            evaluateAutoStart()
        } else if authorization == .denied || authorization == .restricted {
            pendingManualStart = false
            location.stopUpdatingLocation()
            locationRunning = false
            speedMS = nil
            previous = nil
            distanceAnchor = nil
            markGPSGap("Нет разрешения на геопозицию")
            status = "Нет доступа к геопозиции; точки маршрута не записываются"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let startedAt = active?.startedAt, !finishAfterDisconnect() else { return }
        var records: [RideRecord] = []
        for fix in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            records.append(RideRecord(kind: "gps_observation", timestamp: fix.timestamp,
                detail: "lat=\(fix.coordinate.latitude); lon=\(fix.coordinate.longitude); horizontalAccuracy=\(fix.horizontalAccuracy); altitude=\(fix.altitude); verticalAccuracy=\(fix.verticalAccuracy); speed=\(fix.speed); speedAccuracy=\(fix.speedAccuracy); course=\(fix.course); courseAccuracy=\(fix.courseAccuracy)"))
            guard GPSContinuity.acceptsTimestamp(fix.timestamp, startedAt: startedAt,
                previous: points.last?.timestamp, now: Date()) else { continue }
            guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 50,
                  CLLocationCoordinate2DIsValid(fix.coordinate) else {
                markGPSGap("Нет точной геопозиции; ненадёжная точка отклонена")
                continue
            }
            var speed: Double? = fix.speed >= 0 && fix.speed <= 100 ? fix.speed : nil
            if fix.speedAccuracy > 8 { speed = nil }
            if let last = points.last {
                let elapsed = fix.timestamp.timeIntervalSince(last.timestamp)
                let distance = fix.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
                let decision = GPSContinuity.decision(elapsed: elapsed, distance: distance,
                                                       interrupted: pendingGPSGapReason != nil)
                if decision == .reject {
                    markGPSGap("Резкий скачок координат отклонён")
                    continue
                }
                if decision == .newSegment {
                    let gap = GPSGap(id: UUID().uuidString, startedAt: last.timestamp, endedAt: fix.timestamp,
                        from: last.gpsCoordinate,
                        to: GPSCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                        reason: pendingGPSGapReason ?? "Нет принятых точек GPS более минуты")
                    gaps.append(gap)
                    records.append(RideRecord(kind: "gps_gap", timestamp: fix.timestamp, gap: gap))
                    segment += 1
                    distanceAnchor = nil
                }
            } else if let active, pendingGPSGapReason != nil
                        || fix.timestamp.timeIntervalSince(active.startedAt) > GPSContinuity.gapInterval {
                let gap = GPSGap(id: UUID().uuidString, startedAt: active.startedAt, endedAt: fix.timestamp,
                    from: nil, to: GPSCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                    reason: "Ожидание первой точной точки GPS")
                gaps.append(gap)
                records.append(RideRecord(kind: "gps_gap", timestamp: fix.timestamp, gap: gap))
            }
            pendingGPSGapReason = nil
            // Advance the distance anchor only after accepting distance. Updating
            // it for every 10 m fix with 20 m accuracy would lose nearly all travel.
            if let anchor = distanceAnchor {
                let distance = fix.distance(from: anchor)
                let seconds = max(1, fix.timestamp.timeIntervalSince(anchor.timestamp))
                let moving = (speed ?? distance / seconds) >= 1.5
                if moving, distance >= max(5, min(fix.horizontalAccuracy, anchor.horizontalAccuracy)) {
                    active?.distanceMeters += distance
                    distanceAnchor = fix
                }
            } else { distanceAnchor = fix }
            let point = TrackPoint(timestamp: fix.timestamp, latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude, altitude: fix.verticalAccuracy >= 0 ? fix.altitude : nil,
                accuracy: fix.horizontalAccuracy, speed: speed, segment: segment)
            points.append(point)
            active?.pointCount += 1
            if let speed {
                let maximum = max(active?.maxSpeedMS ?? 0, speed)
                active?.maxSpeedMS = maximum
            }
            records.append(RideRecord(kind: "gps", timestamp: fix.timestamp, point: point))
            previous = fix; speedMS = speed; lastLocationAt = fix.timestamp
            status = "Запись маршрута · GPS iPhone"
        }
        if !records.isEmpty { append(records) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        markGPSGap("GPS временно недоступен: \(error.localizedDescription)")
        if let error = error as? CLError, error.code == .locationUnknown {
            status = "Ожидаем точный GPS; поездка продолжает записываться"
        } else { status = "GPS: \(error.localizedDescription)" }
    }
}

/// User-initiated, single request at a time. No automatic network transmission
/// on GPS recovery, and no timer-driven retries when Apple Maps is unavailable.
final class RoadEstimateController: ObservableObject {
    @Published private(set) var estimates: [GPSRouteEstimate] = []
    @Published private(set) var busyGap: String?
    @Published private(set) var message: String?
    private var directions: MKDirections?
    private var timeout: DispatchWorkItem?
    private var generation = UUID()

    func load(_ ride: RideSummary, using recorder: RideRecorder) {
        let expected = generation
        recorder.loadEstimates(ride) { [weak self] result in
            guard let self, self.generation == expected else { return }
            switch result {
            case .success(let saved): self.estimates = saved
            case .failure(let error): self.message = "Не удалось прочитать сохранённые варианты: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        directions?.cancel()
        directions = nil
        busyGap = nil
    }

    func calculate(_ gap: GPSGap, ride: RideSummary, using recorder: RideRecorder) {
        guard busyGap == nil, let start = gap.from, let end = gap.to else { return }
        let source = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
        let destination = CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude)
        guard CLLocationCoordinate2DIsValid(source), CLLocationCoordinate2DIsValid(destination) else {
            message = "Координаты границ пропуска некорректны. Вариант не построен."; return
        }
        guard CLLocation(latitude: source.latitude, longitude: source.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)) >= 100 else {
            message = "Границы пропуска находятся рядом. За это время могла быть остановка или целая поездка по кругу; восстановить её по двум точкам нельзя."
            return
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        let operation = MKDirections(request: request)
        generation = UUID()
        let expected = generation
        busyGap = gap.id
        message = "Запрашиваем возможный дорожный маршрут у Apple Maps…"
        directions = operation
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected else { return }
            self.cancel()
            self.message = "Apple Maps не ответил за 45 секунд. Запрос остановлен; повторите вручную позже."
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: deadline)
        operation.calculate { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == expected else { return }
                self.timeout?.cancel()
                self.timeout = nil
                self.directions = nil
                guard let route = response?.routes.first(where: {
                    $0.polyline.pointCount > 1 && $0.distance.isFinite && $0.distance > 0
                        && $0.distance / max(1, gap.duration) <= 100
                }) else {
                    self.busyGap = nil
                    self.message = "Дорожный вариант не получен. Нужен интернет и доступный маршрут Apple Maps. Повторите вручную позже. \(error?.localizedDescription ?? "Подходящего маршрута нет.")"
                    return
                }
                var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                                          count: route.polyline.pointCount)
                route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: coordinates.count))
                guard coordinates.allSatisfy(CLLocationCoordinate2DIsValid) else {
                    self.busyGap = nil; self.message = "Apple Maps вернул некорректные координаты."; return
                }
                let estimate = GPSRouteEstimate(gapID: gap.id, calculatedAt: Date(),
                    coordinates: coordinates.map { GPSCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
                    distanceMeters: route.distance, expectedTravelTime: route.expectedTravelTime,
                    source: "Apple Maps · автомобильный маршрут · предположение, не запись GPS")
                recorder.saveEstimate(estimate, for: ride) { [weak self] result in
                    guard let self, self.generation == expected else { return }
                    self.busyGap = nil
                    switch result {
                    case .success:
                        self.estimates.removeAll { $0.gapID == gap.id }
                        self.estimates.append(estimate)
                        self.message = "Дорожный вариант сохранён для просмотра без сети. Фактический путь во время пропуска неизвестен."
                    case .failure(let error):
                        self.message = "Не удалось сохранить вариант: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
