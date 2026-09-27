import SwiftUI
import Combine
import UIKit

struct ContentView: View {
    @ObservedObject var bluetooth: MotorcycleBluetooth
    @ObservedObject var rides: RideRecorder
    @StateObject private var companion = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("MotoLink.appearance") private var appearance = "system"
    @AppStorage("MotoLink.keepScreenOn") private var keepScreenOn = false
    @State private var selectedTab = 0
    @State private var showSettings = false
    @State private var showProfile = false
    @State private var showHelp = false
    @State private var showDiagnostics = false
    @State private var showDiscovery = false
    @State private var justSaved = false
    @State private var recordAfterPairing = true
    private let accent = MotoTheme.accent
    private var occupied: Bool { bluetooth.connecting || bluetooth.connected }
    private var bikeName: String { companion.data.bikeName }
    private var hasRideDisplay: Bool { bluetooth.connected || rides.active != nil || previewRide }
    private var previewRide: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("--review-ride")
        #else
        return false
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                CompanionView(store: companion, rides: rides)
                    .safeAreaInset(edge: .bottom) {
                        if !bluetooth.hasRememberedDevice {
                            Button { showDiscovery = true; bluetooth.scan() } label: {
                                Label("Добавить мотоцикл", systemImage: "plus").frame(maxWidth: .infinity)
                            }.buttonStyle(PixelButtonStyle(prominent: true)).padding(14).background(MotoTheme.background)
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { settingsButton }
            }.tabItem { Label("Гараж", systemImage: "house") }.tag(0)
            NavigationStack {
                rideScreen
                    .navigationTitle(bikeName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { settingsButton }
            }.tabItem { Label("Поездка", systemImage: "speedometer") }.tag(1)
            NavigationStack {
                HistoryHubView(rides: rides)
                    .navigationBarTitleDisplayMode(.inline)
            }.tabItem { Label("История", systemImage: "clock.arrow.circlepath") }.tag(2)
        }
        .sheet(isPresented: $showSettings) { settings }
        .sheet(isPresented: $showProfile) { BikeProfileEditor(store: companion) }
        .sheet(isPresented: $showHelp) { help }
        .sheet(isPresented: $showDiscovery) { discoverySheet }
        .sheet(isPresented: $showDiagnostics) { diagnostics }
        .sheet(item: $rides.exportedFiles) { files in ShareSheet(items: files.urls) }
        .onAppear {
            if rides.active != nil || bluetooth.connected { selectedTab = 1 }
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--review-ride") { selectedTab = 1 }
            if ProcessInfo.processInfo.arguments.contains("--review-history") { selectedTab = 2 }
            if ProcessInfo.processInfo.arguments.contains("--review-settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showSettings = true }
            }
            #endif
            updateScreenAwake()
        }
        .onChange(of: rides.active?.id) { id in
            if id != nil { selectedTab = 1 }
            updateScreenAwake()
        }
        .onChange(of: bluetooth.connected) { connected in if connected { selectedTab = 1 } }
        .onChange(of: scenePhase) { _ in updateScreenAwake() }
        .onChange(of: keepScreenOn) { _ in updateScreenAwake() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ToolbarContentBuilder private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Настройки")
        }
    }

