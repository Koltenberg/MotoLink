import SwiftUI

struct SpeedComparisonView: View, Equatable {
    let bluetooth: MotorcycleBluetooth
    let rides: RideRecorder
    var preview = false
    var compact = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
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
        if preview { return (64, 68, 4) }
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
                    .font(.system(.caption).monospacedDigit()).foregroundStyle(MotoTheme.secondary)
            }
        }
        .onAppear { visible = true; updateTimer() }
        .onDisappear { visible = false; timer?.invalidate(); timer = nil }
        .onChange(of: scenePhase) { _ in updateTimer() }
    }
    @ViewBuilder private func reading(_ title: String, _ speed: Double?) -> some View {
        if compact {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(.caption)).foregroundStyle(MotoTheme.secondary)
                Spacer(minLength: 0)
                Text(speed.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 42, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("км/ч").font(.system(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 7).pixelPanel(accent: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(.caption)).foregroundStyle(MotoTheme.secondary)
                Text(speed.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 60, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("км/ч").font(.system(.caption)).foregroundStyle(MotoTheme.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).pixelPanel(accent: true)
        }
    }
    private func sample() {
        #if targetEnvironment(simulator)
        if preview { gps = 64; bike = 68; difference = 4; return }
        #endif
        let now = Date()
        let gpsTime = rides.lastLocationAt
        gps = gpsTime.flatMap { time in
            let age = now.timeIntervalSince(time)
            return age >= 0 && age <= 3 ? rides.speedMS.map { $0 * 3.6 } : nil
        }
        let field = bluetooth.dashboardTelemetry.fields.first { $0.id == "wheel_speed" }
            ?? TelemetryPresentation.placeholder("wheel_speed")
        let row = bluetooth.dashboardTelemetry.row(field, connected: bluetooth.connected, ready: bluetooth.ready, now: now)
        bike = row.value
        if let gps, let bike, let gpsTime, let bikeTime = row.measurement?.timestamp,
           abs(gpsTime.timeIntervalSince(bikeTime)) <= 2 { difference = bike - gps }
        else { difference = nil }
    }
    private func updateTimer() {
        timer?.invalidate(); timer = nil
        guard visible else { return }
        sample()
        guard scenePhase == .active else { return }
        let refresh = Timer(timeInterval: 1, repeats: true) { _ in sample() }
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
            Picker("Sena 50S", selection: $sena) {
                Text("Не указано").tag("unknown"); Text("Выключена").tag("off")
                Text("Подключена, без звука").tag("idle"); Text("Музыка").tag("music")
                Text("Интерком Bluetooth").tag("intercom"); Text("Mesh").tag("mesh")
            }
            Picker("Apple Watch", selection: $watch) {
                Text("Не указано").tag("unknown"); Text("На руке, включены").tag("on"); Text("Выключены").tag("off")
            }
            Picker("Телефон", selection: $position) {
                Text("Не указано").tag("unknown"); Text("На креплении").tag("mount")
                Text("В кармане").tag("pocket"); Text("В сумке").tag("bag")
            }
            Picker("Модель с наклейки Sena", selection: $variant) {
                Text("Не указана").tag("")
                Text("50S · SP113").tag("SP113")
                Text("50S · SP75").tag("SP75")
            }
            if variant == "SP113" {
                Text("SP113 — аппаратный вариант 50S с веткой прошивки 2.x. Наклейка не показывает установленную версию; её можно посмотреть в приложении Sena.").font(.caption).foregroundStyle(MotoTheme.secondary)
            }
            TextField("Версия Sena, если известна", text: $firmware).textFieldStyle(.roundedBorder)
            Text("Это твои отметки, а не обнаруженные устройства. Условия сбросятся после начала записи; вариант и версия сохранятся. Системная диагностика Apple в этот журнал не входит.")
                .font(.caption).foregroundStyle(MotoTheme.secondary)
        }.font(.system(.subheadline))
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
