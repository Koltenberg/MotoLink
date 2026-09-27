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
        // One explicit full-capture flow; disable the legacy two-minute auto-ride mode.
        rides.setAutoRecord(false)
        bluetooth.onMeasurements = { [weak self] in self?.rides.recordMeasurements($0) }
        bluetooth.onStreamFrame = { [weak self] in self?.rides.recordStreamFrame(at: $0) }
        bluetooth.onDiagnosticEvent = { [weak self] in self?.rides.recordDiagnostic($0) }
        bluetooth.$connected.removeDuplicates().sink { [weak self] connected in
            self?.rides.bluetoothChanged(connected)
            self?.connectionContext.snapshot(reason: connected ? "bike_connected" : "bike_disconnected")
        }.store(in: &subscriptions)
        rides.$active.map { $0?.id }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] id in
            guard let self else { return }
            self.connectionContext.setRecording(id != nil)
            if id != nil { self.rides.recordConnectionContext(ConnectionTestSettingsView.capture()) }
        }.store(in: &subscriptions)
        Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.rides.active != nil else { return }
            self.bluetooth.recordHealthSnapshot()
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
