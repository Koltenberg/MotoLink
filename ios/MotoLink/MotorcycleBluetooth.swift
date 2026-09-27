import Combine
import CoreBluetooth
import Foundation
import UIKit

struct NearbyMotorcycle: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// CoreBluetooth delegates run on the main queue. Background operation relies
/// on the system's pending connection/restoration, never a background timer.
final class MotorcycleBluetooth: NSObject, ObservableObject {
    @Published private(set) var nearby: [NearbyMotorcycle] = []
    @Published private(set) var events: [DiagnosticEvent] = []
    @Published private(set) var status = "Проверка Bluetooth…"
    @Published private(set) var bluetoothPowered = false
    @Published private(set) var scanning = false
    @Published private(set) var scanStartedAt: Date?
    @Published private(set) var scanDeadline: Date?
    @Published private(set) var scanFoundNothing = false
    @Published private(set) var connectionPaused: Bool
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var autoReconnect: Bool
    @Published private(set) var selectedName: String
    @Published private(set) var hasRememberedDevice: Bool
    @Published private(set) var packetCount = 0
    @Published private(set) var lastPacketAt: Date?
    @Published private(set) var lastStreamAt: Date?
    @Published private(set) var connectionRequestedAt: Date?
    private var connectionWaitOrigin = "none"
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var reconnectBlockedReason: String?
    private var reconnectPolicy = BLEReconnectPolicy()
    private var reconnectScheduler = BLEReconnectScheduler()
    private var reconnectTask: DispatchWorkItem?
    private var streamRecovery = BLEStreamRecoveryPolicy()
    private var transportRecoveryError: Error?
    private var lastPacketPeripheralID: UUID?
    private var lastRSSIRequestAt: Date?
    private var rssiPending = false
    private var lastRSSI: Int?
    private var lastRSSIAt: Date?
    private var userRescanAfterCancellation: CBPeripheral?
    private var userRescanMayStartScan = false
    private var cancelResume = BLECancelResumePolicy()
    private var nativeReconnect = BLENativeReconnectPolicy()
    private var nativeDisconnectLogged = false
    @Published private(set) var storageError: String?
    @Published private(set) var exportBusy = false
    @Published var exportedFiles: SharedFiles?

    @Published private(set) var capabilities: [MotoProtocol.Capability] = []
    private var telemetryPresentation = TelemetryPresentation()
    @Published private(set) var dashboardTelemetry = TelemetryPresentation()
    private var telemetryPeripheralID: UUID?
    private var lastDashboardPublication: TimeInterval?
    var measurements: [MotoProtocol.Measurement] { telemetryPresentation.measurements }
    @Published private(set) var diagnosticRunning = false
    @Published private(set) var diagnosticStatus = "Готов к полной проверке"
    @Published private(set) var streamPackets = 0
    var onMeasurements: (([MotoProtocol.Measurement]) -> Void)?
    var onStreamFrame: ((Date) -> Void)?
    /// Synchronous ride creation before capture commands, independent of any scene.
    var onReadyForCapture: (() -> Void)?
    var onTransportIdentity: ((UUID) -> Void)?
    var onConfirmedTransportBoundary: ((UUID) -> Void)?
    private var captureProfileSession: UUID?
    private var captureProfileRequested = false
    private var scanGeneration = UUID()

    private var diagnosticPhase = 0
    private var decodedStreamFrames = 0
    private var observationTimeout: DispatchWorkItem?
    private var queryRetries: [UInt8: Int] = [:]

    private enum Key {
        static let identifier = "MotoLink.peripheralIdentifier"
        static let name = "MotoLink.peripheralName"
        static let reconnect = "MotoLink.autoReconnect"
        static let paused = "MotoLink.connectionPaused"
        static let verifiedDevices = "MotoLink.verifiedBLE5Devices"
    }

    private var central: CBCentralManager!
    // CoreBluetooth delegate is weak. Keep the OS-specific adapter alive, and
    // expose exactly one disconnect selector for that OS (Nordic issue #132).
    private var centralDelegate: MotoCentralDelegate!
    private var found: [UUID: CBPeripheral] = [:]
    private var current: CBPeripheral?
    private var savedID: UUID?
    private var connectionWanted = false
    private var shouldResumeAtPowerOn = false
    private var terminalStatus: String?
    private var control: CBCharacteristic?
    private var notifications: [String: CBCharacteristic] = [:]
    private var subscribed: Set<String> = []
    private var pendingNotification: String?
    private var session = UUID()
    private var scanTimeout: DispatchWorkItem?
    private var setupTimeout: DispatchWorkItem?
    private var writeTimeout: DispatchWorkItem?
    private var responseTimeout: DispatchWorkItem?
    private var pendingWrites: [(command: UInt8, frame: Data)] = []
    private var lastSlowQueryAt: [UInt8: Date] = [:]
    private var activeWrite: (command: UInt8, frame: Data)?
    private var optionalStreamRearmInProgress = false
    private var rearmWriteDeferralLogged = false
    private var writeConfirmed = false
    private var responseReceived = false
    private var rejectedResponse = false
    private var logStore: SessionLogStore?
    var onDiagnosticEvent: ((DiagnosticEvent) -> Void)?

    override init() {
        let defaults = UserDefaults.standard
        let rememberedID = defaults.string(forKey: Key.identifier).flatMap(UUID.init(uuidString:))
        let reconnect = defaults.bool(forKey: Key.reconnect)
        savedID = rememberedID
        hasRememberedDevice = rememberedID != nil
        selectedName = defaults.string(forKey: Key.name) ?? "Мотоцикл не выбран"
        autoReconnect = reconnect
        connectionPaused = defaults.bool(forKey: Key.paused)
        shouldResumeAtPowerOn = reconnect && !defaults.bool(forKey: Key.paused)
        super.init()
        do {
            logStore = try SessionLogStore()
            logStore?.onError = { [weak self] message in self?.storageError = message }
        } catch {
            storageError = error.localizedDescription
        }
        record("app", "MotoLink \(AppBuild.version) (\(AppBuild.number)) · iOS \(UIDevice.current.systemVersion)")
        if #available(iOS 17.0, *) { centralDelegate = MotoModernCentralDelegate(self) }
        else { centralDelegate = MotoLegacyCentralDelegate(self) }
        #if targetEnvironment(simulator)
        validateCentralDelegateSelectors()
        #endif
        central = CBCentralManager(delegate: centralDelegate, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "app.motolink.central.v1",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        scanTimeout?.cancel()
        setupTimeout?.cancel()
        writeTimeout?.cancel()
        responseTimeout?.cancel()
        observationTimeout?.cancel()
        reconnectTask?.cancel()
    }

    func scan() {
        guard bluetoothPowered, current == nil, UIApplication.shared.applicationState == .active else { return }
        stopScan()
        found.removeAll()
        nearby.removeAll()
        terminalStatus = nil
        scanFoundNothing = false
        scanStartedAt = Date()
        scanDeadline = scanStartedAt?.addingTimeInterval(25)
        scanning = true
        status = "Поиск мотоцикла поблизости…"
        // Foreground discovery includes devices omitting UUIDs in advertising.
        // The list is restricted to Kawasaki names or the observed service UUID.
        central.scanForPeripherals(withServices: nil, options: nil)
        record("scan", "Начат поиск; выберите свой мотоцикл в списке")
        let expectedScan = scanGeneration
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.scanning, self.scanGeneration == expectedScan else { return }
            self.stopScan()
            self.scanFoundNothing = self.nearby.isEmpty
            self.status = self.nearby.isEmpty
                ? "Мотоцикл не найден. Включите зажигание и Bluetooth на приборке, затем повторите поиск."
                : "Поиск завершён. Выберите свой мотоцикл."
        }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
    }

