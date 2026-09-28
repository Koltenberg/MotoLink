import Combine
import UIKit

/// Created by AppDelegate on every launch, including CoreBluetooth restoration.
/// It does not depend on a visible SwiftUI scene to establish delegate callbacks.
final class MotoLinkController: ObservableObject {
    static let shared = MotoLinkController()
    let rides = RideRecorder()
    let bluetooth = MotorcycleBluetooth()
    private lazy var connectionContext = ConnectionContextMonitor { [weak self] in self?.rides.recordConnectionContext($0) }
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        // First pairing presents an enabled, visible recording switch; later
        // launches preserve the user's choice instead of overriding it.
        bluetooth.onMeasurements = { [weak self] in self?.rides.recordMeasurements($0) }
        bluetooth.onStreamFrame = { [weak self] in self?.rides.recordStreamFrame(at: $0) }
        bluetooth.onDiagnosticEvent = { [weak self] in self?.rides.recordDiagnostic($0) }
        bluetooth.onTransportIdentity = { [weak self] in self?.rides.observeBluetoothPeripheral($0) }
        bluetooth.onConfirmedTransportBoundary = { [weak self] in self?.rides.confirmedBluetoothBoundary($0) }
        rides.onNewRideStarted = { [weak self] id in
            guard let self, self.rides.active?.id == id, !self.rides.finishRequested else { return }
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
            self?.rides.bluetoothChanged(connected)
            self?.connectionContext.snapshot(reason: connected ? "bike_connected" : "bike_disconnected")
        }.store(in: &subscriptions)
        rides.$active.map { $0?.id }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] id in
            guard let self, self.rides.active?.id == id else { return }
            // Restored rides resume passive observation without consuming next-ride inputs.
            self.connectionContext.setRecording(id != nil)
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
