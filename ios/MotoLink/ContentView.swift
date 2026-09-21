import SwiftUI
import Combine
import UIKit

struct ContentView: View {
    @ObservedObject var bluetooth: MotorcycleBluetooth
    @ObservedObject var rides: RideRecorder
    @State private var showHelp = false

    private let accent = MotoTheme.accent
    private var occupied: Bool { bluetooth.connecting || bluetooth.connected }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    connectionCard
                    if !occupied { discovery }
                    captureControls
                    rideStatus
                    NavigationLink { RideHistoryView(rides: rides) } label: {
                        Label("Поездки и журналы", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .pixelPanel()
                    }.buttonStyle(.plain)
                    DisclosureGroup("Показатели мотоцикла") {
                        MotorcycleMeasurementsView(bluetooth: bluetooth)
                    }
                    DisclosureGroup("Диагностика") {
                        VStack(alignment: .leading, spacing: 20) {
                            diagnosticControls
                            logSection
                        }.padding(.top, 12)
                    }
                }
                .padding(20)
            }
            .background(MotoTheme.background)
            .navigationTitle("Moto Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showHelp = true } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Как подключиться")
                }
            }
            .sheet(isPresented: $showHelp) { help }
            .sheet(item: $bluetooth.exportedFiles) { files in
                ShareSheet(items: files.urls)
            }
        }
        .sheet(item: $rides.exportedFiles) { files in ShareSheet(items: files.urls) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 5) {
                    Rectangle().fill(accent).frame(width: 7, height: 7)
                    Rectangle().fill(accent.opacity(0.4)).frame(width: 7, height: 7)
                    Text("MOTO LINK").font(MotoTheme.font(.headline)).tracking(2)
                }.foregroundStyle(accent)
                Spacer()
                Text(AppBuild.version).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(rides.active == nil ? "Подключись.\nИ поехали." : "Записываем\nтвою поездку.")
                .font(MotoTheme.font(MotoTheme.font(.largeTitle)))
            Label("На iPhone · запись без интернета", systemImage: "iphone")
                .font(MotoTheme.font(.subheadline)).foregroundStyle(.secondary)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: bluetooth.connected ? "link" : "antenna.radiowaves.left.and.right")
                    .font(MotoTheme.font(.title2)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bluetooth.selectedName).font(MotoTheme.font(.headline))
                    Text(bluetooth.ready ? "Bluetooth подключён" : bluetooth.connecting ? (bluetooth.reconnectAttempt > 0 ? "Восстанавливаем связь…" : "Подключаемся…") : bluetooth.connected ? "Готовим соединение…" : "Bluetooth не подключён")
                        .font(MotoTheme.font(.subheadline)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if bluetooth.connecting { ProgressView() }
            }
            BikeActivityView(bluetooth: bluetooth).equatable()
            if rides.active != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let state = TelemetryFreshness.state(connected: bluetooth.connected,
                        ready: bluetooth.ready, lastStreamAt: bluetooth.lastStreamAt, now: context.date)
                    Text(state == .receiving ? "Данные байка поступают" : state == .disconnected
                         ? "Данные байка не поступают" : state == .stale
                         ? "Поток данных байка прервался" : "Ждём поток данных байка")
                        .font(MotoTheme.font(.headline)).foregroundStyle(state == .receiving ? Color.green : Color.orange)
                    if bluetooth.connecting, let requested = bluetooth.connectionRequestedAt {
                        Text("Ожидание связи: \(duration(context.date.timeIntervalSince(requested))). Переподключение пока не подтверждено.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if rides.active != nil && !bluetooth.connected {
                Text("Связь с байком прервалась. Журнал остаётся на телефоне, запись GPS продолжается при доступном сигнале.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let reason = bluetooth.reconnectBlockedReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
            if !occupied && bluetooth.hasRememberedDevice {
                Button { bluetooth.connectRemembered() } label: {
                    Label("Подключить мотоцикл", systemImage: "link").frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(PixelButtonStyle()).disabled(!bluetooth.bluetoothPowered)
            }
            if occupied && rides.active == nil {
                Button("Отменить подключение") { bluetooth.stop() }.font(.caption)
            }
            if !bluetooth.bluetoothPowered {
                Text("Включи Bluetooth и разреши доступ для Moto Link в настройках iPhone.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(18).pixelPanel()
    }

    private var rideStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let ride = rides.active {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .top) {
                        metric("В ПУТИ", value: duration(context.date.timeIntervalSince(ride.startedAt)))
                        Spacer()
                        metric("ПО GPS", value: String(format: "%.1f км", ride.distanceMeters / 1000))
                    }
                    if let message = rides.gpsStatus(at: context.date) {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
                Text("Событий Bluetooth: \(ride.rawEventCount ?? 0)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let last = bluetooth.lastPacketAt {
                    HStack {
                        Text("Последний пакет Bluetooth")
                        Text(last, style: .time)
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Ожидаем данные байка. Само подключение ещё не подтверждает телеметрию.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = rides.error {
                Label("Ошибка сохранения: \(error)", systemImage: "exclamationmark.triangle")
                    .font(MotoTheme.font(.subheadline)).foregroundStyle(.orange)
            }
            if let error = bluetooth.storageError {
                Text("Ошибка журнала Bluetooth: \(error)").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                bluetooth.scanning ? bluetooth.stopScan() : bluetooth.scan()
            } label: {
                Label(bluetooth.scanning ? "Остановить поиск" : "Найти мотоцикл", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(PixelButtonStyle())
            .disabled(!bluetooth.bluetoothPowered || occupied)

            ForEach(bluetooth.nearby) { device in
                Button { bluetooth.connect(to: device.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.name).font(MotoTheme.font(.headline))
                            Text(device.id.uuidString.suffix(8))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(device.rssi) dBm").font(.caption.monospaced())
                        Image(systemName: "chevron.right")
                    }
                    .padding(16)
                    .pixelPanel()
                }
                .buttonStyle(.plain)
                .disabled(occupied)
            }
        }
    }

    private var diagnosticControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Проверка каналов").font(MotoTheme.font(.title3).weight(.semibold))
            Text("Соберём сведения, возможности, напряжение, температуры и попробуем запустить поток. Если поток не появится, автоматически применим один резервный профиль совместимости. Он передаёт мотоциклу имя телефона MotoLink.")
                .font(MotoTheme.font(.subheadline)).foregroundStyle(.secondary)
            Button { bluetooth.runFullDiagnostic() } label: {
                Label("Проверить всё", systemImage: "bolt.shield").frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(PixelButtonStyle(prominent: true)).foregroundStyle(.white)
                .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning)
            if bluetooth.diagnosticRunning {
                HStack { ProgressView(); Text(bluetooth.diagnosticStatus).font(.caption) }
            } else { Text(bluetooth.diagnosticStatus).font(.caption).foregroundStyle(.secondary) }
            Text("Показатели остаются экспериментальными. Поле впрыска сохраняется без единиц: его смысл и масштаб ещё проверяем. Все пакеты сохраняются даже без расшифровки.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Отдельные запросы") {
                requestButton("Модель и версия", subtitle: "Информация из ответа", icon: "bolt.circle", commands: [0x03])
                requestButton("Возможности", subtitle: "Поддерживаемые показатели", icon: "list.bullet.rectangle", commands: [0x40])
                requestButton("Текущие значения", subtitle: "Напряжение и температуры", icon: "waveform.path", commands: [0x41, 0x45])
            }
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if rides.active == nil {
                Button {
                    rides.setAutoRecord(false)
                    rides.startCapture()
                    if rides.active != nil {
                        for event in bluetooth.events { rides.recordDiagnostic(event) }
                        bluetooth.setAutoReconnect(true)
                        bluetooth.runFullDiagnostic()
                    }
                } label: {
                    Label("Начать запись", systemImage: "record.circle")
                        .font(MotoTheme.font(.headline)).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(PixelButtonStyle(prominent: true)).foregroundStyle(.white)
                    .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning)
                Text(bluetooth.ready ? "Запишем GPS, доступные данные байка и ошибки в один журнал." : "Включи мотоцикл и подключись перед движением.")
                    .font(MotoTheme.font(.subheadline)).foregroundStyle(.secondary)
            } else {
                if bluetooth.diagnosticRunning {
                    HStack { ProgressView(); Text("Проверяем данные байка…").font(MotoTheme.font(.subheadline)) }
                    Text("Дождись окончания проверки перед движением. Запись уже идёт.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Запись идёт · без ограничения времени", systemImage: "record.circle.fill")
                        .font(MotoTheme.font(.subheadline).weight(.semibold)).foregroundStyle(accent)
                }
                Button {
                    bluetooth.stop()
                    rides.finishAndExport()
                } label: {
                    Label(rides.exporting ? "Сохраняем…" : "Закончить и сохранить", systemImage: "square.and.arrow.up")
                        .font(MotoTheme.font(.headline)).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(PixelButtonStyle(prominent: true)).foregroundStyle(.white).disabled(rides.exporting)
                Text("После остановки сохрани журнал в «Файлы». Остановка двигателя сама запись не завершает.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).pixelPanel(Color(red: 0.14, green: 0.07, blue: 0.085), accent: true)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Журнал").font(MotoTheme.font(.title3).weight(.semibold))
                Spacer()
                Button { bluetooth.export() } label: {
                    if bluetooth.exportBusy { ProgressView() }
                    else { Label("Экспорт", systemImage: "square.and.arrow.up") }
                }
                .disabled(bluetooth.exportBusy)
            }
            if let error = bluetooth.storageError {
                Text("Не удалось сохранить журнал: \(error)")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Локальный JSONL: время, каналы и исходные байты. Экспорт может содержать идентификаторы мотоцикла. Последние 5 файлов, до 10 МБ каждый; сведения подключения сохраняются отдельно.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(bluetooth.events.suffix(40).reversed())) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(event.kind.uppercased())
                                .foregroundStyle(event.kind == "rx" ? accent : Color.secondary)
                            Spacer()
                            Text(String(event.timestamp.dropFirst(11).prefix(12)))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2.monospaced())
                        Text(event.detail).font(.caption).textSelection(.enabled)
                        if let hex = event.hex {
                            Text(hex.isEmpty ? "∅ (пустой пакет)" : hex)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .pixelPanel()
    }

    private func duration(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .monospaced).weight(.semibold)).monospacedDigit()
        }
    }

    private func requestButton(_ title: String, subtitle: String, icon: String, commands: [UInt8]) -> some View {
        Button { bluetooth.request(commands) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(MotoTheme.font(.subheadline).weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixelPanel()
        }
        .buttonStyle(.plain)
        .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning)
        .opacity(bluetooth.ready && !bluetooth.busy ? 1 : 0.45)
    }

    private var help: some View {
        NavigationStack {
            List {
                Section("Перед поездкой") {
                    Text("Включи мотоцикл. Закрой Bluefy, RIDEOLOGY и другие приложения, использующие его Bluetooth.")
                    Text("Нажми «Найти мотоцикл», выбери свой байк и дождись подключения. Затем нажми «Начать запись» и дождись окончания проверки.")
                    Text("Разреши Bluetooth и геопозицию «Всегда». Не закрывай Moto Link смахиванием. Работу под блокировкой сначала проверь в короткой поездке.")
                }
                Section("В дороге") {
                    Text("Записываем полученные пакеты, GPS и ошибки на iPhone. Интернет для записи не нужен. Восстановление Bluetooth включается вместе с записью, но мотоцикл может не принять повторное соединение.")
                    Text("Потеря GPS или Bluetooth не завершает сеанс. Пропущенные данные не выдумываются; при остановке приложения системой возможны пробелы.")
                }
                Section("После поездки") {
                    Text("Остановись и нажми «Закончить и сохранить» → «Сохранить в Файлы» → «На iPhone». Повторно выгрузить журнал можно в разделе «Поездки и журналы».")
                    Text("Журнал содержит маршрут. Передавай его лично, не публикуй в открытом репозитории.")
                }
                Section("Показатели") {
                    Text("Доступность и расшифровка показателей зависят от мотоцикла. Все полученные пакеты сохраняются даже без расшифровки. Скорость и расстояние GPS поступают с телефона.")
                    Text("Карта и оценка пути по дорогам могут требовать интернет. Это не мешает локальной записи.")
                }
            }.scrollContentBackground(.hidden).background(MotoTheme.background)
                .navigationTitle("Как записать поездку")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showHelp = false } } }
        }
    }

}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// One static texture, two effect frames per second. Packet-rate updates do
/// not redraw this child; background/reduced-motion/low-power mode pauses it.
private struct BikeActivityView: View, Equatable {
    let bluetooth: MotorcycleBluetooth
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot = BikeActivitySnapshot()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bluetooth === rhs.bluetooth }

    private var animating: Bool {
        scenePhase == .active && !reduceMotion && !lowPower && snapshot.live
            && (snapshot.moving || snapshot.running || (snapshot.thermalLevel ?? 0) > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.animation(minimumInterval: 0.5, paused: !animating)) { context in
                let phase = animating ? Int(context.date.timeIntervalSince1970 * 2) % 4 : 0
                ZStack {
                    Canvas { canvas, size in
                        // Static pixel ground: no scrolling background or 60 Hz loop.
                        for index in 0..<14 {
                            let x = CGFloat(index) * size.width / 14
                            let rect = CGRect(x: x, y: size.height * 0.97, width: size.width / 20, height: 2)
                            canvas.fill(Path(rect), with: .color(Color.white.opacity(0.08)))
                        }
                    }
                    Image("BikeSpriteDetail")
                        .resizable().interpolation(.none).scaledToFit()
                        .saturation(snapshot.live ? 1 : 0.15)
                        .opacity(snapshot.live ? 1 : 0.70)
                        .offset(y: animating && snapshot.running && phase % 2 == 1 ? 0.7 : 0)
                    Canvas { canvas, size in
                        drawEffects(context: canvas, size: size, phase: phase)
                    }
                }.aspectRatio(2, contentMode: .fit)
            }
            .frame(maxWidth: 360)
            .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(snapshot.label).font(MotoTheme.font(.subheadline).weight(.semibold))
                Spacer(minLength: 2)
                Text(snapshot.temperature.map { "\($0) °C" } ?? "— °C")
                    .font(.system(.headline, design: .monospaced).monospacedDigit())
                    .foregroundStyle((snapshot.thermalLevel ?? 0) >= 6 ? Color.orange : Color.secondary)
                    .accessibilityLabel(snapshot.temperature.map { "Охлаждающая жидкость: \($0) градусов" }
                        ?? "Нет свежей температуры охлаждающей жидкости")
            }
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    Rectangle().fill(snapshot.live && index < (snapshot.engineLevel ?? 0)
                        ? MotoTheme.accent : Color.white.opacity(0.12))
                        .frame(width: 12, height: CGFloat(4 + index * 3))
                }
                Text(snapshot.live ? "Живые данные" : "Ожидаем данные")
                    .font(MotoTheme.font(.caption)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.live ? "Свежие данные мотоцикла" : "Нет свежих данных мотоцикла")
            Text("Свет и выхлоп — оформление. Тепло — по температуре ОЖ.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { sample() }
        .onReceive(ticker) { _ in if scenePhase == .active { sample() } }
        .onChange(of: scenePhase) { phase in if phase == .active { sample() } }
    }

    private func sample() {
        let next = BikeActivitySnapshot.sample(connected: bluetooth.connected, ready: bluetooth.ready,
            measurements: bluetooth.measurements, now: Date())
        if snapshot != next { snapshot = next }
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func drawEffects(context: GraphicsContext, size: CGSize, phase: Int) {
        guard snapshot.live else { return }
        let unit = size.width / 160
        func pixel(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
            let rect = CGRect(x: (x * 160).rounded() * unit, y: (y * 80).rounded() * unit,
                              width: w * unit, height: h * unit)
            context.fill(Path(rect), with: .color(color))
        }
        if snapshot.running {
            // Cosmetic head/tail lights, not decoded switches or beam state.
            pixel(0.817, 0.345, 3, 2, Color(red: 1, green: 0.93, blue: 0.77).opacity(0.8))
            pixel(0.838, 0.364, 6, 2, Color(red: 1, green: 0.93, blue: 0.77).opacity(0.10))
            pixel(0.865, 0.380, 8, 3, Color(red: 1, green: 0.93, blue: 0.77).opacity(0.05))
            pixel(0.126, 0.196, 3, 1, MotoTheme.accent.opacity(0.65))
            // Exhaust exists at cold idle too. Density follows RPM, not a smoke sensor.
            for index in 0..<(2 + (snapshot.engineLevel ?? 0)) {
                let travel = Double((index + phase) % 7) / 7
                let heat = Double(snapshot.thermalLevel ?? 0) / 8
                pixel(0.165 - travel * 0.13, 0.49 - travel * (0.10 + heat * 0.14),
                      2 + travel * 3, 1 + travel * 2, Color.gray.opacity(0.20 * (1 - travel)))
            }
        }
        if snapshot.moving {
            // Moving highlights on the rims; body and brake calipers stay fixed.
            for (x, y, radius) in [(0.190, 0.698, 0.083), (0.813, 0.717, 0.088)] {
                for offset in [0.0, 180.0] {
                    let angle = Double(phase) * 45 + offset
                    var path = Path()
                    path.addArc(center: CGPoint(x: x * size.width, y: y * size.height),
                                radius: radius * size.width,
                                startAngle: .degrees(angle), endAngle: .degrees(angle + 26),
                                clockwise: false)
                    context.stroke(path, with: .color(Color(red: 1, green: 0.42, blue: 0.40).opacity(0.6)), lineWidth: unit)
                }
            }
            for index in 0..<4 {
                let x = 0.18 + Double(index) * 0.18 - Double(phase) * 0.018
                pixel(x, 0.968, 5, 1, Color.gray.opacity(0.25))
            }
        }
        if let heat = snapshot.thermalLevel, heat > 0 {
            // Cosmetic warmth, never a fan, fault, smoke sensor or fire warning.
            let warmth = Double(heat) / 8
            let color = Color(red: 0.67 + 0.14 * warmth, green: 0.64,
                              blue: 0.64 - 0.14 * warmth).opacity(0.12 + 0.18 * warmth)
            if snapshot.running {
                for index in 0..<(2 + heat / 2) {
                    let travel = (Double(index) + Double(phase) / 4) / 7
                    let x = 0.16 - travel * 0.14
                    let y = 0.49 - travel * (0.12 + 0.14 * warmth)
                    pixel(x, y, 2 + travel * 4, 1 + warmth, color)
                    pixel(x - 0.009, y - 0.017, 2 + travel * 2, 1, color.opacity(0.6))
                }
            }
            for index in 0..<(1 + heat / 3) {
                let x = 0.46 + Double(index) * 0.043 + Double(phase % 2) * 0.006
                pixel(x, 0.52 - Double((index + phase) % 4) * 0.026, 1, 2, color.opacity(0.55))
            }
        }
    }
}