    func stopScan() {
        let wasScanning = scanning
        scanGeneration = UUID()
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()
        scanning = false
        scanStartedAt = nil
        scanDeadline = nil
        if wasScanning { status = nearby.isEmpty ? "Поиск остановлен" : "Выберите свой мотоцикл" }
    }

    func scanProgress(at date: Date) -> String {
        guard scanning, let scanDeadline else { return status }
        let remaining = max(0, min(25, Int(ceil(scanDeadline.timeIntervalSince(date)))))
        return nearby.isEmpty ? "Ищем рядом · ещё \(remaining) с"
            : "Найдено: \(nearby.count) · ещё \(remaining) с"
    }

    private func resumeConnectionIntent() {
        connectionPaused = false
        scanFoundNothing = false
        shouldResumeAtPowerOn = autoReconnect
        UserDefaults.standard.set(false, forKey: Key.paused)
    }

    func connect(to identifier: UUID, automaticallyReconnect: Bool? = nil) {
        guard bluetoothPowered, current == nil, let peripheral = found[identifier] else { return }
        BLEDiscoverySelection.connect(identifier, automaticallyReconnect: automaticallyReconnect,
            currentPreference: autoReconnect, commit: { selectedID, enabled in
                savedID = selectedID
                selectedName = nearby.first(where: { $0.id == selectedID })?.name ?? peripheral.name ?? "Kawasaki"
                hasRememberedDevice = true
                autoReconnect = enabled
                UserDefaults.standard.set(selectedID.uuidString, forKey: Key.identifier)
                UserDefaults.standard.set(selectedName, forKey: Key.name)
                UserDefaults.standard.set(enabled, forKey: Key.reconnect)
                resumeConnectionIntent()
                resetRecovery()
            }, issue: { _ in
                beginConnection(peripheral)
            })
    }

