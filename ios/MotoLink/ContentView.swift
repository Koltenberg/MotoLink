import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var bluetooth: MotorcycleBluetooth
    @ObservedObject var rides: RideRecorder
    @State private var showHelp = false

    private let accent = Color(red: 0.94, green: 0.20, blue: 0.25)
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
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
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
            .background(Color(red: 0.045, green: 0.047, blue: 0.055))
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
                Text("MOTO LINK").font(.caption.weight(.heavy)).tracking(3).foregroundStyle(accent)
                Spacer()
                Text("0.4.1").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(rides.active == nil ? "Твой маршрут.\nТвой ритм." : "Поездка записывается.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Label("На iPhone · запись без интернета", systemImage: "iphone")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: bluetooth.connected ? "link" : "antenna.radiowaves.left.and.right")
                    .font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bluetooth.selectedName).font(.headline)
                    Text(bluetooth.ready ? "Bluetooth подключён" : bluetooth.connecting ? "Подключаемся…" : bluetooth.connected ? "Готовим соединение…" : "Bluetooth не подключён")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if bluetooth.connecting { ProgressView() }
            }
            if rides.active != nil && !bluetooth.connected {
                Text("Связь с байком прервалась. Журнал остаётся на телефоне, запись GPS продолжается при доступном сигнале.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !occupied && bluetooth.hasRememberedDevice {
                Button { bluetooth.connectRemembered() } label: {
                    Label("Подключить мотоцикл", systemImage: "link").frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.bordered).disabled(!bluetooth.bluetoothPowered)
            }
            if occupied && rides.active == nil {
                Button("Отменить подключение") { bluetooth.stop() }.font(.caption)
            }
            if !bluetooth.bluetoothPowered {
                Text("Включи Bluetooth и разреши доступ для Moto Link в настройках iPhone.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(18).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
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
                        Text("Последние данные байка")
                        Text(last, style: .time)
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Ожидаем данные байка. Само подключение ещё не подтверждает телеметрию.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = rides.error {
                Label("Ошибка сохранения: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.orange)
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
            .buttonStyle(.bordered)
            .disabled(!bluetooth.bluetoothPowered || occupied)

            ForEach(bluetooth.nearby) { device in
                Button { bluetooth.connect(to: device.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.name).font(.headline)
                            Text(device.id.uuidString.suffix(8))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(device.rssi) dBm").font(.caption.monospaced())
                        Image(systemName: "chevron.right")
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(occupied)
            }
        }
    }

    private var diagnosticControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Проверка каналов").font(.title3.weight(.semibold))
            Text("Соберём сведения, возможности, напряжение, температуры и попробуем запустить поток. Если поток не появится, автоматически применим один резервный профиль совместимости. Он передаёт мотоциклу имя телефона MotoLink.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { bluetooth.runFullDiagnostic() } label: {
                Label("Проверить всё", systemImage: "bolt.shield").frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).foregroundStyle(.white)
                .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning)
            if bluetooth.diagnosticRunning {
                HStack { ProgressView(); Text(bluetooth.diagnosticStatus).font(.caption) }
            } else { Text(bluetooth.diagnosticStatus).font(.caption).foregroundStyle(.secondary) }
            Text("Значения 4A и температуры помечаются экспериментальными до проверки формата EX500G. Все пакеты сохраняются даже без расшифровки.")
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
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).foregroundStyle(.white)
                    .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning)
                Text(bluetooth.ready ? "Запишем GPS, доступные данные байка и ошибки в один журнал." : "Включи мотоцикл и подключись перед движением.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                if bluetooth.diagnosticRunning {
                    HStack { ProgressView(); Text("Проверяем данные байка…").font(.subheadline) }
                    Text("Дождись окончания проверки перед движением. Запись уже идёт.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Запись идёт · без ограничения времени", systemImage: "record.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                }
                Button {
                    bluetooth.stop()
                    rides.finishAndExport()
                } label: {
                    Label(rides.exporting ? "Сохраняем…" : "Закончить и сохранить", systemImage: "square.and.arrow.up")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(rides.exporting)
                Text("После остановки сохрани журнал в «Файлы». Остановка двигателя сама запись не завершает.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Журнал").font(.title3.weight(.semibold))
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
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22))
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
        }
    }

    private func requestButton(_ title: String, subtitle: String, icon: String, commands: [UInt8]) -> some View {
        Button { bluetooth.request(commands) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
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
            }.navigationTitle("Как записать поездку")
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
