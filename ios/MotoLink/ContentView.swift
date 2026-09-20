import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var bluetooth: MotorcycleBluetooth
    @ObservedObject var rides: RideRecorder
    @State private var showHelp = false

    private let accent = Color(red: 0.56, green: 0.93, blue: 0.37)
    private var occupied: Bool { bluetooth.connecting || bluetooth.connected }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    connectionCard
                    discovery
                    captureControls
                    RidePanel(rides: rides)
                    MotorcycleMeasurementsView(bluetooth: bluetooth)
                    diagnosticControls
                    logSection
                }
                .padding(20)
            }
            .background(Color(red: 0.055, green: 0.065, blue: 0.055))
            .navigationTitle("MotoLink")
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
        VStack(alignment: .leading, spacing: 8) {
            Text("MOTOLINK / 0.4")
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(accent)
            Text("Твой байк. Твои поездки.")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Text("Маршруты на iPhone, связь с Kawasaki и единая проверка доступных данных.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(bluetooth.connected ? accent : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bluetooth.selectedName).font(.headline)
                    Text(bluetooth.status).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if bluetooth.connecting { ProgressView() }
            }

            Divider()
            HStack(alignment: .top, spacing: 12) {
                metric("СОЕДИНЕНИЕ", value: bluetooth.connected ? "Есть" : "Нет")
                Spacer()
                metric("ВХОДЯЩИЕ ПАКЕТЫ", value: String(bluetooth.packetCount))
            }
            if let last = bluetooth.lastPacketAt {
                HStack {
                    Text("Последний пакет")
                    Spacer()
                    Text(last, style: .time).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Подключение по Bluetooth ещё не означает, что получена телеметрия.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Подключаться автоматически", isOn: Binding(
                get: { bluetooth.autoReconnect },
                set: { bluetooth.setAutoReconnect($0) }
            ))
            .font(.subheadline)
            .disabled(!bluetooth.hasRememberedDevice)

            Text("После первой полной проверки приложение повторяет профиль телеметрии при автоподключении. Bluetooth-связь не подтверждает запуск двигателя.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if occupied || bluetooth.scanning {
                Button(role: .destructive) { bluetooth.stop() } label: {
                    Label("Остановить", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else if bluetooth.hasRememberedDevice {
                Button { bluetooth.connectRemembered() } label: {
                    Label("Подключить сохранённый", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.black)
                .disabled(!bluetooth.bluetoothPowered)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
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
            Text("Одна полная проверка").font(.title3.weight(.semibold))
            Text("Соберём сведения, возможности, напряжение, температуры и попробуем запустить поток. Если поток не появится, автоматически применим один резервный профиль совместимости. Он передаёт мотоциклу имя телефона MotoLink.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { bluetooth.runFullDiagnostic() } label: {
                Label("Проверить всё", systemImage: "bolt.shield").frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning)
            if bluetooth.diagnosticRunning {
                HStack { ProgressView(); Text(bluetooth.diagnosticStatus).font(.caption) }
            } else { Text(bluetooth.diagnosticStatus).font(.caption).foregroundStyle(.secondary) }
            Text("Остановка потока — кнопкой «Остановить» в блоке соединения. Значения 4A и температуры помечаются экспериментальными до проверки формата EX500G. Все пакеты сохраняются даже без расшифровки.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Отдельные запросы") {
                requestButton("Модель и версия", subtitle: "Информация из ответа", icon: "bolt.circle", commands: [0x03])
                requestButton("Возможности", subtitle: "Поддерживаемые показатели", icon: "list.bullet.rectangle", commands: [0x40])
                requestButton("Текущие значения", subtitle: "Напряжение и температуры", icon: "waveform.path", commands: [0x41, 0x45])
            }
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Одна поездка — один журнал").font(.title3.weight(.semibold))
            if rides.active == nil {
                Button {
                    rides.startCapture()
                    if rides.active != nil {
                        // Include connection setup already observed before the button.
                        for event in bluetooth.events { rides.recordDiagnostic(event) }
                        bluetooth.setAutoReconnect(true)
                        bluetooth.runFullDiagnostic()
                    }
                } label: {
                    Label("Собирать всё и начать поездку", systemImage: "record.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                    .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning)
                Text("Подключись на месте. Запусти сбор и дождись окончания проверки перед движением. Затем можно заблокировать экран; не смахивай приложение.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    // Capture the disconnect and final transport state before closing the file.
                    bluetooth.stop()
                    rides.finishAndExport()
                } label: {
                    Label("Завершить и сохранить журнал", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(rides.exporting)
                Text("Записываются GPS, исходные пакеты, ошибки и разрывы. После поездки остановись, нажми эту кнопку и выбери «Сохранить в Файлы». Повторный экспорт доступен в истории.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Остановка двигателя пока не определяется достоверно. В этом режиме потеря GPS или Bluetooth не завершает сеанс. Сохранённое остаётся на iPhone после перезапуска; время, когда iOS не выполняла приложение, восстановить нельзя.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
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
                Section("Первый запуск") {
                    Text("Включи зажигание стоящего мотоцикла. Для этой проверки запускать двигатель не нужно.")
                    Text("Заверши соединение с мотоциклом в nRF Connect и RIDEOLOGY. Разреши Bluetooth для MotoLink.")
                    Text("Нажми «Найти мотоцикл» и выбери Kawasaki-EX500G. Если iOS запросит код сопряжения, используй код своей приборки.")
                    Text("Дождись сообщения «Каналы готовы». Нажми «Проверить всё» один раз. Дождись результата и экспортируй журнал даже при ошибках.")
                }
                Section("Автоподключение") {
                    Text("Выбранный мотоцикл запоминается. Включённый переключатель позволяет iOS ждать его появления и восстанавливать связь в фоне.")
                    Text("После принудительного закрытия смахиванием открой MotoLink снова. Отключённый Bluetooth, отозванное разрешение и ограничения iOS мешают переподключению.")
                    Text("Кнопка «Остановить» отключает автоподключение и поток. GPS-поездку заверши отдельной кнопкой. После первой полной проверки профиль телеметрии повторяется при автоподключении.")
                }
                Section("Поездки и геопозиция") {
                    Text("GPS, скорость и расстояние берутся с iPhone. Мотоциклетные значения подписаны отдельно. Ручная поездка работает без Bluetooth.")
                    Text("Для автозаписи нужны оба переключателя: автоподключение и запись при подключении. Разреши геопозицию «Всегда». Уже начатая вручную запись допускает «При использовании» и продолжается под блокировкой, пока iOS разрешает выполнение.")
                    Text("После прекращения процесса возможны разрывы маршрута. Экспорт сохраняет сегменты GPX, исходные точки и измерения. Карта может требовать интернет для подложки; сама запись локальная.")
                }
                Section("Что мы проверяем") {
                    Text("На твоём EX500G подтверждены модель, восемь поддерживаемых полей и пакет напряжения. Поток 4A и температурный формат ещё требуют проверки на байке.")
                    Text("BLE-связь и входящий пакет сами по себе не доказывают работу двигателя или движение. Данные температуры, скорости и оборотов здесь не подменяются предположениями.")
                    Text("Полная проверка использует опубликованные запросы и профиль сессии Z500; резервный путь передаёт имя MotoLink. Прошивка и сброс сервиса не затрагиваются.")
                }
            }
            .navigationTitle("Подключение")
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