    func connectRemembered() {
        guard bluetoothPowered, let savedID else { return }
        if let current {
            guard current.identifier == savedID,
                  cancelResume.requestedResume(for: current.identifier) else { return }
            resumeConnectionIntent()
            userRescanMayStartScan = false
            status = "Подключимся после завершения отмены…"
            record("connection_resume_queued", "Новое подключение запрошено пользователем; ждём завершения предыдущей отмены")
            // Do not set connectionWanted yet. A racing didConnect still belongs
            // to the closing request and must be cancelled, not prepared.
            return
        }
        resumeConnectionIntent()
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [savedID]).first else {
            status = "Сохранённый мотоцикл не найден в iOS. Повторите поиск."
            return
        }
        resetRecovery()
        beginConnection(peripheral)
    }

    /// A UI affordance for a stopped rider, not a deadline on iOS's pending request.
    func canRequestUserRescan(at now: Date) -> Bool {
        guard UIApplication.shared.applicationState == .active, bluetoothPowered,
              connecting, !connected, !ready, connectionWanted,
              reconnectScheduler.pending == nil, userRescanAfterCancellation == nil,
              !reconnectPolicy.transportRestartPending,
              !nativeReconnect.awaitingCancellation,
              current?.state == .connecting || nativeReconnect.systemOwnsPendingConnection,
              let connectionRequestedAt else { return false }
        let wait = now.timeIntervalSince(connectionRequestedAt)
        return wait.isFinite && wait >= 120
    }

    /// Cancel exactly this pending request; discovery begins only after iOS confirms closure.
    /// The caller presents this as an explicit action to use after stopping the motorcycle.
    func requestUserRescan() {
        let now = Date()
        guard canRequestUserRescan(at: now), let current else { return }
        let waited = Int(now.timeIntervalSince(connectionRequestedAt ?? now))
        resetRecovery()
        userRescanAfterCancellation = current
        userRescanMayStartScan = true
        cancelResume.requestedCancellation(for: current.identifier)
        connectionWanted = false
        terminalStatus = "Ожидание остановлено. Повторите поиск, когда будете готовы."
        clearTransport()
        status = "Останавливаем ожидание перед новым поиском…"
        record("user_rescan_requested", "waitSeconds=\(waited); waitOrigin=\(connectionWaitOrigin); autoReconnect=\(autoReconnect); ожидаем подтверждение отмены от iOS")
        // Keep current's identity until a terminal callback. A racing didConnect
        // sees connectionWanted=false and cancels instead of preparing telemetry.
        nativeReconnect.cancellationRequested()
        central.cancelPeripheralConnection(current)
    }

    private func completeUserRescanCancellation(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        guard let requested = userRescanAfterCancellation, requested === peripheral else { return false }
        let resumeRemembered = cancelResume.completedCancellation(for: peripheral.identifier,
            canResume: bluetoothPowered && !connectionPaused)
        let startScan = userRescanMayStartScan
            && !resumeRemembered && UIApplication.shared.applicationState == .active && bluetoothPowered
        resetRecovery()
        clearTransport()
        nativeReconnect.clearConnection()
        current = nil
        connecting = false
        connected = false
        connectionWanted = false
        connectionRequestedAt = nil
        terminalStatus = nil
        record("user_rescan_cancelled", "scanNow=\(startScan); \(Self.errorDetails(error))")
        if resumeRemembered {
            connectRemembered()
        } else if startScan {
            scan()
        } else {
            status = "Ожидание остановлено. Повторите поиск, когда будете готовы."
        }
        return true
    }

    func setAutoReconnect(_ enabled: Bool) {
        guard !enabled || hasRememberedDevice else { return }
        if !enabled {
            resetRecovery()
            cancelResume.revokeResume()
        }
        autoReconnect = enabled
        shouldResumeAtPowerOn = enabled
        UserDefaults.standard.set(enabled, forKey: Key.reconnect)
        if enabled { resumeConnectionIntent() }
        record("setting", "Автоподключение: \(enabled ? "включено" : "выключено")")
        if enabled, bluetoothPowered {
            connectRemembered()
        } else if !enabled, connecting || nativeReconnect.systemOwnsPendingConnection, let current {
            connectionWanted = false
            terminalStatus = "Ожидание подключения остановлено"
            if current.state == .disconnected && !nativeReconnect.systemOwnsPendingConnection
                && !nativeReconnect.awaitingCancellation {
                // A cooldown has no OS request and therefore no disconnect
                // callback to release the selected peripheral for a new scan.
                clearTransport()
                cancelResume.reset()
                nativeReconnect.clearConnection()
                self.current = nil
                connecting = false
                status = terminalStatus!
            } else {
                cancelResume.requestedCancellation(for: current.identifier)
                nativeReconnect.cancellationRequested()
                central.cancelPeripheralConnection(current)
            }
        }
    }

    func stop() {
        autoReconnect = false
        UserDefaults.standard.set(false, forKey: Key.reconnect)
        pauseConnection()
    }

    /// An explicit pause retains preferences. Only a new user connection or
    /// enabling auto-connect resumes it; radio cycling/restoration cannot undo it.
    func pauseConnection() {
        resetRecovery()
        cancelResume.revokeResume()
        connectionPaused = true
        shouldResumeAtPowerOn = false
        UserDefaults.standard.set(true, forKey: Key.paused)
        connectionWanted = false
        terminalStatus = "Подключение приостановлено"
        stopScan()
        clearTransport()
        if let current {
            if current.state == .disconnected && !nativeReconnect.systemOwnsPendingConnection
                && !nativeReconnect.awaitingCancellation {
                cancelResume.reset()
                nativeReconnect.clearConnection()
                self.current = nil
            } else {
                cancelResume.requestedCancellation(for: current.identifier)
                nativeReconnect.cancellationRequested()
                central.cancelPeripheralConnection(current)
            }
        } else {
            cancelResume.reset()
            nativeReconnect.clearConnection()
        }
        connecting = false
        connected = false
        status = "Подключение приостановлено"
        record("connection", "Подключение приостановлено пользователем; очередь запросов очищена; autoReconnect=\(autoReconnect)")
    }

    /// Bounded, source-derived queries and the telemetry session profile.
    /// No arbitrary writer, maintenance reset, time sync, firmware or meter commands.
    func request(_ commands: [UInt8]) {
        guard ready, !busy, !commands.isEmpty else { return }
        let frames = commands.compactMap { command -> (command: UInt8, frame: Data)? in
            guard let data = MotoProtocol.request(command) else { return nil }
            return (command, data)
        }
        guard frames.count == commands.count else {
            record("error", "Запрос отклонён: команда вне разрешённого списка")
            return
        }
        pendingWrites = frames
        busy = true
        sendNext()
    }

    func refreshSlowMeasurements() {
        guard ready, !busy, !diagnosticRunning else { return }
        let temperatureIDs: Set<String> = ["engine_water_temperature", "inlet_air_temperature"]
        let commands = SlowTelemetryPolling.commands(now: Date(),
            voltageSupported: capabilities.contains { $0.id == "ecu_battery12V" && $0.supported },
            temperatureSupported: capabilities.contains { temperatureIDs.contains($0.id) && $0.supported },
            lastVoltageAt: measurements.first { $0.id == "ecu_battery12V" }?.timestamp,
            lastTemperatureAt: measurements.filter { temperatureIDs.contains($0.id) }.map(\.timestamp).max(),
            lastStatusRequestAt: lastSlowQueryAt[0x41], lastTemperatureRequestAt: lastSlowQueryAt[0x45])
        if !commands.isEmpty { request(commands) }
    }

    func startCaptureProfileIfNeeded() {
        guard ready, captureProfileSession != session else { return }
        captureProfileRequested = true
        runFullDiagnostic()
    }

    func runFullDiagnostic() {
        guard ready, !busy, !diagnosticRunning else { return }
        captureProfileSession = session
        captureProfileRequested = false
        diagnosticRunning = true
        diagnosticPhase = 1
        streamPackets = 0
        decodedStreamFrames = 0
        queryRetries = [:]
        diagnosticStatus = "Проверка 1/2: данные и запуск потока"
        record("diagnostic_start", "Автопроверка: запросы, профиль потока, один резервный путь при отсутствии 4A")
        UserDefaults.standard.set(true, forKey: "MotoLink.resumeTelemetry")
        request([0x03, 0x40, 0x41, 0x45, 0x1A, 0x1D, 0x47, 0x08, 0x45])
    }

    private func observeDiagnostic() {
        guard diagnosticRunning else { return }
        diagnosticStatus = "Слушаем поток 15 секунд…"
        let expected = session
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.session == expected, self.diagnosticRunning else { return }
            if self.streamPackets == 0, self.diagnosticPhase == 1 {
                self.diagnosticPhase = 2
                self.diagnosticStatus = "Проверка 2/2: полный профиль совместимости"
                self.record("fallback", "Структурно полный 4A не получен. Один полный профиль, включая имя телефона MotoLink; время и настройки приборки не изменяются.")
                self.request([0x03, 0x40, 0x1A, 0x1D, 0x47, 0x0B, 0x41, 0x1B, 0x48, 0x1E, 0x08, 0x45])
            } else {
                self.diagnosticRunning = false
                if self.decodedStreamFrames > 0 {
                    self.diagnosticStatus = "Поток получен. Экспериментальные значения отмечены."
                } else if self.streamPackets > 0 {
                    self.diagnosticStatus = "Пакеты 4A есть, но формат значений не распознан. Журнал сохранён."
                } else {
                    self.diagnosticStatus = "Проверка завершена. Поток 4A не получен; все ответы и ошибки в журнале."
                }
                self.record("diagnostic_end", self.diagnosticStatus)
            }
        }
        observationTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
    }

    func export() {
        guard !exportBusy, let logStore else {
            storageError = storageError ?? "Журнал недоступен"
            return
        }
        exportBusy = true
        logStore.export { [weak self] result in
            guard let self else { return }
            self.exportBusy = false
            switch result {
            case .success(let files): self.exportedFiles = SharedFiles(urls: files)
            case .failure(let error): self.storageError = error.localizedDescription
            }
        }
    }

    /// Called by the existing low-frequency capture timer; this is diagnostic
    /// observation, not a background keepalive or a reconnect deadline.
    func recordHealthSnapshot() {
        resumeScheduledReconnect()
        let now = Date()
        let packetAge = lastPacketAt.map { Int(max(0, now.timeIntervalSince($0))) } ?? -1
        let streamAge = lastStreamAt.map { Int(max(0, now.timeIntervalSince($0))) } ?? -1
        let rssiAge = lastRSSIAt.map { Int(max(0, now.timeIntervalSince($0))) } ?? -1
        let rssiValue = lastRSSI.map { String($0) } ?? "unavailable"
        let waiting = connecting ? connectionRequestedAt.map { Int(max(0, now.timeIntervalSince($0))) } ?? -1 : 0
        let cooldown = reconnectScheduler.pending.flatMap {
            reconnectScheduler.remaining(for: $0, now: ProcessInfo.processInfo.systemUptime)
        }.map { Int(ceil($0)) } ?? 0
        record("ble_health", "connected=\(connected); ready=\(ready); connecting=\(connecting); waitSeconds=\(waiting); waitOrigin=\(connecting ? connectionWaitOrigin : "none"); packetAgeSeconds=\(packetAge); streamAgeSeconds=\(streamAge); peripheralState=\(current?.state.rawValue ?? -1); reconnectAttempt=\(reconnectAttempt); retryCooldownSeconds=\(cooldown); systemReconnectPending=\(nativeReconnect.systemOwnsPendingConnection); cancelPending=\(nativeReconnect.awaitingCancellation); appState=\(UIApplication.shared.applicationState.rawValue); centralState=\(central.state.rawValue); protectedDataAvailable=\(UIApplication.shared.isProtectedDataAvailable); lastRSSIdBm=\(rssiValue); rssiAgeSeconds=\(rssiAge)")
        checkStreamRecovery()
        // One local RSSI read per minute, only while visible and between commands.
        if UIApplication.shared.applicationState == .active, ready, !busy,
           !diagnosticRunning, !rssiPending, let current, isCurrent(current),
           lastRSSIRequestAt == nil || now.timeIntervalSince(lastRSSIRequestAt!) >= 60 {
            lastRSSIRequestAt = now
            rssiPending = true
            current.readRSSI()
        }
    }

    private static func errorDetails(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "error=none" }
        return "domain=\(error.domain); code=\(error.code); message=\(error.localizedDescription)"
    }

    /// Passive evidence at an accepted disconnect, before clearing GATT ages.
    /// Never call recordHealthSnapshot here: it also runs recovery/RSSI work.
    private func recordDisconnectContext(_ error: Error?) {
        let now = Date()
        func age(_ date: Date?) -> String {
            guard let date else { return "unavailable" }
            let seconds = now.timeIntervalSince(date)
            guard seconds.isFinite, seconds >= 0 else { return "clock_changed" }
            return String(format: "%.3f", seconds)
        }
        let rssi = lastRSSI.map(String.init) ?? "unavailable"
        record("ble_disconnect_context", "connected=\(connected); ready=\(ready); busy=\(busy); diagnosticRunning=\(diagnosticRunning); lastRSSIdBm=\(rssi); rssiAgeSeconds=\(age(lastRSSIAt)); packetAgeSeconds=\(age(lastPacketAt)); streamAgeSeconds=\(age(lastStreamAt)); peripheralState=\(current?.state.rawValue ?? -1); systemReconnectPending=\(nativeReconnect.systemOwnsPendingConnection); cancelPending=\(nativeReconnect.awaitingCancellation); transportRestartPending=\(reconnectPolicy.transportRestartPending); appState=\(UIApplication.shared.applicationState.rawValue); protectedDataAvailable=\(UIApplication.shared.isProtectedDataAvailable); \(Self.errorDetails(error))")
    }

    @objc private func enteredBackground() {
        // A foreground request must not turn into a delayed background scan.
        userRescanMayStartScan = false
        if scanning {
            stopScan()
            status = "Поиск приостановлен. Откройте приложение для выбора мотоцикла."
        }
    }

    private func resetRecovery() {
        userRescanAfterCancellation = nil
        userRescanMayStartScan = false
        cancelScheduledReconnect()
        reconnectPolicy.reset()
        transportRecoveryError = nil
        reconnectAttempt = 0
        reconnectBlockedReason = nil
    }

    @objc private func becameActive() {
        // An opportunity to check an existing session, not a background timer.
        resumeScheduledReconnect()
        checkStreamRecovery()
    }

    private func checkStreamRecovery() {
        let eligible = autoReconnect && connectionWanted && ready && !busy && !diagnosticRunning
            && UserDefaults.standard.bool(forKey: "MotoLink.resumeTelemetry")
            && current.map(isCurrent) == true
        guard let action = streamRecovery.nextAction(at: ProcessInfo.processInfo.systemUptime,
                                                      eligible: eligible) else { return }
        switch action {
        case .rearmStream:
            record("stream_recovery", "Нет структурно корректного 4A не менее 45 секунд. Один повтор известного профиля 08; соединение сохраняется.")
            optionalStreamRearmInProgress = true
            rearmWriteDeferralLogged = false
            request([0x08])
        case .preserveActiveLink:
            record("stream_stalled_link_alive", "4A пока не вернулся, но другие корректные пакеты поступают. Сохраняем соединение: повторное обнаружение мотоцикла в движении может быть недоступно.")
        case .restartTransport:
            failSetup("Поток 4A не восстановился и все корректные пакеты отсутствуют не менее 30 секунд; восстанавливаем канал", retry: true)
        }
    }

    private func previouslyVerified(_ peripheral: CBPeripheral) -> Bool {
        UserDefaults.standard.stringArray(forKey: Key.verifiedDevices)?.contains(peripheral.identifier.uuidString) == true
    }

    private func rememberVerified(_ peripheral: CBPeripheral) {
        var identifiers = UserDefaults.standard.stringArray(forKey: Key.verifiedDevices) ?? []
        guard !identifiers.contains(peripheral.identifier.uuidString) else { return }
        identifiers.append(peripheral.identifier.uuidString)
        UserDefaults.standard.set(identifiers, forKey: Key.verifiedDevices)
    }

    /// Retry completed failures, not an OS connection which is still pending.
    /// An app-side deadline also bounds immediate CoreBluetooth failures.
    private func recoverConnection(_ peripheral: CBPeripheral, error: Error?, wanted: Bool) {
        let nsError = error as NSError?
        let removedPairing = nsError?.domain == CBErrorDomain
            && nsError?.code == CBError.Code.peerRemovedPairingInformation.rawValue
        let pairingLimit = nsError?.domain == CBErrorDomain
            && nsError?.code == CBError.Code.tooManyLEPairedDevices.rawValue
        let cancelled = nsError?.domain == CBErrorDomain
            && nsError?.code == CBError.Code.operationCancelled.rawValue
        let allowed = wanted && autoReconnect && bluetoothPowered
        if allowed && (removedPairing || pairingLimit) {
            reconnectBlockedReason = removedPairing
                ? "iOS сообщает, что сопряжение удалено. На остановке проверь сопряжение в настройках Bluetooth и подключись снова."
                : "iOS сообщает о лимите сопряжённых устройств. На остановке проверь настройки Bluetooth."
            status = reconnectBlockedReason!
            record("reconnect_blocked", "\(status); \(Self.errorDetails(error))")
        }
        guard let delay = reconnectPolicy.nextDelay(allowed: allowed,
            requiresPairing: removedPairing || pairingLimit, cancelled: cancelled) else { return }
        reconnectAttempt = reconnectPolicy.failureCount
        record("reconnect", "attempt=\(reconnectAttempt); appDelaySeconds=\(Int(delay)); \(Self.errorDetails(error))")
        beginConnection(peripheral, delay: delay)
    }

    private func beginConnection(_ peripheral: CBPeripheral, delay: TimeInterval = 0) {
        cancelResume.reset()
        nativeReconnect.clearConnection()
        nativeDisconnectLogged = false
        onTransportIdentity?(peripheral.identifier)
        stopScan()
        selectTelemetryCatalogue(for: peripheral.identifier)
        clearTransport()
        transportRecoveryError = nil
        terminalStatus = nil
        current = peripheral
        peripheral.delegate = self
        connectionWanted = true
        connecting = true
        connected = false
        packetCount = 0
        // Preserve the last receive time across reconnection to the same bike.
        if lastPacketPeripheralID != peripheral.identifier {
            lastRSSI = nil
            lastRSSIAt = nil
            lastPacketAt = nil
            lastPacketPeripheralID = peripheral.identifier
        }
        lastStreamAt = nil
        connectionRequestedAt = nil
        reconnectPolicy.connectionStarted()
        status = delay > 0 ? "Повтор подключения через \(Int(delay)) сек…" : "Ожидание \(selectedName)…"
        guard reconnectScheduler.schedule(after: delay, now: ProcessInfo.processInfo.systemUptime) != nil else {
            connecting = false
            connectionWanted = false
            current = nil
            record("error", "Не удалось запланировать повтор подключения: неверный интервал")
            return
        }
        resumeScheduledReconnect()
    }

    private func cancelScheduledReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectScheduler.cancel()
    }

    /// A timer may be suspended in the background. BLE/health/foreground events
    /// also visit this deadline, and the ticket can only be consumed once.
    private func resumeScheduledReconnect() {
        guard let ticket = reconnectScheduler.pending, let current,
              connectionWanted, bluetoothPowered,
              !nativeReconnect.systemOwnsPendingConnection, !nativeReconnect.awaitingCancellation,
              let remaining = reconnectScheduler.remaining(for: ticket,
                    now: ProcessInfo.processInfo.systemUptime) else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        if remaining > 0 {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.reconnectScheduler.pending == ticket else { return }
                self.resumeScheduledReconnect()
            }
            reconnectTask = item
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
            return
        }
        guard reconnectScheduler.consume(ticket, now: ProcessInfo.processInfo.systemUptime) else { return }
        connectionRequestedAt = Date()
        connectionWaitOrigin = "request"
        status = "Ожидание \(selectedName)…"
        record("connection", "Запрошено подключение к \(selectedName); id=\(current.identifier.uuidString)")
        // Do not delegate the cooldown to CBConnectPeripheralOptionStartDelayKey:
        // Real iOS 26.6.2 rides received invalidParameters immediately on
        // requests using this option; the callback does not identify which
        // parameter was rejected. Regardless of cause, the app must rate-limit.
        // Once this request is issued, no deadline cancels it: iOS owns the wait.
        issueConnectionRequest(current)
    }

    private func issueConnectionRequest(_ peripheral: CBPeripheral) {
        let supported: Bool
        if #available(iOS 17.0, *) { supported = true } else { supported = false }
        let enabled = nativeReconnect.connectionRequested(for: peripheral.identifier,
            supported: supported, enabled: autoReconnect && !connectionPaused)
        if #available(iOS 17.0, *), enabled {
            record("native_reconnect", "Системное восстановление iOS включено для этого запроса; параметры радиосвязи не меняются")
            central.connect(peripheral, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    #if targetEnvironment(simulator)
    private func validateCentralDelegateSelectors() {
        let legacy = NSSelectorFromString("centralManager:didDisconnectPeripheral:error:")
        let modern = NSSelectorFromString("centralManager:didDisconnectPeripheral:timestamp:isReconnecting:error:")
        if #available(iOS 17.0, *) {
            precondition(centralDelegate.responds(to: modern) && !centralDelegate.responds(to: legacy),
                         "Modern CoreBluetooth adapter must expose only the timestamp disconnect selector")
        } else {
            precondition(centralDelegate.responds(to: legacy) && !centralDelegate.responds(to: modern),
                         "Legacy CoreBluetooth adapter must expose only the old disconnect selector")
        }
        print("MotoLink CoreBluetooth delegate selector check passed")
    }
    #endif

    private func prepare(_ peripheral: CBPeripheral) {
        nativeDisconnectLogged = false
        onTransportIdentity?(peripheral.identifier)
        selectTelemetryCatalogue(for: peripheral.identifier)
        clearTransport()
        connected = true
        connecting = false
        connectionRequestedAt = nil
        status = "Bluetooth подключён. Проверка каналов…"
        peripheral.delegate = self
        record("setup", "Поиск сервиса Kawasaki; attempt=\(reconnectAttempt)")
        peripheral.discoverServices([CBUUID(string: MotoProtocol.service)])
        let expectedSession = session
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session == expectedSession, !self.ready else { return }
            self.failSetup("Мотоцикл не подтвердил каналы за 60 секунд", retry: true)
        }
        setupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    private func selectTelemetryCatalogue(for identifier: UUID) {
        guard telemetryPeripheralID != identifier else { return }
        telemetryPeripheralID = identifier
        telemetryPresentation = TelemetryPresentation()
        publishTelemetry(force: true)
    }

    private func publishTelemetry(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        // Two readable display updates per second; every packet is still
        // decoded, journalled and passed to onMeasurements without this limit.
        guard force || lastDashboardPublication == nil || now - lastDashboardPublication! >= 0.5 else { return }
        lastDashboardPublication = now
        dashboardTelemetry = telemetryPresentation
    }

    private func clearTransport() {
        cancelScheduledReconnect()
        session = UUID()
        captureProfileRequested = false
        streamRecovery.reset()
        lastStreamAt = nil
        rssiPending = false
        lastRSSIRequestAt = nil
        setupTimeout?.cancel()
        setupTimeout = nil
        writeTimeout?.cancel()
        writeTimeout = nil
        responseTimeout?.cancel()
        responseTimeout = nil
        observationTimeout?.cancel()
        observationTimeout = nil
        if diagnosticRunning { diagnosticStatus = "Проверка прервана; журнал сохранён" }
        diagnosticRunning = false
        capabilities = []
        telemetryPresentation.invalidateReadings()
        publishTelemetry(force: true)
        pendingWrites.removeAll()
        lastSlowQueryAt.removeAll()
        activeWrite = nil
        optionalStreamRearmInProgress = false
        rearmWriteDeferralLogged = false
        writeConfirmed = false
        responseReceived = false
        rejectedResponse = false
        busy = false
        ready = false
        control = nil
        notifications.removeAll()
        subscribed.removeAll()
        pendingNotification = nil
    }

    private func failSetup(_ message: String, error: Error? = nil, retry: Bool = false) {
        guard !reconnectPolicy.transportRestartPending else { return }
        record("error", "\(message); \(Self.errorDetails(error))")
        terminalStatus = message
        let recover = retry && connectionWanted && autoReconnect && bluetoothPowered
        if recover {
            reconnectPolicy.requestTransportRestart()
            transportRecoveryError = error
            record("transport_restart", "Закрываем неисправный канал; повторное подключение после подтверждения iOS. \(message)")
        } else {
            connectionWanted = false
        }
        clearTransport()
        status = recover ? "Канал прервался. Восстанавливаем связь…" : message
        // Keep this peripheral until didDisconnect. Never overlap connect and
        // cancel, and ignore late GATT callbacks from the closing session.
        if let current {
            nativeReconnect.cancellationRequested()
            central.cancelPeripheralConnection(current)
        }
    }

    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        current === peripheral && connectionWanted && !reconnectPolicy.transportRestartPending
            && peripheral.state == .connected
    }

    private func sendNext() {
        guard ready, let current, current.state == .connected, let control else {
            pendingWrites.removeAll()
            activeWrite = nil
            optionalStreamRearmInProgress = false
            rearmWriteDeferralLogged = false
            busy = false
            return
        }
        guard activeWrite == nil else { return }
        guard !pendingWrites.isEmpty else {
            busy = false
            status = "Запросы переданы. Ответы — в журнале."
            if captureProfileRequested { startCaptureProfileIfNeeded() }
            return
        }
        let write = pendingWrites.removeFirst()
        guard write.frame.count <= current.maximumWriteValueLength(for: .withResponse) else {
            failSetup("Размер запроса превышает доступный размер BLE-записи")
            return
        }
        activeWrite = write
        if write.command == 0x41 || write.command == 0x45 { lastSlowQueryAt[write.command] = Date() }
        // Register response state before writeValue: a notification can reach
        // us before didWriteValueFor confirms the ATT transaction.
        writeConfirmed = false
        responseReceived = false
        rejectedResponse = false
        record("tx", String(format: "Запрос 0x%02X", write.command), characteristic: MotoProtocol.control, data: write.frame)
        current.writeValue(write.frame, for: control, type: .withResponse)
        scheduleWriteTimeout()
    }

    private func scheduleWriteTimeout() {
        let expectedSession = session
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session == expectedSession, self.activeWrite != nil else { return }
            if self.optionalStreamRearmInProgress,
               self.streamRecovery.hasRecentPacket(at: ProcessInfo.processInfo.systemUptime) {
                // The original ATT write is still pending: keep busy/activeWrite
                // intact so its late callback cannot confirm a different command.
                if !self.rearmWriteDeferralLogged {
                    self.rearmWriteDeferralLogged = true
                    self.record("stream_rearm_ack_deferred", "Подтверждение дополнительного 08 задержалось, но корректные пакеты поступают. Сохраняем связь и очередь; повторная проверка через 60 секунд.")
                }
                self.scheduleWriteTimeout()
                return
            }
            self.failSetup("Нет подтверждения BLE-записи за 60 секунд", retry: true)
        }
        writeTimeout = timeout
        // A first write can show the system pairing/PIN dialog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    private func matchesResponse(_ data: Data, command: UInt8) -> Bool {
        let bytes = Array(data)
        if [0x08, 0x0B, 0x1B, 0x48, 0x1E].contains(command) {
            // Init/config query ACK is an outcome, not telemetry. Long ACKs echo
            // payload; byte 7 must not be misread as a rejection status.
            return bytes.count >= 5 && bytes.count == Int(bytes[1]) + 3 && bytes[0] == 0x20 && bytes[3] == command
        }
        return MotoProtocol.validEnvelope(data, command: command)
    }

    private func finishRequest(received: Bool, rejected: Bool = false, failure: String? = nil) {
        guard let write = activeWrite else { return }
        responseTimeout?.cancel()
        responseTimeout = nil
        activeWrite = nil
        optionalStreamRearmInProgress = false
        rearmWriteDeferralLogged = false
        writeConfirmed = false
        responseReceived = false
        rejectedResponse = false
        let command = String(format: "0x%02X", write.command)
        if let failure {
            status = "Дополнительный запрос не выполнен; соединение сохраняется."
            record("request_failed", failure)
        } else if received {
            status = "Ответ \(command) получен. Расшифровка — в журнале."
            record("response", "Получен пакет ответа \(command); значения могут быть недоступны")
        } else {
            status = "Ответа \(command) пока нет. Журнал сохранён."
            record(rejected ? "rejected" : "response_timeout", rejected ? "Мотоцикл отклонил \(command)" : "Ответ \(command) не получен за 8 секунд; продолжаем сбор.")
            if diagnosticRunning, !rejected, [0x03, 0x40, 0x41].contains(write.command),
               queryRetries[write.command, default: 0] == 0 {
                queryRetries[write.command] = 1
                pendingWrites.insert(write, at: 0)
                record("retry", "Однократный повтор \(command)")
            }
        }
        if pendingWrites.isEmpty {
            busy = false
            observeDiagnostic()
            if captureProfileRequested { startCaptureProfileIfNeeded() }
        } else {
            sendNext()
        }
    }

    private func record(_ kind: String, _ detail: String,
                        characteristic: String? = nil, data: Data? = nil) {
        let event = DiagnosticEvent(kind: kind, detail: detail, characteristic: characteristic, data: data)
        events.append(event)
        if events.count > 300 { events.removeFirst(events.count - 300) }
        logStore?.append(event)
        onDiagnosticEvent?(event)
    }
}

