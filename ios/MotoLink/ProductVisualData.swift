#if targetEnvironment(simulator)
import Foundation

/// Fictional visual fixtures, excluded from every device build. Never sent to BLE
/// or written to a user's ride journal. Used by the actual dashboard renderers.
enum ProductVisualData {
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