    private var rideScreen: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width > 600 && !typeSize.isAccessibilitySize
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 8 : 16) {
                    if compact && hasRideDisplay { compactConnectionStatus }
                    else { connectionStatus }
                    if hasRideDisplay {
                        if compact {
                            HStack(alignment: .top, spacing: 18) {
                                VStack(spacing: 8) {
                                    SpeedComparisonView(bluetooth: bluetooth, rides: rides, preview: previewRide, compact: true).equatable()
                                    MotorcycleDashboardView(bluetooth: bluetooth, preview: previewRide, compact: true).equatable()
                                }.frame(maxWidth: .infinity)
                                VStack(spacing: 4) {
                                    BikeActivityView(bluetooth: bluetooth, preview: previewRide, compact: true).equatable()
                                    rideStatus
                                }.frame(width: geometry.size.width * 0.26)
                            }
                        } else {
                            instrumentPanel
                            BikeActivityView(bluetooth: bluetooth, preview: previewRide).equatable()
                            rideStatus
                        }
                    } else {
                        Image("BikeSpriteDetail").resizable().interpolation(.none).scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 185).accessibilityHidden(true)
                        Text(bluetooth.connecting ? "Ждём твой байк" : "Поехали?")
                            .font(MotoTheme.font(.title)).foregroundStyle(.primary)
                        Text(bluetooth.connecting
                             ? "Включи зажигание и держи iPhone рядом. Ожидание можно оставить или отменить."
                             : bluetooth.hasRememberedDevice
                             ? (bluetooth.autoReconnect && !bluetooth.connectionPaused
                                ? "Включи зажигание. Подключимся к твоему мотоциклу."
                                : "Включи зажигание и нажми «Подключиться».")
                             : "Включи зажигание и один раз выбери свой мотоцикл.")
                            .font(MotoTheme.font(.body)).foregroundStyle(MotoTheme.secondary)
                        if !occupied {
                            Button {
                                if bluetooth.hasRememberedDevice { bluetooth.connectRemembered() }
                                else { showDiscovery = true; bluetooth.scan() }
                            } label: {
                                Label(bluetooth.hasRememberedDevice ? "Подключиться" : "Выбрать мотоцикл",
                                      systemImage: "link").frame(maxWidth: .infinity)
                            }.buttonStyle(PixelButtonStyle(prominent: true))
                                .disabled(!bluetooth.bluetoothPowered)
                        }
                        if rides.autoRecord {
                            Label("Автозапись включена", systemImage: "record.circle")
                                .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                        }
                    }
                    if let error = bluetooth.storageError {
                        Label("Журнал не сохраняется: " + error, systemImage: "exclamationmark.triangle")
                            .font(MotoTheme.font(.caption)).foregroundStyle(.red)
                    }
                }.padding(.horizontal, compact ? 12 : 18).padding(.vertical, compact ? 8 : 18)
            }
            .background(MotoTheme.background)
            .safeAreaInset(edge: .bottom) {
                if hasRideDisplay {
                    captureControls.padding(.horizontal, 16).padding(.vertical, 8)
                        .background(MotoTheme.background)
                }
            }
        }
    }

    private var instrumentPanel: some View {
        VStack(spacing: 12) {
            SpeedComparisonView(bluetooth: bluetooth, rides: rides, preview: previewRide).equatable()
            MotorcycleDashboardView(bluetooth: bluetooth, preview: previewRide).equatable()
        }
    }

    private var compactConnectionStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: bluetooth.ready || previewRide ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
            Text(previewRide ? "Связь с байком · пример" : bluetooth.ready ? "Связь с байком" : bluetooth.connected ? "Готовим соединение" : "Ждём связь")
                .font(MotoTheme.font(.subheadline))
            if rides.active != nil && !bluetooth.connected && !previewRide {
                Text("Запись продолжается").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            Spacer()
            if let reason = bluetooth.reconnectBlockedReason, !previewRide {
                PixelInfoButton(title: "Почему ожидаем подключение", detail: reason)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if bluetooth.canRequestUserRescan(at: context.date) && !previewRide {
                    Button("Повторить поиск") { bluetooth.requestUserRescan() }.font(MotoTheme.font(.caption))
                }
            }
            if occupied && rides.active == nil && !previewRide {
                Button("Отменить") { bluetooth.pauseConnection() }.font(MotoTheme.font(.subheadline))
            }
        }.padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: bluetooth.connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(bluetooth.connected ? Color.primary : MotoTheme.secondary)
                Text(previewRide ? "Связь с байком · пример" : bluetooth.ready ? "Связь с байком" : bluetooth.connected ? "Готовим соединение" :
                    bluetooth.connecting ? "Ожидаем подключения" : "Байк не подключён")
                    .font(MotoTheme.font(.subheadline))
                Spacer()
                if bluetooth.connecting { ProgressView().controlSize(.small) }
                if occupied && rides.active == nil {
                    Button("Отменить") { bluetooth.pauseConnection() }.font(MotoTheme.font(.subheadline))
                }
            }
            if !bluetooth.bluetoothPowered && !previewRide {
                Text(bluetooth.status).font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            } else if let reason = bluetooth.reconnectBlockedReason {
                Text(reason).font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            }
            if rides.active != nil && !bluetooth.connected {
                Label("Ждём связь · запись продолжается", systemImage: "arrow.triangle.2.circlepath")
                    .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if bluetooth.canRequestUserRescan(at: context.date) {
                    Button("Повторить поиск рядом") { bluetooth.requestUserRescan() }
                        .font(MotoTheme.font(.subheadline))
                }
            }
        }.padding(14).pixelPanel()
    }

    private var rideStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ride = rides.active {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack {
                        metric("Время", value: duration(context.date.timeIntervalSince(ride.startedAt)))
                        Spacer()
                        metric("Путь GPS", value: String(format: "%.1f км", ride.distanceMeters / 1000))
                    }
                    if rides.gpsStatus(at: context.date) != nil {
                        Label("GPS временно недоступен", systemImage: "location.slash").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }
                }
            }
        }
    }

    private var discoverySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Включи зажигание").font(MotoTheme.font(.title2))
                    Text("Держи iPhone рядом с байком. Выбери его в списке — повторно выбирать не понадобится.")
                        .foregroundStyle(MotoTheme.secondary)
                    if bluetooth.scanning {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack { ProgressView(); Text(bluetooth.scanProgress(at: context.date)) }
                        }
                        Button("Остановить поиск") { bluetooth.stopScan() }
                    } else {
                        if bluetooth.nearby.isEmpty {
                            Text(bluetooth.scanFoundNothing ? "Мотоцикл не найден. Проверь зажигание и доступность Bluetooth на приборке." : "Готовы найти мотоцикл рядом.")
                        }
                        Button("Искать рядом") { bluetooth.scan() }
                            .buttonStyle(PixelButtonStyle(prominent: true)).disabled(!bluetooth.bluetoothPowered)
                    }
                    Toggle("Записывать поездки автоматически", isOn: $recordAfterPairing)
                    Text("Начнём запись при подключении. Сохраняем на iPhone без интернета.").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    ForEach(bluetooth.nearby) { device in
                        Button {
                            bluetooth.connect(to: device.id)
                            bluetooth.setAutoReconnect(true)
                            rides.setAutoRecord(recordAfterPairing)
                            selectedTab = 1
                            showDiscovery = false
                        } label: {
                            HStack {
                                Image(systemName: "motorcycle")
                                Text(device.name).font(MotoTheme.font(.headline))
                                Spacer(); Image(systemName: "chevron.right")
                            }.padding(18).pixelPanel()
                        }.buttonStyle(.plain)
                    }
                    if !bluetooth.bluetoothPowered {
                        Text("Для поиска нужен Bluetooth. Разрешение можно изменить в настройках iPhone.")
                    }
                    DisclosureGroup("Не видишь свой байк?") {
                        Text("На Ninja / Z500 подключись до движения, в первые минуты после включения зажигания. Если окно поиска закрылось, повтори после выключения и включения зажигания на стоянке. Закрой другие приложения, подключённые к мотоциклу.")
                            .font(MotoTheme.font(.subheadline)).padding(.top, 8)
                    }.foregroundStyle(MotoTheme.secondary)
                }.padding(20)
            }.background(MotoTheme.background).navigationTitle("Выбрать мотоцикл")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showDiscovery = false } } }
        }.onAppear { if bluetooth.hasRememberedDevice { recordAfterPairing = rides.autoRecord } }
        .onDisappear { bluetooth.stopScan() }
    }

    private var settings: some View {
        NavigationStack {
            List {
                PixelSection("Мой байк") {
                    Button { showSettings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showProfile = true } } label: {
                        Label("Имя и пробег", systemImage: "pencil")
                    }
                    Button("Выбрать другой мотоцикл") {
                        showSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showDiscovery = true; bluetooth.scan() }
                    }.disabled(occupied || rides.active != nil)
                }
                Section {
                    Toggle("Подключаться автоматически", isOn: Binding(get: { bluetooth.autoReconnect }, set: bluetooth.setAutoReconnect)).disabled(!bluetooth.hasRememberedDevice)
                    Toggle("Начинать запись при подключении", isOn: Binding(get: { rides.autoRecord }, set: { value in
                        if value { bluetooth.setAutoReconnect(true) }
                        rides.setAutoRecord(value)
                    })).disabled(!bluetooth.hasRememberedDevice)
                    if !bluetooth.hasRememberedDevice { Text("Сначала выбери мотоцикл в разделе «Поездка».").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary) }
                    if rides.autoRecord && rides.authorization != .authorizedAlways {
                        Button("Разрешить GPS в фоне") { rides.requestBackgroundPermission() }
                    }
                } header: { Text("Автоматические поездки").font(MotoTheme.font(.caption)) }
                footer: { Text("После первого выбора ждём байк и сохраняем запись на iPhone. Заверши поездку кнопкой после остановки. Если смахнуть приложение, открой его снова. iOS может ограничить запуск в фоне.").font(MotoTheme.font(.caption)) }
                PixelSection("Экран") {
                    PixelChoiceField(title: "Тема", selection: $appearance, options: [
                        .init(value: "system", label: "Как на iPhone"),
                        .init(value: "light", label: "Светлая"),
                        .init(value: "dark", label: "Тёмная")
                    ])
                    Toggle("Не гасить экран при записи", isOn: $keepScreenOn)
                    Text("Светлая тема удобнее на солнце. Экран остаётся включённым только пока Moto Link открыт.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                Section {
                    Button("Начать за минуту") {
                        showSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showHelp = true }
                    }
                    Button("Диагностика для разработки") {
                        showSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showDiagnostics = true }
                    }
                }
                PixelSection("О Moto Link") {
                    Text("Всё для твоего байка — на телефоне.")
                    LabeledContent("Версия", value: AppBuild.version)
                    Text("Гараж, запись и история работают без интернета. Показатели байка пока экспериментальные. Анимация иллюстрирует данные; свет фар — оформление. Скорость не корректируется автоматически.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
            }.font(MotoTheme.font(.body)).scrollContentBackground(.hidden).background(MotoTheme.background)
                .navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showSettings = false } } }
        }
    }

    private var diagnostics: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ConnectionTestSettingsView()
                    diagnosticControls
                    logSection
                }.padding(20)
            }.background(MotoTheme.background).navigationTitle("Диагностика")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showDiagnostics = false } } }
                .sheet(item: $bluetooth.exportedFiles) { files in ShareSheet(items: files.urls) }
        }
    }

    private func updateScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn && rides.active != nil && scenePhase == .active
    }

    private var diagnosticControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Проверка каналов").font(MotoTheme.font(.title3))
            Text("Событий в поездке: \(rides.active?.rawEventCount ?? 0)")
                .font(MotoTheme.font(.caption).monospacedDigit()).foregroundStyle(MotoTheme.secondary)
            if let last = bluetooth.lastPacketAt {
                Text("Последние данные: \(last.formatted(date: .omitted, time: .standard))")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            Text("Соберём сведения, возможности, напряжение, температуры и попробуем запустить поток. Если поток не появится, автоматически применим один резервный профиль совместимости. Он передаёт мотоциклу имя телефона MotoLink.")
                .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            Button { bluetooth.runFullDiagnostic() } label: {
                Label("Проверить всё", systemImage: "bolt.shield").frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(PixelButtonStyle(prominent: true)).foregroundStyle(.white)
                .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning)
            if bluetooth.diagnosticRunning {
                HStack { ProgressView(); Text(bluetooth.diagnosticStatus).font(MotoTheme.font(.caption)) }
            } else { Text(bluetooth.diagnosticStatus).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary) }
            Text("Показатели остаются экспериментальными. Поле впрыска сохраняется без единиц: его смысл и масштаб ещё проверяем. Все пакеты сохраняются даже без расшифровки.")
                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            DisclosureGroup("Отдельные запросы") {
                requestButton("Модель и версия", subtitle: "Информация из ответа", icon: "bolt.circle", commands: [0x03])
                requestButton("Возможности", subtitle: "Поддерживаемые показатели", icon: "list.bullet.rectangle", commands: [0x40])
                requestButton("Текущие значения", subtitle: "Напряжение и температуры", icon: "waveform.path", commands: [0x41, 0x45])
            }
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rides.active == nil {
                Button {
                    justSaved = false
                    rides.startCapture()
                    if rides.active != nil {
                        for event in bluetooth.events { rides.recordDiagnostic(event) }
                        bluetooth.setAutoReconnect(true)
                        bluetooth.startCaptureProfileIfNeeded()
                    }
                } label: {
                    Label("Начать поездку", systemImage: "record.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(PixelButtonStyle(prominent: true))
                    .disabled(!bluetooth.ready || rides.finishingRide)
                if justSaved { Text("Сохранено в истории").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary) }
            } else {
                if rides.finishingRide {
                    HStack { ProgressView(); Text("Сохраняем поездку…") }.font(MotoTheme.font(.subheadline))
                } else {
                    HStack {
                        Circle().fill(accent).frame(width: 7, height: 7)
                        Text(rides.finishRequested ? "Повтори сохранение" : "Запись на iPhone")
                            .font(MotoTheme.font(.subheadline))
                        Spacer()
                        Button(rides.finishRequested ? "Сохранить ещё раз" : "Завершить") {
                            if !bluetooth.autoReconnect { bluetooth.pauseConnection() }
                            rides.stop { _ in justSaved = true }
                        }.buttonStyle(PixelButtonStyle())
                    }
                }
            }
            if let error = rides.error {
                Text("Не удалось сохранить: \(error)").font(MotoTheme.font(.caption)).foregroundStyle(.red)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Журнал").font(MotoTheme.font(.title3))
                Spacer()
                Button { bluetooth.export() } label: {
                    if bluetooth.exportBusy { ProgressView() }
                    else { Label("Экспорт", systemImage: "square.and.arrow.up") }
                }
                .disabled(bluetooth.exportBusy)
            }
            if let error = bluetooth.storageError {
                Text("Не удалось сохранить журнал: \(error)")
                    .font(MotoTheme.font(.caption)).foregroundStyle(.orange)
            }
            Text("Локальный JSONL: время, каналы и исходные байты. Экспорт может содержать идентификаторы мотоцикла. Последние 5 файлов, до 10 МБ каждый; сведения подключения сохраняются отдельно.")
                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(bluetooth.events.suffix(40).reversed())) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(event.kind.uppercased())
                                .foregroundStyle(event.kind == "rx" ? accent : MotoTheme.secondary)
                            Spacer()
                            Text(String(event.timestamp.dropFirst(11).prefix(12)))
                                .foregroundStyle(MotoTheme.secondary)
                        }
                        .font(MotoTheme.font(.caption2))
                        Text(event.detail).font(MotoTheme.font(.caption)).textSelection(.enabled)
                        if let hex = event.hex {
                            Text(hex.isEmpty ? "∅ (пустой пакет)" : hex)
                                .font(MotoTheme.font(.caption2))
                                .foregroundStyle(MotoTheme.secondary)
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
            Text(label).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            Text(value).font(MotoTheme.font(.title2)).monospacedDigit()
        }
    }

    private func requestButton(_ title: String, subtitle: String, icon: String, commands: [UInt8]) -> some View {
        Button { bluetooth.request(commands) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(MotoTheme.font(.subheadline))
                    Text(subtitle).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
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
                PixelSection("1 · Выбери байк") {
                    Text("Включи зажигание. В «Поездке» нажми «Выбрать мотоцикл» и выбери его рядом.")
                }
                PixelSection("2 · Поехали") {
                    Text("Нажми «Начать поездку» или включи автозапись в настройках. Запись остаётся на iPhone даже при потере связи.")
                }
                PixelSection("3 · Сохрани") {
                    Text("После остановки нажми «Завершить». В «Истории» можно переименовать, удалить или поделиться поездкой.")
                }
                PixelSection("Твой гараж") {
                    Text("Укажи пробег с приборки, добавь заправку и интервалы обслуживания. Если дату замены не помнишь, достаточно пробега.")
                }
            }.scrollContentBackground(.hidden).background(MotoTheme.background)
                .navigationTitle("Начать за минуту").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showHelp = false } } }
        }
    }
}

