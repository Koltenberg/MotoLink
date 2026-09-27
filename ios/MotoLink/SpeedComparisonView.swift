import SwiftUI

struct SpeedComparisonView: View, Equatable {
    let bluetooth: MotorcycleBluetooth
    let rides: RideRecorder
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var gps: Double?
    @State private var bike: Double?
    @State private var difference: Double?
    @State private var timer: Timer?
    @State private var visible = false
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bluetooth === rhs.bluetooth && lhs.rides === rhs.rides }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { reading("GPS", gps); reading("Байк · проверяем", bike) }
            } else {
                HStack(alignment: .top, spacing: 12) { reading("GPS", gps); reading("Байк · проверяем", bike) }
            }
            if let difference {
                Text(String(format: "Байк − GPS: %+.0f км/ч", difference)).font(.system(.subheadline).monospacedDigit())
            } else { Text("Разница появится при свежих данных обоих источников.").font(.system(.caption)).foregroundStyle(.secondary) }
            Text("GPS зависит от приёма. Скорость из Bluetooth ещё сверяем с приборкой; поправка автоматически не применяется.")
                .font(.system(.caption)).foregroundStyle(.secondary)
        }
        .onAppear { visible = true; updateTimer() }
        .onDisappear { visible = false; timer?.invalidate(); timer = nil }
        .onChange(of: scenePhase) { _ in updateTimer() }
    }
    private func reading(_ title: String, _ speed: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.caption)).foregroundStyle(.secondary)
            Text(speed.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("км/ч").font(.system(.caption)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).pixelPanel(accent: true)
    }
    private func sample() {
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
        guard visible, scenePhase == .active else { return }
        sample()
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
                Text("SP113 — аппаратный вариант 50S с веткой прошивки 2.x. Наклейка не показывает установленную версию; её можно посмотреть в приложении Sena.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Версия Sena, если известна", text: $firmware).textFieldStyle(.roundedBorder)
            Text("Это твои отметки, а не обнаруженные устройства. Условия сбросятся после начала записи; вариант и версия сохранятся. Системная диагностика Apple в этот журнал не входит.")
                .font(.caption).foregroundStyle(.secondary)
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
