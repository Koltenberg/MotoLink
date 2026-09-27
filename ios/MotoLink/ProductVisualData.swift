#if targetEnvironment(simulator)
import Foundation
import UIKit

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

    static func measurements() -> [MotoProtocol.Measurement] {
        [("wheel_speed", "Скорость", 68.0, "км/ч"),
         ("gear_position", "Передача", 3.0, ""),
         ("engine_speed", "Обороты", 5300.0, "об/мин"),
         ("engine_water_temperature", "Температура", 92.0, "°C")].map {
            MotoProtocol.Measurement(id: $0.0, label: $0.1, value: $0.2, unit: $0.3,
                                     timestamp: Date(), source: "Simulator example")
        }
    }
    static func catalogue() -> TelemetryPresentation {
        var value = TelemetryPresentation()
        value.configure(measurements().map {
            MotoProtocol.Capability(id: $0.id, label: $0.label, mode: $0.id == "engine_speed" ? 0 : 1)
        })
        value.receive(Data(), decoded: measurements())
        return value
    }
}
#endif
