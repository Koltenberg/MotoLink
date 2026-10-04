import SwiftUI
import Combine
import UIKit

struct ContentView: View {
    private enum ConnectionPrompt: Equatable { case rescan, disconnect, stopWaiting }
    private enum SignalPosition: Equatable { case firstDash, seat, returnDash }

    @ObservedObject var bluetooth: MotorcycleBluetooth
    @ObservedObject var rides: RideRecorder
    @StateObject private var companion = CompanionStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("MotoLink.appearance") private var appearance = "system"
    @AppStorage("MotoLink.keepScreenOn") private var keepScreenOn = false
    @State private var selectedTab = 0
    @State private var focusedMetric: FocusedRideMetric?
    @State private var showSettings = false
    @State private var showProfile = false
    @State private var showFuelEditor = false
    @State private var showHelp = false
    @State private var showDiagnostics = false
    @State private var showDiscovery = false
    @State private var connectionPrompt: ConnectionPrompt?
    @State private var showConnectionCheck = false
    @State private var connectionCheckOwnsScan = false
    @State private var firstDashSignals: [SignalComparisonPolicy.Reading] = []
    @State private var seatSignals: [SignalComparisonPolicy.Reading] = []
    @State private var returnDashSignals: [SignalComparisonPolicy.Reading] = []
    @State private var measuringSignalAt: SignalPosition?
    @State private var signalCheckMessage: String?
    @State private var signalCheckGeneration = UUID()
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
                            }.buttonStyle(PixelButtonStyle(prominent: true)).padding(14).background(MotoTheme.backdrop)
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
        .sheet(isPresented: $showProfile) { BikeProfileEditor(store: companion, rides: rides) }
        .sheet(isPresented: $showFuelEditor) { FuelEditor(store: companion, rides: rides, entry: nil) }
        .sheet(isPresented: $showHelp) { help }
        .sheet(isPresented: $showDiscovery) { discoverySheet }
        .sheet(isPresented: $showConnectionCheck) { connectionCheck }
        .sheet(isPresented: $showDiagnostics) { diagnostics }
        .sheet(item: $rides.exportedFiles) { files in ShareSheet(items: files.urls) }
        .fullScreenCover(item: $focusedMetric) { metric in
            FocusedRideMetricView(bluetooth: bluetooth, rides: rides, metric: metric,
                                  preview: previewRide) { focusedMetric = nil }
        }
        .confirmationDialog(connectionPrompt == .rescan
                            ? "Мотоцикл остановлен и зажигание включено заново?"
                            : connectionPrompt == .stopWaiting
                            ? "Остановить ожидание на стоянке?"
                            : "Отключить мотоцикл на стоянке?",
                            isPresented: Binding(get: { connectionPrompt != nil },
                                                 set: { if !$0 { connectionPrompt = nil } }),
                            titleVisibility: .visible) {
            if connectionPrompt == .rescan {
                Button("Да, повторить поиск") { bluetooth.requestUserRescan() }
            } else if connectionPrompt == .disconnect {
                Button("Отключить байк", role: .destructive) { bluetooth.pauseConnection() }
            } else if connectionPrompt == .stopWaiting {
                Button("Остановить ожидание", role: .destructive) { bluetooth.pauseConnection() }
            }
            Button("Назад", role: .cancel) {}
        } message: {
            Text(connectionPrompt == .rescan
                 ? "В движении байк может не предлагать подключение. Новый поиск отменит текущее ожидание iOS."
                 : "В движении новое подключение может быть недоступно до остановки и перезапуска двигателя.")
        }
        .onAppear {
            if rides.active != nil || bluetooth.connected { selectedTab = 1 }
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--review-ride") { selectedTab = 1 }
            if ProcessInfo.processInfo.arguments.contains("--review-focus-rpm") {
                // Simulator landscape review rotates the root scene first.
                // A full-screen cover presented before the geometry request
                // can report portrait-only support on hosted iOS 26 runners.
                let delay = ProcessInfo.processInfo.arguments.contains("--review-landscape") ? 3.0 : 0.4
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    focusedMetric = FocusedRideMetric(id: "engine_speed")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--review-focus-gps") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    focusedMetric = FocusedRideMetric(id: "gps_speed")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--review-history") { selectedTab = 2 }
            if ProcessInfo.processInfo.arguments.contains("--review-settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showSettings = true }
            }
            if ProcessInfo.processInfo.arguments.contains("--review-diagnostics") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showDiagnostics = true }
            }
            #endif
            updateScreenAwake()
        }
        .onChange(of: rides.active?.id) { id in
            if id != nil { selectedTab = 1 }
            updateScreenAwake(recording: id != nil)
        }
        .onChange(of: bluetooth.connected) { connected in if connected { selectedTab = 1 } }
        .onChange(of: scenePhase) { phase in updateScreenAwake(phase: phase) }
        .onChange(of: keepScreenOn) { enabled in updateScreenAwake(keepingScreenOn: enabled) }
        .onChange(of: focusedMetric?.id) { _ in updateScreenAwake() }
        .onDisappear {
            // A full-screen reading temporarily hides this view. It owns the
            // same ride screen-awake preference while it is presented.
            if focusedMetric == nil { UIApplication.shared.isIdleTimerDisabled = false }
        }
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
                    if !previewRide {
                        HStack {
                            Button { showConnectionCheck = true } label: {
                                Label("Проверить связь", systemImage: "antenna.radiowaves.left.and.right")
                            }
                            Spacer(minLength: 8)
                            if !occupied && rides.active == nil && bluetooth.hasRememberedDevice {
                                Button("Другой байк") { showDiscovery = true; bluetooth.scan() }
                                    .disabled(!bluetooth.canScanNearby)
                            }
                        }.font(MotoTheme.font(.subheadline))
                    }
                    if hasRideDisplay {
                        if compact {
                            HStack(alignment: .top, spacing: 18) {
                                VStack(spacing: 8) {
                                    SpeedComparisonView(bluetooth: bluetooth, rides: rides, preview: previewRide,
                                                        compact: true, onSelect: focusMetric).equatable()
                                    MotorcycleDashboardView(bluetooth: bluetooth, preview: previewRide,
                                                            compact: true, onSelect: focusMetric).equatable()
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
                        BikeArtworkView()
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
            .background(MotoTheme.backdrop)
            .safeAreaInset(edge: .bottom) {
                if hasRideDisplay {
                    captureControls.padding(.horizontal, 16).padding(.vertical, 8)
                        .background(MotoTheme.backdrop)
                }
            }
        }
    }

    private var instrumentPanel: some View {
        VStack(spacing: 12) {
            SpeedComparisonView(bluetooth: bluetooth, rides: rides, preview: previewRide,
                                onSelect: focusMetric).equatable()
            MotorcycleDashboardView(bluetooth: bluetooth, preview: previewRide,
                                    onSelect: focusMetric).equatable()
        }
    }

    private func focusMetric(_ id: String) {
        focusedMetric = FocusedRideMetric(id: id)
    }

    private var compactConnectionStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: bluetooth.ready || previewRide ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
            Text(previewRide ? "Связь с байком · пример" : bluetooth.ready ? "Связь с байком" : bluetooth.connected ? "Связь есть · ждём данные" : "Ждём связь")
                .font(MotoTheme.font(.subheadline))
            if rides.active != nil && !bluetooth.connected && !previewRide {
                Text("Запись продолжается").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            Spacer()
            if let reason = bluetooth.reconnectBlockedReason, !previewRide {
                PixelInfoButton(title: "Почему ожидаем подключение", detail: reason)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if rides.active == nil && bluetooth.canRequestUserRescan(at: context.date) && !previewRide {
                    Button("Поиск на стоянке") { connectionPrompt = .rescan }.font(MotoTheme.font(.caption))
                }
            }
            if bluetooth.connected && rides.active == nil && !previewRide {
                Button("Отключить") { connectionPrompt = .disconnect }.font(MotoTheme.font(.caption))
            }
            if bluetooth.connecting && !bluetooth.connected && rides.active == nil && !previewRide {
                Button("Остановить ожидание") { connectionPrompt = .stopWaiting }.font(MotoTheme.font(.subheadline))
            }
        }.padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: bluetooth.connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(bluetooth.connected ? Color.primary : MotoTheme.secondary)
                Text(previewRide ? "Связь с байком · пример" : bluetooth.ready ? "Связь с байком" : bluetooth.connected ? "Связь есть · ждём данные" :
                    bluetooth.connecting ? "Ожидаем подключения" : "Байк не подключён")
                    .font(MotoTheme.font(.subheadline))
                Spacer()
                if bluetooth.connecting { ProgressView().controlSize(.small) }
                if bluetooth.connecting && !bluetooth.connected && rides.active == nil {
                    Button("Остановить ожидание") { connectionPrompt = .stopWaiting }.font(MotoTheme.font(.subheadline))
                } else if bluetooth.connected && rides.active == nil && !previewRide {
                    Button("Отключить") { connectionPrompt = .disconnect }.font(MotoTheme.font(.subheadline))
                }
            }
            if !bluetooth.bluetoothPowered && !previewRide {
                Text(bluetooth.status).font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            } else if let reason = bluetooth.reconnectBlockedReason {
                Text(reason).font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            }
            if bluetooth.connected && !bluetooth.ready && !previewRide {
                Text(bluetooth.status).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            if rides.active != nil && !bluetooth.connected {
                Label("Связь прервана · запись продолжается", systemImage: "arrow.triangle.2.circlepath")
                    .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                Text("В движении байк может не предлагать новое подключение. После остановки и нового запуска двигателя связь может вернуться.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if rides.active == nil && bluetooth.canRequestUserRescan(at: context.date) {
                    Button("Поиск на стоянке") { connectionPrompt = .rescan }
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
                Button { showFuelEditor = true } label: {
                    Label("Заправка", systemImage: "fuelpump")
                }.buttonStyle(PixelButtonStyle())
                .accessibilityHint("Добавить заправку, не завершая запись поездки")
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
                    if let reason = bluetooth.scanUnavailableReason {
                        Text(reason).font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                    }
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
                            .buttonStyle(PixelButtonStyle(prominent: true)).disabled(!bluetooth.canScanNearby)
                    }
                    Toggle("Записывать поездки автоматически", isOn: $recordAfterPairing)
                    Text("Начнём запись при подключении. Сохраняем на iPhone без интернета.").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    ForEach(bluetooth.nearby) { device in
                        Button {
                            guard bluetooth.connect(to: device.id, automaticallyReconnect: true) else { return }
                            rides.setAutoRecord(recordAfterPairing)
                            selectedTab = 1
                            showDiscovery = false
                        } label: {
                            HStack {
                                Image(systemName: "motorcycle")
                                Text(device.name).font(MotoTheme.font(.headline))
                                Spacer(); Image(systemName: "chevron.right")
                            }.padding(18).pixelPanel()
                        }.buttonStyle(.plain).disabled(!bluetooth.canScanNearby)
                    }
                    if !bluetooth.bluetoothPowered {
                        Text("Для поиска нужен Bluetooth. Разрешение можно изменить в настройках iPhone.")
                    }
                    DisclosureGroup("Не видишь свой байк?") {
                        Text("На Ninja / Z500 подключись до движения, в первые минуты после включения зажигания. Если окно поиска закрылось, повтори после выключения и включения зажигания на стоянке. Закрой другие приложения, подключённые к мотоциклу.")
                            .font(MotoTheme.font(.subheadline)).padding(.top, 8)
                    }.foregroundStyle(MotoTheme.secondary)
                }.padding(20)
            }.background(MotoTheme.backdrop).navigationTitle("Выбрать мотоцикл")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showDiscovery = false } } }
        }.onAppear { if bluetooth.hasRememberedDevice { recordAfterPairing = rides.autoRecord } }
        .onDisappear { bluetooth.stopScan() }
    }

    private var connectionCheck: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Проверяем Bluetooth и видимость байка рядом.")
                        .font(MotoTheme.font(.headline))
                    Text("Проверка не подключает другой мотоцикл и не меняет настройки автозаписи. Уже включённое автоподключение продолжает работать.")
                        .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Bluetooth", value: bluetooth.bluetoothPowered ? "Доступен" : "Недоступен")
                            LabeledContent("Связь", value: bluetooth.ready ? "Подключён" : bluetooth.connected
                                ? "Готовим данные" : bluetooth.connecting ? "Ожидаем байк" : "Нет подключения")
                            Text("Данные байка: " + dataFreshness(bluetooth.lastStreamAt, at: context.date))
                                .foregroundStyle(MotoTheme.secondary)
                            if bluetooth.scanning {
                                HStack { ProgressView(); Text(bluetooth.scanProgress(at: context.date)) }
                            }
                        }.font(MotoTheme.font(.subheadline)).padding(16).pixelPanel()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Сравнить уровень сигнала").font(MotoTheme.font(.title3))
                        Text("На стоянке с включённым зажиганием замерь сигнал у приборки (A1), у переднего края сиденья (B), затем снова у приборки (A2). Байк должен оставаться на месте.")
                            .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(alignment: .leading, spacing: 12) {
                                signalPosition("У приборки · A1", readings: firstDashSignals,
                                               at: context.date, position: .firstDash)
                                signalPosition("У переднего края сиденья · B", readings: seatSignals,
                                               at: context.date, position: .seat)
                                signalPosition("Снова у приборки · A2", readings: returnDashSignals,
                                               at: context.date, position: .returnDash)
                                if let comparison = SignalComparisonPolicy.summary(
                                    firstDash: firstDashSignals, seat: seatSignals, returnDash: returnDashSignals,
                                    at: context.date, sessionID: signalCheckGeneration,
                                    connected: bluetooth.ready) {
                                    Text(signalComparisonText(comparison))
                                        .font(MotoTheme.font(.subheadline))
                                } else if !firstDashSignals.isEmpty || !seatSignals.isEmpty || !returnDashSignals.isEmpty {
                                    Text("Для сравнения нужны по 2 свежих замера A1 → B → A2 за 2 минуты в одном подключении.")
                                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                                }
                            }
                        }
                        Text("В каждой строке — до трёх замеров по порядку.")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                        if !firstDashSignals.isEmpty || !seatSignals.isEmpty || !returnDashSignals.isEmpty {
                            Button("Новый тест") { resetSignalReadings() }
                                .buttonStyle(PixelButtonStyle())
                                .disabled(measuringSignalAt != nil)
                        }
                        if measuringSignalAt != nil { ProgressView("Измеряем сигнал…") }
                        if let signalCheckMessage {
                            Text(signalCheckMessage).foregroundStyle(MotoTheme.secondary)
                        } else if !bluetooth.ready {
                            Text("Для замера дождись готового соединения с байком.")
                                .foregroundStyle(MotoTheme.secondary)
                        }
                        Text("RSSI показывает уровень сигнала текущего соединения. Значение может быть недоступно; замеры сами по себе не устанавливают причину обрывов.")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }.font(MotoTheme.font(.subheadline)).padding(16).pixelPanel()
                    if let reason = bluetooth.scanUnavailableReason {
                        Text(reason).font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                    }
                    if !bluetooth.connected {
                        Text(bluetooth.scanning ? "Мотоциклы рядом" : "Устройства из последнего поиска")
                            .font(MotoTheme.font(.title3))
                        ForEach(bluetooth.nearby) { device in
                            Label(device.name, systemImage: "motorcycle")
                                .font(MotoTheme.font(.headline)).padding(14).frame(maxWidth: .infinity, alignment: .leading).pixelPanel()
                        }
                        if bluetooth.nearby.isEmpty && !bluetooth.scanning && bluetooth.scanFoundNothing {
                            Text("Байк не найден. Проверь зажигание и доступность Bluetooth на приборке.")
                                .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                        } else if bluetooth.nearby.isEmpty && !bluetooth.scanning && connectionCheckOwnsScan {
                            Text("Поиск прерван до завершения. Повтори проверку, когда Moto Link открыт на экране.")
                                .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                        }
                        Button(bluetooth.scanning ? "Ищем рядом…" : "Проверить ещё раз") { checkVisibility() }
                            .buttonStyle(PixelButtonStyle(prominent: true))
                            .disabled(bluetooth.scanning || !bluetooth.canScanNearby)
                        Text("Появление байка в результатах поиска подтверждает видимость по Bluetooth. Это ещё не подтверждение совместимости или получения показателей. Для подключения выбери его в разделе «Поездка».")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }
                }.padding(20)
            }.background(MotoTheme.backdrop)
                .refreshable { checkVisibility() }
                .navigationTitle("Проверить связь").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showConnectionCheck = false } } }
        }.onAppear { resetSignalReadings(); checkVisibility() }
            .onReceive(bluetooth.$connected) { connected in
                if !connected { resetSignalReadings() }
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active { resetSignalReadings() }
            }
            .onDisappear {
                resetSignalReadings()
                if connectionCheckOwnsScan { bluetooth.stopScan() }
                connectionCheckOwnsScan = false
            }
    }

    private func checkVisibility() {
        guard bluetooth.canScanNearby, !bluetooth.scanning else { return }
        connectionCheckOwnsScan = true
        bluetooth.scan()
    }

    private func signalPosition(_ title: String, readings: [SignalComparisonPolicy.Reading], at now: Date,
                                position: SignalPosition) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(title).font(MotoTheme.font(.subheadline))
                Spacer(minLength: 4)
                Button("Замерить") { measureSignal(at: position) }
                    .buttonStyle(PixelButtonStyle())
                    .disabled(!bluetooth.ready || bluetooth.busy || bluetooth.diagnosticRunning ||
                              measuringSignalAt != nil || !canMeasureSignal(at: position, now: now))
                    .accessibilityLabel("Замерить сигнал: \(title)")
            }
            if let latest = readings.last {
                Text(readings.map { String($0.dBm) }.joined(separator: " → ") + " dBm")
                    .font(MotoTheme.font(.headline))
                let age = now.timeIntervalSince(latest.measuredAt)
                let ageDescription = age.isFinite && age >= 0
                    ? (age < 60 ? "\(Int(age)) с назад" : "\(Int(age / 60)) мин назад")
                    : "время неизвестно"
                Text("Последний \(latest.measuredAt.formatted(date: .omitted, time: .shortened)) · \(ageDescription)")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                if !SignalComparisonPolicy.isRecent(latest, at: now, sessionID: signalCheckGeneration) {
                    Text("Замер старше 2 минут · начни новый тест")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
            } else {
                Text("Нет замера").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
        }
    }

    private func resetSignalReadings() {
        signalCheckGeneration = UUID()
        firstDashSignals = []
        seatSignals = []
        returnDashSignals = []
        measuringSignalAt = nil
        signalCheckMessage = nil
    }

    private func signalComparisonText(_ comparison: SignalComparisonPolicy.Summary) -> String {
        let difference = comparison.seatImprovementDB.magnitude
            .formatted(.number.precision(.fractionLength(0...1)))
        if comparison.seatImprovementDB > 0 { return "У сиденья сильнее на \(difference) дБ (медиана)." }
        if comparison.seatImprovementDB < 0 { return "У сиденья слабее на \(difference) дБ (медиана)." }
        return "Медианный уровень сигнала одинаков."
    }

    private func canMeasureSignal(at position: SignalPosition, now: Date) -> Bool {
        switch position {
        case .firstDash:
            return firstDashSignals.count < 3 && seatSignals.isEmpty && returnDashSignals.isEmpty
        case .seat:
            return SignalComparisonPolicy.hasEnoughRecentReadings(firstDashSignals, at: now,
                                                                  sessionID: signalCheckGeneration) &&
                seatSignals.count < 3 && returnDashSignals.isEmpty
        case .returnDash:
            return SignalComparisonPolicy.hasEnoughRecentReadings(firstDashSignals, at: now,
                                                                  sessionID: signalCheckGeneration) &&
                SignalComparisonPolicy.hasEnoughRecentReadings(seatSignals, at: now,
                                                               sessionID: signalCheckGeneration) &&
                returnDashSignals.count < 3
        }
    }

    private func measureSignal(at position: SignalPosition) {
        guard measuringSignalAt == nil, bluetooth.ready,
              canMeasureSignal(at: position, now: Date()) else { return }
        measuringSignalAt = position
        signalCheckMessage = nil
        let generation = signalCheckGeneration
        bluetooth.measureSignalStrength { reading, message in
            guard generation == signalCheckGeneration, bluetooth.connected else { return }
            measuringSignalAt = nil
            if let reading {
                guard SignalComparisonPolicy.isValidRSSI(reading.dBm) else {
                    signalCheckMessage = "iOS не вернула доступный RSSI. Повтори замер."
                    return
                }
                let sample = SignalComparisonPolicy.Reading(dBm: reading.dBm,
                                                            measuredAt: reading.measuredAt,
                                                            sessionID: generation)
                switch position {
                case .firstDash: firstDashSignals.append(sample)
                case .seat: seatSignals.append(sample)
                case .returnDash: returnDashSignals.append(sample)
                }
            }
            signalCheckMessage = message
        }
    }

    private func dataFreshness(_ date: Date?, at now: Date) -> String {
        guard let date else { return "пока не поступали" }
        let age = now.timeIntervalSince(date)
        guard age.isFinite, age >= 0 else { return "время обновления неизвестно" }
        if age < 3 { return "поступают сейчас" }
        if age < 60 { return "последнее обновление \(Int(age)) с назад" }
        return "нет новых данных \(Int(min(age / 60, 999_999))) мин"
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
                    }.disabled(!bluetooth.canScanNearby || rides.active != nil)
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
                footer: { Text("Выбери байк один раз. Запись сохраняется на iPhone; после остановки нажми «Завершить».").font(MotoTheme.font(.caption)) }
                PixelSection("Экран") {
                    PixelChoiceField(title: "Тема", selection: $appearance, options: [
                        .init(value: "system", label: "Как на iPhone"),
                        .init(value: "light", label: "Светлая"),
                        .init(value: "dark", label: "Тёмная")
                    ])
                    Toggle("Не гасить экран при записи", isOn: $keepScreenOn)
                    NavigationLink("Цвета показателей") { MetricVisualSettingsView() }
                    Text("Светлая тема — для солнца. Удержание экрана работает, пока приложение открыто.")
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
                    Text("Поездки и гараж — без интернета. Рисунок иллюстрирует показания; свет и дым — оформление.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
            }.font(MotoTheme.font(.body)).scrollContentBackground(.hidden).background(MotoTheme.backdrop)
                .navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showSettings = false } } }
        }
    }

    private var diagnostics: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Журнал и сведения iPhone доступны без мотоцикла.", systemImage: "iphone")
                        .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                    logSection
                    DisclosureGroup("Условия проверки") {
                        ConnectionTestSettingsView().padding(.top, 10)
                    }.font(MotoTheme.font(.subheadline))
                    DisclosureGroup("Проверка каналов") {
                        diagnosticControls.padding(.top, 10)
                    }.font(MotoTheme.font(.subheadline))
                }.padding(20)
            }.background(MotoTheme.backdrop).navigationTitle("Диагностика")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showDiagnostics = false } } }
                .sheet(item: $bluetooth.exportedFiles) { files in ShareSheet(items: files.urls) }
        }
    }

    private func updateScreenAwake(phase: ScenePhase? = nil, keepingScreenOn: Bool? = nil,
                                  recording: Bool? = nil) {
        UIApplication.shared.isIdleTimerDisabled = (keepingScreenOn ?? keepScreenOn)
            && (recording ?? (rides.active != nil)) && (phase ?? scenePhase) == .active
    }

    private var diagnosticControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Проверка каналов").font(MotoTheme.font(.title3))
            Text(rides.active != nil ? "Событий в поездке: \(rides.active?.rawEventCount ?? 0)"
                 : "Последних событий в памяти: \(bluetooth.events.count)")
                .font(MotoTheme.font(.caption).monospacedDigit()).foregroundStyle(MotoTheme.secondary)
            if !bluetooth.ready {
                Text("Запросы показателей станут доступны после подключения к байку. Журнал ниже можно открыть и сохранить сейчас.")
                    .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            }
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
            } else if bluetooth.ready { Text(bluetooth.diagnosticStatus).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary) }
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
                            // Saving a ride must not tear down a healthy BLE link.
                            // Discovery may be unavailable once the bike is moving;
                            // disconnecting remains an explicit user action.
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
                Text("Журнал связи").font(MotoTheme.font(.title3))
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
            Text("Сохранён на iPhone. Экспорт — для разбора связи; он может содержать идентификаторы байка.")
                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            DisclosureGroup("Последние события") {
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
              }.padding(.top, 12)
            }.font(MotoTheme.font(.subheadline))
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
            }.scrollContentBackground(.hidden).background(MotoTheme.backdrop)
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
        }.background(MotoTheme.backdrop).navigationTitle("История")
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
            return ProductVisualData.bikeActivitySnapshot()
        }
        #endif
        return sampledSnapshot
    }

    private var animating: Bool {
        visible && scenePhase == .active && !reduceMotion && !lowPower && snapshot.live
            && (snapshot.moving || snapshot.running)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BikeArtworkFrame(compact: compact) {
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
                        if animating && snapshot.wind {
                            drawWind(context: canvas, size: size, phase: phase)
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
            }
            .accessibilityHidden(true)
            .overlay(alignment: .bottomLeading) {
                if compact {
                    Text(snapshot.live ? "Свежие данные" : "Нет свежих данных")
                        .font(MotoTheme.font(.caption))
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(MotoTheme.panel.opacity(0.94), in: PixelFrame())
                        .accessibilityLabel(snapshot.live ? "Свежие данные мотоцикла" : "Нет свежих данных мотоцикла")
                }
            }
            if !compact {
                Text(snapshot.label).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
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
        .onAppear { visible = true; updateRefreshTimer(phase: scenePhase) }
        .onDisappear { visible = false; stopRefreshTimer() }
        .onChange(of: scenePhase) { phase in updateRefreshTimer(phase: phase) }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func updateRefreshTimer(phase: ScenePhase) {
        stopRefreshTimer()
        sample()
        guard visible && phase == .active else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in sample() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
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
        // Decorative effects are absent in the background, Reduce Motion and
        // Low Power Mode. The unmodified motorcycle illustration remains.
        guard animating else { return }
        let unit = size.width / 160
        func pixel(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
            let rect = CGRect(x: (x * 160).rounded() * unit, y: (y * 80).rounded() * unit,
                              width: w * unit, height: h * unit)
            context.fill(Path(rect), with: .color(color))
        }
        if snapshot.running {
            // Visible but small illustrative lights; no headlight switch is decoded.
            let beam = Color(red: 1, green: 0.93, blue: 0.72)
            pixel(0.831, 0.346, 5, 3, beam.opacity(0.95))
            pixel(0.857, 0.348, 10, 3, beam.opacity(0.46))
            pixel(0.893, 0.344, 12, 2, beam.opacity(0.18))
            pixel(0.125, 0.195, 4, 2, MotoTheme.accent.opacity(0.85))
            // Exhaust starts at the visible muffler outlet, even at cold idle.
            // Heat changes the plume shape; this is not an exhaust sensor.
            let heat = Double(snapshot.thermalLevel ?? 0) / 8
            for index in 0..<(4 + (snapshot.engineLevel ?? 0) / 2) {
                let travel = Double((index * 2 + phase) % 8) / 8
                let x = 0.154 - travel * 0.125
                let y = 0.49 - travel * (0.12 + heat * 0.07)
                pixel(x, y, 3 + travel * 5, 2 + travel * 3,
                      Color.primary.opacity(0.55 * (1 - travel)))
                pixel(x - 0.008, y - 0.015, 2 + travel * 2, 1,
                      Color.primary.opacity(0.28 * (1 - travel)))
            }
        }
        if snapshot.moving {
            drawExposedWheelHighlights(context: context, size: size, phase: phase)
            for index in 0..<4 {
                let x = 0.22 + Double(index) * 0.18 - Double(phase) * 0.014
                pixel(x, 0.968, 7, 1, Color.gray.opacity(0.38))
            }
        }
        if snapshot.running, let heat = snapshot.thermalLevel, heat > 0 {
            // Cosmetic warmth, never a fan, fault, smoke sensor or fire warning.
            let warmth = Double(heat) / 8
            let color = Color(red: 0.67 + 0.14 * warmth, green: 0.64,
                              blue: 0.64 - 0.14 * warmth).opacity(0.12 + 0.18 * warmth)
            for index in 0..<(1 + heat / 3) {
                let x = 0.46 + Double(index) * 0.043 + Double(phase % 2) * 0.006
                pixel(x, 0.52 - Double((index + phase) % 4) * 0.026, 1, 2, color.opacity(0.55))
            }
        }
    }

    private func drawExposedWheelHighlights(context: GraphicsContext, size: CGSize, phase: Int) {
        // The 1774 × 887 sprite has rear/front rim centres near (0.190, 0.700)
        // and (0.812, 0.713), with red rim radius ≈ 0.095 of its width.
        // Clip to the exposed lower/outer arcs. In particular the rear mask
        // excludes the muffler and the front mask excludes the fender/fork.
        var rear = Path()
        rear.addRect(CGRect(x: size.width * 0.07, y: size.height * 0.54,
                            width: size.width * 0.09, height: size.height * 0.30))
        rear.addRect(CGRect(x: size.width * 0.12, y: size.height * 0.78,
                            width: size.width * 0.17, height: size.height * 0.14))
        var front = Path()
        front.addRect(CGRect(x: size.width * 0.71, y: size.height * 0.70,
                             width: size.width * 0.20, height: size.height * 0.23))
        front.addRect(CGRect(x: size.width * 0.85, y: size.height * 0.59,
                             width: size.width * 0.07, height: size.height * 0.16))
        let wheels: [(CGFloat, CGFloat, Path)] = [(0.190, 0.700, rear), (0.812, 0.713, front)]
        for (x, y, mask) in wheels {
            var clipped = context
            clipped.clip(to: mask)
            for offset in [0.0, 180.0] {
                let angle = Double(phase) * 22.5 + offset
                var arc = Path()
                arc.addArc(center: CGPoint(x: x * size.width, y: y * size.height),
                           radius: size.width * 0.095,
                           startAngle: .degrees(angle), endAngle: .degrees(angle + 36),
                           clockwise: false)
                clipped.stroke(arc, with: .color(MotoTheme.accent.opacity(0.86)),
                               lineWidth: max(1, size.width / 110))
            }
        }
    }

    private func drawWind(context: GraphicsContext, size: CGSize, phase: Int) {
        // Speed lines sit behind the existing sprite. Only a fresh, decoded
        // wheel speed ≥160 km/h can activate them; no wind sensor is claimed.
        for index in 0..<4 {
            let travel = CGFloat((phase + index * 2) % 8) / 8
            let x = size.width * (0.015 + travel * 0.075)
            let y = size.height * (0.24 + CGFloat(index) * 0.145)
            var stroke = Path()
            stroke.move(to: CGPoint(x: x, y: y))
            stroke.addLine(to: CGPoint(x: x + size.width * (0.12 + CGFloat(index) * 0.016),
                                       y: y - size.height * 0.006))
            context.stroke(stroke, with: .color(MotoTheme.accent.opacity(0.33)),
                           lineWidth: max(1, size.width / 220))
        }
    }
}
