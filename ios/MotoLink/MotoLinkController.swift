import Combine
import UIKit

/// Created by AppDelegate on every launch, including CoreBluetooth restoration.
/// It does not depend on a visible SwiftUI scene to establish delegate callbacks.
final class MotoLinkController: ObservableObject {
    static let shared = MotoLinkController()
    let rides = RideRecorder()
    let bluetooth = MotorcycleBluetooth()
    let companion = CompanionStore()
    let mileage = MileageTracker()
    private lazy var connectionContext = ConnectionContextMonitor { [weak self] in self?.rides.recordConnectionContext($0) }
    private lazy var networkContext = NetworkPathContextMonitor { [weak self] in self?.rides.recordConnectionContext($0) }
    private var lastMonitoredRideID: UUID?
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        mileage.onUpdate = { [weak self] estimate, distance in
            self?.companion.updateTrackedOdometer(estimate)
            self?.companion.updateTrackedDistance(distance)
        }
        companion.$data.sink { [weak self] data in
            guard let self else { return }
            let summaries = self.rides.history + (self.rides.active.map { [$0] } ?? [])
            let trips = summaries.map { RecordedTripDistance(id: $0.id, startedAt: $0.startedAt,
                endedAt: $0.endedAt, distanceMeters: $0.distanceMeters) }
            // $data publishes before CompanionStore.data is assigned. Defer
            // the derived value so the view/store cannot evaluate old anchors.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.companion.isReadable, self.companion.data == data else { return }
                self.mileage.updateCompanion(data,
                    initialEstimate: data.estimatedOdometer(from: trips)?.kilometers)
            }
        }.store(in: &subscriptions)
        bluetooth.onMeasurements = { [weak self] values in
            self?.mileage.recordMeasurements(values)
            self?.rides.recordMeasurements(values)
        }
        rides.onAcceptedGPSSpeed = { [weak self] speed, date, receivedAt in
            self?.mileage.recordGPSSpeed(speed, at: date, receivedAt: receivedAt)
        }
        bluetooth.onStreamFrame = { [weak self] in self?.rides.recordStreamFrame(at: $0) }
        bluetooth.onDiagnosticEvent = { [weak self] in self?.rides.recordDiagnostic($0) }
        bluetooth.onTransportIdentity = { [weak self] id in
            self?.mileage.observeBike(id)
            self?.rides.observeBluetoothPeripheral(id)
        }
        bluetooth.onConfirmedTransportBoundary = { [weak self] in self?.rides.confirmedBluetoothBoundary($0) }
        rides.onNewRideStarted = { [weak self] id in
            guard let self, self.rides.active?.id == id, !self.rides.finishRequested else { return }
            self.rides.recordDiagnosticPrelude(self.bluetooth.capturePrelude)
            self.rides.recordConnectionContext(ConnectionTestSettingsView.capture())
            self.bluetooth.startCaptureProfileIfNeeded()
        }
        bluetooth.onReadyForCapture = { [weak self] in
            guard let self else { return }
            self.rides.bluetoothReadyForCapture()
            if self.rides.active != nil, !self.rides.finishRequested {
                self.bluetooth.startCaptureProfileIfNeeded()
            }
        }
        bluetooth.$connected.removeDuplicates().sink { [weak self] connected in
            self?.mileage.bluetoothChanged(connected)
            self?.rides.bluetoothChanged(connected)
            self?.connectionContext.snapshot(reason: connected ? "bike_connected" : "bike_disconnected")
            if !connected { self?.rides.recordGPSCallbackSummary(reason: "bike_disconnected") }
        }.store(in: &subscriptions)
        rides.$activeRideID.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] id in
            guard let self, self.rides.active?.id == id else { return }
            // Restored rides resume passive observation without consuming next-ride inputs.
            // Finishing can synchronously auto-start a new ride before the
            // queued nil ID arrives. Reset by identity, even when both rides
            // are active at their respective callbacks, so caps and initial
            // snapshots always belong to the current ride.
            guard self.lastMonitoredRideID != id else { return }
            self.connectionContext.setRecording(false)
            self.networkContext.setRecording(false)
            self.lastMonitoredRideID = id
            self.connectionContext.setRecording(id != nil)
            self.networkContext.setRecording(id != nil)
        }.store(in: &subscriptions)
        rides.$activeRideID.combineLatest(rides.$finishRequested, rides.$restoringRoute)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                let selected = self.rides.active != nil && !self.rides.finishRequested
                self.mileage.detailedRecordingChanged(selected,
                    suppliesGPS: selected && !self.rides.restoringRoute)
            }.store(in: &subscriptions)
        Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            let recording = self.rides.active != nil
            guard recording || self.bluetooth.connected || self.bluetooth.connecting || self.bluetooth.ready else { return }
            // BLE observation and the single known stream rearm also work when
            // the rider views live telemetry without saving a ride. Extra RSSI
            // reads and phone/slow-value sampling remain tied to recording.
            self.bluetooth.recordHealthSnapshot(allowRSSI: recording)
            guard recording else { return }
            self.rides.recordPhoneHealth()
            self.bluetooth.refreshSlowMeasurements()
        }.store(in: &subscriptions)
    }
}

final class MotoLinkAppDelegate: NSObject, UIApplicationDelegate {
    let controller = MotoLinkController.shared
    func application(_ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Eager singleton instantiation above is intentional for BLE restoration.
        true
    }
}