private struct HistoryHubView: View {
    @ObservedObject var rides: RideRecorder
    @State private var section = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Поездки") { section = 0 }
                    .buttonStyle(PixelButtonStyle(prominent: section == 0))
                    .accessibilityAddTraits(section == 0 ? .isSelected : [])
                Button("Сводка") { section = 1 }
                    .buttonStyle(PixelButtonStyle(prominent: section == 1))
                    .accessibilityAddTraits(section == 1 ? .isSelected : [])
            }.padding(.horizontal, 18).padding(.vertical, 10)
            if section == 0 { RideHistoryView(rides: rides) }
            else { RideStatisticsView(rides: rides) }
        }.background(MotoTheme.background).navigationTitle("История")
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            // Completion also covers cancellation. The share extension has now
            // finished reading the copies; saved Documents journals stay intact.
            let sharedItems = items
            DispatchQueue.global(qos: .utility).async {
                MotoLinkExportCleanup.removeCompletedExports(sharedItems)
            }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// One static texture, at most four effect frames per second. Packet-rate updates do
/// not redraw this child; background/reduced-motion/low-power mode pauses it.
struct BikeActivityView: View, Equatable {
    let bluetooth: MotorcycleBluetooth
    var preview = false
    var compact = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sampledSnapshot = BikeActivitySnapshot()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var visible = false
    @State private var refreshTimer: Timer?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bluetooth === rhs.bluetooth && lhs.preview == rhs.preview && lhs.compact == rhs.compact }

    private var snapshot: BikeActivitySnapshot {
        #if targetEnvironment(simulator)
        if preview {
            let now = Date()
            return BikeActivitySnapshot.sample(connected: true, ready: true, measurements: ProductVisualData.measurements(at: now), now: now)
        }
        #endif
        return sampledSnapshot
    }

    private var animating: Bool {
        visible && scenePhase == .active && !reduceMotion && !lowPower && snapshot.live
            && (snapshot.moving || snapshot.running || (snapshot.thermalLevel ?? 0) > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.animation(minimumInterval: 0.25, paused: !animating)) { context in
                let phase = animating ? Int(context.date.timeIntervalSince1970 * 4) % 8 : 0
                ZStack {
                    Canvas { canvas, size in
                        // Static pixel ground: no scrolling background or 60 Hz loop.
                        for index in 0..<14 {
                            let x = CGFloat(index) * size.width / 14
                            let rect = CGRect(x: x, y: size.height * 0.97, width: size.width / 20, height: 2)
                            canvas.fill(Path(rect), with: .color(Color.primary.opacity(0.12)))
                        }
                    }
                    Image("BikeSpriteDetail")
                        .resizable().interpolation(.none).scaledToFit()
                        .saturation(1)
                        .opacity(1)
                        .offset(y: animating && snapshot.running && phase % 2 == 1 ? 1.0 : 0)
                    Canvas { canvas, size in
                        drawEffects(context: canvas, size: size, phase: phase)
                    }
                }.aspectRatio(2, contentMode: .fit)
            }
            .frame(maxWidth: 360)
            .accessibilityHidden(true)
            Text(snapshot.label).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            if !compact { HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    Rectangle().fill(snapshot.live && index < (snapshot.engineLevel ?? 0)
                        ? MotoTheme.accent : Color.primary.opacity(0.12))
                        .frame(width: 12, height: CGFloat(4 + index * 3))
                }
                Text(snapshot.live ? "Живые данные" : "Ожидаем данные")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.live ? "Свежие данные мотоцикла" : "Нет свежих данных мотоцикла")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { visible = true; updateRefreshTimer() }
        .onDisappear { visible = false; stopRefreshTimer() }
        .onChange(of: scenePhase) { _ in updateRefreshTimer() }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func updateRefreshTimer() {
        stopRefreshTimer()
        sample()
        guard visible && scenePhase == .active else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sample() }
    }

    private func sample() {
        #if targetEnvironment(simulator)
        if preview { return }
        #endif
        let next = BikeActivitySnapshot.sample(connected: bluetooth.connected, ready: bluetooth.ready,
            measurements: bluetooth.measurements, now: Date())
        if sampledSnapshot != next { sampledSnapshot = next }
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
            pixel(0.838, 0.364, 6, 2, Color(red: 1, green: 0.93, blue: 0.77).opacity(0.22))
            pixel(0.865, 0.380, 8, 3, Color(red: 1, green: 0.93, blue: 0.77).opacity(0.10))
            pixel(0.126, 0.196, 3, 1, MotoTheme.accent.opacity(0.65))
            // Exhaust exists at cold idle too. Density follows RPM, not a smoke sensor.
            for index in 0..<(2 + (snapshot.engineLevel ?? 0)) {
                let travel = Double((index + phase) % 7) / 7
                let heat = Double(snapshot.thermalLevel ?? 0) / 8
                pixel(0.165 - travel * 0.13, 0.49 - travel * (0.10 + heat * 0.14),
                      3 + travel * 4, 2 + travel * 2, Color.gray.opacity(0.38 * (1 - travel)))
            }
        }
        if snapshot.moving {
            // Moving highlights on the rims; body and brake calipers stay fixed.
            for (x, y, radius) in [(0.190, 0.698, 0.083), (0.813, 0.717, 0.088)] {
                for offset in [0.0, 180.0] {
                    let angle = Double(phase) * 22.5 + offset
                    var path = Path()
                    path.addArc(center: CGPoint(x: x * size.width, y: y * size.height),
                                radius: radius * size.width,
                                startAngle: .degrees(angle), endAngle: .degrees(angle + 38),
                                clockwise: false)
                    context.stroke(path, with: .color(Color(red: 1, green: 0.48, blue: 0.45).opacity(0.85)), lineWidth: 2 * unit)
                }
            }
            for index in 0..<4 {
                let x = 0.22 + Double(index) * 0.18 - Double(phase) * 0.014
                pixel(x, 0.968, 7, 1, Color.gray.opacity(0.38))
            }
        }
        if let heat = snapshot.thermalLevel, heat > 0 {
            // Cosmetic warmth, never a fan, fault, smoke sensor or fire warning.
            let warmth = Double(heat) / 8
            let color = Color(red: 0.67 + 0.14 * warmth, green: 0.64,
                              blue: 0.64 - 0.14 * warmth).opacity(0.12 + 0.18 * warmth)
            if snapshot.running {
                for index in 0..<(2 + heat / 2) {
                    let travel = (Double(index) + Double(phase) / 8) / 7
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
