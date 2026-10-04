import Combine
import SwiftUI

struct SpeedComparisonView: View, Equatable {
    let bluetooth: MotorcycleBluetooth
    let rides: RideRecorder
    var preview = false
    var compact = false
    var onSelect: (String) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(MetricColorPreferences.storageKey) private var scaleSettingsData = Data()
    private var colorPreferences: MetricColorPreferences {
        MetricColorPreferences.decoded(scaleSettingsData) ?? MetricColorPreferences.load(persistMigration: false)
    }
    @State private var gps: Double?
    @State private var bike: Double?
    @State private var difference: Double?
    @State private var timer: Timer?
    @State private var visible = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bluetooth === rhs.bluetooth && lhs.rides === rhs.rides
            && lhs.preview == rhs.preview && lhs.compact == rhs.compact
    }
    private var display: (gps: Double?, bike: Double?, difference: Double?) {
        #if targetEnvironment(simulator)
        if preview { return ProductVisualData.speedComparison() }
        #endif
        return (gps, bike, difference)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { reading("GPS", display.gps); reading("Байк", display.bike) }
            } else {
                HStack(alignment: .top, spacing: 12) { reading("GPS", display.gps); reading("Байк", display.bike) }
            }
            if !compact, let difference = display.difference {
                Text(String(format: "Разница %+.0f км/ч", difference))
                    .font(MotoTheme.font(.caption).monospacedDigit()).foregroundStyle(MotoTheme.secondary)
            }
        }
        .onAppear { visible = true; updateTimer(for: scenePhase) }
        .onDisappear { visible = false; timer?.invalidate(); timer = nil }
        .onChange(of: scenePhase) { phase in updateTimer(for: phase) }
        .onReceive(bluetooth.$dashboardTelemetry.dropFirst()) { latest in
            guard visible && scenePhase == .active else { return }
            sample(telemetry: latest)
        }
    }
    @ViewBuilder private func reading(_ title: String, _ speed: Double?) -> some View {
        let id = title == "GPS" ? "gps_speed" : "wheel_speed"
        Button { onSelect(id) } label: {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    Spacer(minLength: 0)
                    Text(speed.map { String(format: "%.0f", $0) } ?? "—")
                        .font(MotoTheme.numberFont(size: 42).monospacedDigit())
                        .foregroundStyle(MetricVisualColor.color(metricID: id, value: speed, preferences: colorPreferences) ?? MotoTheme.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("км/ч").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 7).pixelPanel(accent: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    Text(speed.map { String(format: "%.0f", $0) } ?? "—")
                        .font(MotoTheme.numberFont(size: 60).monospacedDigit())
                        .foregroundStyle(MetricVisualColor.color(metricID: id, value: speed, preferences: colorPreferences) ?? MotoTheme.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("км/ч").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).pixelPanel(accent: true)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(title == "GPS" ? "Скорость GPS" : "Скорость мотоцикла")
        .accessibilityValue(speed.map { String(format: "%.0f километров в час", $0) } ?? "Нет свежих данных")
        .accessibilityHint("Дважды коснитесь, чтобы увеличить показатель")
    }
    private func sample(fromTimer: Bool = false, telemetry latest: TelemetryPresentation? = nil) {
        #if targetEnvironment(simulator)
        defer { ProductVisualRefreshProbe.sample(panel: "speed", fromTimer: fromTimer) }
        if preview { let sample = ProductVisualData.speedComparison(); gps = sample.gps; bike = sample.bike; difference = sample.difference; return }
        #endif
        let now = Date()
        let gpsTime = rides.lastLocationAt
        gps = gpsTime.flatMap { time in
            let age = now.timeIntervalSince(time)
            return age >= 0 && age <= 3 ? rides.speedMS.map { $0 * 3.6 } : nil
        }
        let currentTelemetry = latest ?? bluetooth.dashboardTelemetry
        let field = currentTelemetry.fields.first { $0.id == "wheel_speed" }
            ?? TelemetryPresentation.placeholder("wheel_speed")
        let row = currentTelemetry.row(field, connected: bluetooth.connected, ready: bluetooth.ready, now: now)
        bike = row.value
        if let gps, let bike, let gpsTime, let bikeTime = row.measurement?.timestamp,
           abs(gpsTime.timeIntervalSince(bikeTime)) <= 2 { difference = bike - gps }
        else { difference = nil }
    }
    private func updateTimer(for phase: ScenePhase) {
        timer?.invalidate(); timer = nil
        guard visible else { return }
        sample()
        // Use the callback's new phase, not the previous View captured by the
        // iOS 16-compatible onChange overload.
        guard phase == .active else { return }
        let refresh = Timer(timeInterval: 1, repeats: true) { _ in sample(fromTimer: true) }
        timer = refresh; RunLoop.main.add(refresh, forMode: .common)
    }
}

struct ConnectionTestSettingsView: View {
    @AppStorage("MotoLink.test.sena") private var sena = "unknown"
    @AppStorage("MotoLink.test.watch") private var watch = "unknown"
    @AppStorage("MotoLink.test.position") private var position = "unknown"
    @AppStorage("MotoLink.test.senaFirmware") private var firmware = ""
    @AppStorage("MotoLink.test.senaVariant") private var variant = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Условия следующей поездки").font(MotoTheme.font(.headline))
            PixelChoiceField(title: "Sena 50S", selection: $sena, options: [
                .init(value: "unknown", label: "Не указано"),
                .init(value: "off", label: "Выключена"),
                .init(value: "idle", label: "Подключена, без звука"),
                .init(value: "music", label: "Музыка"),
                .init(value: "intercom", label: "Интерком Bluetooth"),
                .init(value: "mesh", label: "Mesh")
            ])
            PixelChoiceField(title: "Apple Watch", selection: $watch, options: [
                .init(value: "unknown", label: "Не указано"),
                .init(value: "on", label: "На руке, включены"),
                .init(value: "off", label: "Выключены")
            ])
            PixelChoiceField(title: "Телефон", selection: $position, options: [
                .init(value: "unknown", label: "Не указано"),
                .init(value: "mount", label: "На креплении"),
                .init(value: "pocket", label: "В кармане"),
                .init(value: "bag", label: "В сумке")
            ])
            PixelChoiceField(title: "Модель с наклейки Sena", selection: $variant, options: [
                .init(value: "", label: "Не указана"),
                .init(value: "SP113", label: "50S · SP113"),
                .init(value: "SP75", label: "50S · SP75")
            ])
            if variant == "SP113" {
                Text("SP113 — аппаратный вариант 50S с веткой прошивки 2.x. Наклейка не показывает установленную версию; её можно посмотреть в приложении Sena.").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            TextField("Версия Sena, если известна", text: $firmware).font(MotoTheme.font(.body)).textFieldStyle(.roundedBorder)
            Text("Это твои отметки, а не обнаруженные устройства. Условия сбросятся после начала записи; вариант и версия сохранятся. Системная диагностика Apple в этот журнал не входит.")
                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
        }.font(MotoTheme.font(.subheadline))
    }
    static func capture() -> String {
        let d = UserDefaults.standard
        func value(_ key: String) -> String {
            String((d.string(forKey: "MotoLink.test." + key) ?? "unknown").prefix(80))
                .replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "\n", with: " ")
        }
        let detail = "source=user_reported; sena=\(value("sena")); watch=\(value("watch")); phonePosition=\(value("position")); senaVariant=\(value("senaVariant")); senaFirmware=\(value("senaFirmware")); actualWatchTransport=unknown"
        for key in ["sena", "watch", "position"] { d.set("unknown", forKey: "MotoLink.test." + key) }
        return detail
    }
}