// The version-specific adapter owns the Objective-C protocol conformance.
// These are ordinary Swift forwarding targets, not another delegate surface.
extension MotorcycleBluetooth {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothPowered = central.state == .poweredOn
        guard bluetoothPowered else {
            cancelResume.reset()
            nativeReconnect.clearConnection()
            nativeDisconnectLogged = false
            userRescanAfterCancellation = nil
            userRescanMayStartScan = false
            stopScan()
            clearTransport()
            found.removeAll()
            nearby.removeAll()
            current = nil
            connecting = false
            connected = false
            connectionWanted = false
            switch central.state {
            case .poweredOff: status = "Bluetooth выключен"
            case .unauthorized: status = "Разрешите Bluetooth для MotoLink в Настройках"
            case .unsupported: status = "Это устройство не поддерживает Bluetooth LE"
            case .resetting: status = "Bluetooth перезапускается"
            default: status = "Проверка Bluetooth…"
            }
            record("bluetooth", status)
            return
        }
        if let current, connectionWanted {
            if nativeReconnect.awaitingCancellation { return }
            if reconnectScheduler.pending != nil {
                resumeScheduledReconnect()
                return
            }
            if current.state == .connected {
                nativeReconnect.preparedConnectedState(current.identifier)
                prepare(current)
            }
            else if current.state != .connecting && !nativeReconnect.systemOwnsPendingConnection {
                connectionRequestedAt = Date()
                connectionWaitOrigin = "request"
                issueConnectionRequest(current)
            }
            return
        }
        status = "Bluetooth готов"
        if autoReconnect && shouldResumeAtPowerOn && reconnectBlockedReason == nil { connectRemembered() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for peripheral in peripherals {
            guard autoReconnect, !connectionPaused, peripheral.identifier == savedID else {
                central.cancelPeripheralConnection(peripheral)
                continue
            }
            current = peripheral
            peripheral.delegate = self
            nativeReconnect.restored(peripheral.identifier, connecting: peripheral.state == .connecting)
            onTransportIdentity?(peripheral.identifier)
            connectionWanted = true
            connecting = peripheral.state != .connected
            connected = peripheral.state == .connected
            // iOS does not provide the original pending request's start time.
            // Require a fresh 120 seconds of observed waiting before offering rescan.
            connectionRequestedAt = peripheral.state == .connecting ? Date() : nil
            connectionWaitOrigin = peripheral.state == .connecting ? "restored_observation" : "none"
            record("restore_wait", "peripheralState=\(peripheral.state.rawValue); waitOrigin=\(connectionWaitOrigin); originalRequestAge=unknown")
            record("restore", "iOS восстановила соединение; профиль телеметрии возобновится только при включённом автоподключении")
            // didUpdateState starts discovery once CoreBluetooth is powered on.
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rawName = advertisedName ?? peripheral.name
        let name = rawName ?? "Kawasaki (без имени)"
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard rawName?.lowercased().hasPrefix("kawasaki") == true
                || advertised.contains(CBUUID(string: MotoProtocol.advertisedService)) else { return }
        found[peripheral.identifier] = peripheral
        let item = NearbyMotorcycle(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = nearby.firstIndex(where: { $0.id == item.id }) { nearby[index] = item }
        else { nearby.append(item) }
        nearby.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard current === peripheral, connectionWanted,
              !nativeReconnect.awaitingCancellation, !reconnectPolicy.transportRestartPending else {
            if current === peripheral { nativeReconnect.cancellationRequested() }
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard nativeReconnect.connected(peripheral.identifier) else {
            record("native_reconnect_duplicate", "Соединение уже подготовлено по текущему состоянию после отложенного события iOS")
            return
        }
        record("connection", "BLE соединение установлено; телеметрия ещё не подтверждена")
        onConfirmedTransportBoundary?(peripheral.identifier)
        prepare(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard current === peripheral, peripheral.state == .disconnected,
              reconnectScheduler.pending == nil else { return }
        if completeUserRescanCancellation(peripheral, error: error) { return }
        let resumeRemembered = cancelResume.completedCancellation(for: peripheral.identifier,
            canResume: bluetoothPowered && !connectionPaused)
        let wanted = connectionWanted
        let cause = error as NSError?
        if nativeReconnect.rejectOptionIfUsed(invalidParameters: cause?.domain == CBErrorDomain
            && cause?.code == CBError.Code.invalidParameters.rawValue) {
            record("native_reconnect_fallback", "iOS отклонила запрос с новым параметром. В этом процессе следующие запросы без него; ограничение частоты повторов сохраняется")
        }
        let recoveryError = transportRecoveryError ?? error
        transportRecoveryError = nil
        clearTransport()
        nativeReconnect.clearConnection()
        current = nil
        connecting = false
        connected = false
        connectionWanted = false
        status = terminalStatus ?? "Подключение не удалось: \(error?.localizedDescription ?? "причина не указана")"
        record("error", "\(status); \(Self.errorDetails(error))")
        recordHealthSnapshot()
        // An encryption timeout is not evidence that the bond was removed.
        if resumeRemembered { connectRemembered() }
        else { recoverConnection(peripheral, error: recoveryError, wanted: wanted) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard current === peripheral, peripheral.state == .disconnected,
              reconnectScheduler.pending == nil else { return }
        completeDisconnection(peripheral, error: error)
    }

    @available(iOS 17.0, *)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        guard current === peripheral else { return }
        let receivedAt = Date().timeIntervalSinceReferenceDate
        let cause = error as NSError?
        let pairingFailure = cause?.domain == CBErrorDomain &&
            [CBError.Code.peerRemovedPairingInformation.rawValue,
             CBError.Code.tooManyLEPairedDevices.rawValue].contains(cause?.code ?? -1)
        let mayResume = connectionWanted && autoReconnect && bluetoothPowered
            && !connectionPaused && !pairingFailure && !reconnectPolicy.transportRestartPending
        let action = nativeReconnect.disconnected(peripheral.identifier,
            timestamp: timestamp, reconnecting: isReconnecting,
            peripheralIsConnected: peripheral.state == .connected, mayResume: mayResume)
        record("native_disconnect", "eventCFAbsoluteTime=\(timestamp); receivedCFAbsoluteTime=\(receivedAt); systemIsReconnecting=\(isReconnecting); peripheralState=\(peripheral.state.rawValue); action=\(action); \(Self.errorDetails(error))")
        switch action {
        case .ignore:
            return
        case .applicationFallback:
            completeDisconnection(peripheral, error: error)
        case .waitForSystem:
            recordNativeDisconnection(error, reconnect: true)
            onConfirmedTransportBoundary?(peripheral.identifier)
            clearTransport()
            connected = false
            connecting = true
            connectionRequestedAt = Date()
            connectionWaitOrigin = "system_reconnect_observation"
            status = "iPhone восстанавливает связь с мотоциклом…"
            // No connect/cancel/timer here: iOS already owns the pending request.
        case .prepareConnected:
            recordNativeDisconnection(error, reconnect: true)
            onConfirmedTransportBoundary?(peripheral.identifier)
            connected = false
            record("connection", "BLE соединение установлено; телеметрия ещё не подтверждена; source=native_current_state")
            prepare(peripheral)
        case .cancelConnection:
            if connected {
                recordNativeDisconnection(error, reconnect: false)
                onConfirmedTransportBoundary?(peripheral.identifier)
            }
            if pairingFailure {
                transportRecoveryError = error
                reconnectBlockedReason = "iOS сообщает о проблеме сопряжения. На остановке проверь настройки Bluetooth."
                terminalStatus = reconnectBlockedReason
            }
            // A setup-triggered cancel still intends to retry after its ACK.
            // A racing system-reconnect notification must not revoke that intent.
            if pairingFailure || !reconnectPolicy.transportRestartPending {
                connectionWanted = false
            }
            clearTransport()
            connected = false
            connecting = false
            nativeReconnect.cancellationRequested()
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func recordNativeDisconnection(_ error: Error?, reconnect: Bool) {
        guard !nativeDisconnectLogged else { return }
        recordDisconnectContext(error)
        nativeDisconnectLogged = true
        record("connection", "Отключено; \(Self.errorDetails(error)); reconnect=\(reconnect); systemOwnership=true")
    }

    private func completeDisconnection(_ peripheral: CBPeripheral, error: Error?) {
        if !nativeDisconnectLogged { recordDisconnectContext(error) }
        onConfirmedTransportBoundary?(peripheral.identifier)
        if completeUserRescanCancellation(peripheral, error: error) { return }
        let resumeRemembered = cancelResume.completedCancellation(for: peripheral.identifier,
            canResume: bluetoothPowered && !connectionPaused)
        let shouldReconnect = connectionWanted && autoReconnect && bluetoothPowered
        let recoveryError = transportRecoveryError ?? error
        transportRecoveryError = nil
        recordHealthSnapshot()
        clearTransport()
        nativeReconnect.clearConnection()
        current = nil
        connecting = false
        connected = false
        connectionWanted = false
        status = terminalStatus ?? "Связь прервана"
        if nativeDisconnectLogged {
            record("native_reconnect_terminal", "Системное ожидание завершено; \(Self.errorDetails(error)); reconnect=\(shouldReconnect)")
        } else {
            record("connection", "Отключено; \(Self.errorDetails(error)); reconnect=\(shouldReconnect)")
        }
        nativeDisconnectLogged = false
        if resumeRemembered { connectRemembered() }
        else { recoverConnection(peripheral, error: recoveryError, wanted: shouldReconnect) }
    }
}

/// CoreBluetooth chooses optional delegate selectors at runtime. Keeping the
/// modern and legacy selectors on different objects avoids precedence ambiguity.
private class MotoCentralDelegate: NSObject, CBCentralManagerDelegate {
    weak var owner: MotorcycleBluetooth?
    init(_ owner: MotorcycleBluetooth) { self.owner = owner; super.init() }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { owner?.centralManagerDidUpdateState(central) }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        owner?.centralManager(central, willRestoreState: dict)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        owner?.centralManager(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        owner?.centralManager(central, didConnect: peripheral)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        owner?.centralManager(central, didFailToConnect: peripheral, error: error)
    }
}

private final class MotoLegacyCentralDelegate: MotoCentralDelegate {
    @objc
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        owner?.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }
}

@available(iOS 17.0, *)
private final class MotoModernCentralDelegate: MotoCentralDelegate {
    @objc
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        owner?.centralManager(central, didDisconnectPeripheral: peripheral,
                              timestamp: timestamp, isReconnecting: isReconnecting, error: error)
    }
}

extension MotorcycleBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard isCurrent(peripheral), invalidatedServices.contains(where: {
            $0.uuid == CBUUID(string: MotoProtocol.service)
        }) else { return }
        failSetup("iOS сообщила об изменении сервиса Kawasaki", retry: true)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard isCurrent(peripheral) else { return }
        rssiPending = false
        if let error { record("rssi_error", Self.errorDetails(error)) }
        else {
            lastRSSI = RSSI.intValue
            lastRSSIAt = Date()
            record("rssi", "dBm=\(RSSI.intValue)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let error { failSetup("Ошибка поиска сервиса", error: error, retry: true); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: MotoProtocol.service) }) else {
            let verified = previouslyVerified(peripheral)
            failSetup(verified ? "Ранее проверенный сервис Kawasaki временно не найден"
                : "Ожидаемый сервис Kawasaki отсутствует. Эта модель пока не подтверждена.", retry: verified)
            return
        }
        record("setup", "Сервис найден; поиск каналов")
        let ids = ([MotoProtocol.control] + MotoProtocol.notify).map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(ids, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral), service.uuid == CBUUID(string: MotoProtocol.service) else { return }
        if let error { failSetup("Ошибка поиска каналов", error: error, retry: true); return }
        let characteristics = service.characteristics ?? []
        guard let write = characteristics.first(where: { $0.uuid == CBUUID(string: MotoProtocol.control) }),
              write.properties.contains(.write) else {
            failSetup("Канал запросов с подтверждением не найден", retry: previouslyVerified(peripheral))
            return
        }
        control = write
        for identifier in MotoProtocol.notify {
            guard let characteristic = characteristics.first(where: { $0.uuid == CBUUID(string: identifier) }),
                  characteristic.properties.contains(.notify) else {
                failSetup("Канал уведомлений отсутствует: \(identifier)", retry: previouslyVerified(peripheral))
                return
            }
            notifications[identifier.uppercased()] = characteristic
        }
        rememberVerified(peripheral)
        record("setup", "Каналы найдены; последовательная проверка трёх уведомлений; maxWriteWithResponse=\(peripheral.maximumWriteValueLength(for: .withResponse))")
        subscribed.removeAll()
        pendingNotification = nil
        for characteristic in notifications.values {
            if characteristic.isNotifying {
                // Preserve restored subscriptions instead of interrupting data
                // merely to obtain another confirmation from the same channel.
                subscribed.insert(characteristic.uuid.uuidString.uppercased())
                record("notify_restored", "Действующая подписка сохранена", characteristic: characteristic.uuid.uuidString)
            }
        }
        status = "Подписка на три канала…"
        subscribeNext(peripheral)
    }

    private func subscribeNext(_ peripheral: CBPeripheral) {
        guard isCurrent(peripheral), !ready, pendingNotification == nil else { return }
        for identifier in MotoProtocol.notify.map({ $0.uppercased() }) where !subscribed.contains(identifier) {
            guard let characteristic = notifications[identifier] else { return }
            pendingNotification = identifier
            peripheral.setNotifyValue(true, for: characteristic)
            return
        }
        guard subscribed.count == MotoProtocol.notify.count else { return }
        setupTimeout?.cancel()
        setupTimeout = nil
        ready = true
        status = "Мотоцикл подключён"
        onReadyForCapture?()
        record("ready", "Все три подписки подтверждены")
        if autoReconnect && UserDefaults.standard.bool(forKey: "MotoLink.resumeTelemetry") {
            startCaptureProfileIfNeeded()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.service?.uuid == CBUUID(string: MotoProtocol.service),
              notifications[characteristic.uuid.uuidString.uppercased()] === characteristic else { return }
        if let error { failSetup("Не удалось включить уведомления", error: error, retry: true); return }
        guard characteristic.isNotifying else { failSetup("Мотоцикл отключил уведомления", retry: true); return }
        let identifier = characteristic.uuid.uuidString.uppercased()
        if pendingNotification == identifier { pendingNotification = nil }
        subscribed.insert(identifier)
        record("notify", "Уведомления подтверждены", characteristic: characteristic.uuid.uuidString)
        subscribeNext(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.service?.uuid == CBUUID(string: MotoProtocol.service),
              notifications[characteristic.uuid.uuidString.uppercased()] === characteristic else { return }
        if let error {
            record("rx_error", Self.errorDetails(error), characteristic: characteristic.uuid.uuidString)
            checkStreamRecovery()
            return
        }
        guard let data = characteristic.value else { return }
        packetCount += 1
        lastPacketAt = Date()
        record("rx", MotoProtocol.inspect(data), characteristic: characteristic.uuid.uuidString, data: data)
        let bytes = Array(data)
        if BLEStreamRecoveryPolicy.isPacket(data) {
            streamRecovery.receivedPacket(at: ProcessInfo.processInfo.systemUptime)
        }
        if let supported = MotoProtocol.capabilities(data) {
            capabilities = supported
            telemetryPresentation.configure(supported)
            publishTelemetry(force: true)
        }
        if BLEStreamRecoveryPolicy.isStreamFrame(data) {
            streamPackets += 1
            lastStreamAt = lastPacketAt
            streamRecovery.receivedStream(at: ProcessInfo.processInfo.systemUptime)
            if let timestamp = lastStreamAt { onStreamFrame?(timestamp) }
        }
        let decoded = MotoProtocol.measurements(data, capabilities: capabilities)
        // A private atomic replacement preserves row identities and order while
        // invalidating missing values. Display sampling never throttles capture.
        telemetryPresentation.receive(data, decoded: decoded)
        publishTelemetry()
        if !decoded.isEmpty {
            if bytes.first == 0x4A {
                decodedStreamFrames += 1
                lastStreamAt = lastPacketAt
                reconnectPolicy.receivedTelemetry(at: lastPacketAt!)
                if reconnectAttempt > 0, reconnectPolicy.failureCount == 0 {
                    reconnectAttempt = 0
                    record("reconnect_recovered", "Свежая телеметрия поступает не менее 15 секунд")
                }
            }
            onMeasurements?(decoded)
        }
        if bytes.count == 5, bytes[0] == 0x20, bytes[1] == 2,
           let write = activeWrite, bytes[3] == write.command, bytes[4] != 0 {
            record("command_rejected", String(format: "0x%02X: код %d", write.command, bytes[4]))
            // Wait for didWriteValueFor before advancing, otherwise an old ATT
            // callback can be mistaken for the next queued write.
            rejectedResponse = true
            if writeConfirmed { finishRequest(received: false, rejected: true) }
            checkStreamRecovery()
            return
        }
        if let activeWrite, matchesResponse(data, command: activeWrite.command) {
            responseReceived = true
            if writeConfirmed { finishRequest(received: true) }
        }
        checkStreamRecovery()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), control === characteristic, let activeWrite else { return }
        writeTimeout?.cancel()
        writeTimeout = nil
        if let error {
            let cause = error as NSError
            let pairingFailure = cause.domain == CBErrorDomain &&
                [CBError.Code.peerRemovedPairingInformation.rawValue, CBError.Code.tooManyLEPairedDevices.rawValue].contains(cause.code)
            if optionalStreamRearmInProgress, !pairingFailure,
               streamRecovery.hasRecentPacket(at: ProcessInfo.processInfo.systemUptime) {
                // An error callback completes this ATT operation. Unlike a
                // missing callback, it is now safe to release the queue.
                finishRequest(received: false, failure: "Дополнительный 08: \(Self.errorDetails(error)); другие корректные пакеты поступают")
                return
            }
            failSetup("Ошибка передачи запроса", error: error, retry: true)
            return
        }
        writeConfirmed = true
        record("tx_confirmed", String(format: "BLE принял 0x%02X; это не подтверждение данных", activeWrite.command))
        if rejectedResponse {
            finishRequest(received: false, rejected: true)
        } else if responseReceived {
            finishRequest(received: true)
        } else {
            status = "Запрос передан. Ожидание ответа…"
            let expectedSession = session
            let command = activeWrite.command
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.session == expectedSession,
                      self.activeWrite?.command == command else { return }
                self.finishRequest(received: false)
            }
            responseTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        }
    }
}

struct SharedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}
