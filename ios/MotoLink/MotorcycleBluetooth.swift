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
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var reconnectBlockedReason: String?
    private var reconnectPolicy = BLEReconnectPolicy()
    private var streamRecovery = BLEStreamRecoveryPolicy()
    private var transportRecoveryError: Error?
    private var lastPacketPeripheralID: UUID?
    private var lastRSSIRequestAt: Date?
    private var rssiPending = false
    @Published private(set) var storageError: String?
    @Published private(set) var exportBusy = false
    @Published var exportedFiles: SharedFiles?

    @Published private(set) var capabilities: [MotoProtocol.Capability] = []
    @Published private(set) var measurements: [MotoProtocol.Measurement] = []
    @Published private(set) var diagnosticRunning = false
    @Published private(set) var diagnosticStatus = "Готов к полной проверке"
    @Published private(set) var streamPackets = 0
    var onMeasurements: (([MotoProtocol.Measurement]) -> Void)?

    private var diagnosticPhase = 0
    private var decodedStreamFrames = 0
    private var observationTimeout: DispatchWorkItem?
    private var queryRetries: [UInt8: Int] = [:]

    private enum Key {
        static let identifier = "MotoLink.peripheralIdentifier"
        static let name = "MotoLink.peripheralName"
        static let reconnect = "MotoLink.autoReconnect"
        static let verifiedDevices = "MotoLink.verifiedBLE5Devices"
    }

    private var central: CBCentralManager!
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
        shouldResumeAtPowerOn = reconnect
        super.init()
        do {
            logStore = try SessionLogStore()
            logStore?.onError = { [weak self] message in self?.storageError = message }
        } catch {
            storageError = error.localizedDescription
        }
        record("app", "MotoLink \(AppBuild.version) (\(AppBuild.number)) · iOS \(UIDevice.current.systemVersion)")
        central = CBCentralManager(delegate: self, queue: .main, options: [
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
    }

    func scan() {
        guard bluetoothPowered, current == nil else { return }
        stopScan()
        found.removeAll()
        nearby.removeAll()
        terminalStatus = nil
        scanning = true
        status = "Поиск мотоцикла поблизости…"
        // Foreground discovery includes devices omitting UUIDs in advertising.
        // The list is restricted to Kawasaki names or the observed service UUID.
        central.scanForPeripherals(withServices: nil, options: nil)
        record("scan", "Начат поиск; выберите свой мотоцикл в списке")
        let timeout = DispatchWorkItem { [weak self] in
            self?.stopScan()
            self?.status = "Поиск завершён. Выберите мотоцикл или повторите поиск."
        }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()
        scanning = false
    }

    func connect(to identifier: UUID) {
        guard bluetoothPowered, current == nil, let peripheral = found[identifier] else { return }
        resetRecovery()
        savedID = identifier
        selectedName = nearby.first(where: { $0.id == identifier })?.name ?? peripheral.name ?? "Kawasaki"
        hasRememberedDevice = true
        UserDefaults.standard.set(identifier.uuidString, forKey: Key.identifier)
        UserDefaults.standard.set(selectedName, forKey: Key.name)
        beginConnection(peripheral)
    }

    func connectRemembered() {
        guard bluetoothPowered, current == nil, let savedID else { return }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [savedID]).first else {
            status = "Сохранённый мотоцикл не найден в iOS. Повторите поиск."
            return
        }
        resetRecovery()
        beginConnection(peripheral)
    }

    func setAutoReconnect(_ enabled: Bool) {
        guard !enabled || hasRememberedDevice else { return }
        if !enabled { resetRecovery() }
        autoReconnect = enabled
        shouldResumeAtPowerOn = enabled
        UserDefaults.standard.set(enabled, forKey: Key.reconnect)
        record("setting", "Автоподключение: \(enabled ? "включено" : "выключено")")
        if enabled, bluetoothPowered, current == nil {
            connectRemembered()
        } else if !enabled, connecting, let current {
            connectionWanted = false
            terminalStatus = "Ожидание подключения остановлено"
            central.cancelPeripheralConnection(current)
        }
    }

    func stop() {
        resetRecovery()
        autoReconnect = false
        shouldResumeAtPowerOn = false
        UserDefaults.standard.set(false, forKey: Key.reconnect)
        connectionWanted = false
        terminalStatus = "Остановлено"
        stopScan()
        clearTransport()
        if let current {
            central.cancelPeripheralConnection(current)
        }
        connecting = false
        connected = false
        status = "Остановлено"
        record("connection", "Остановлено пользователем; очередь запросов очищена")
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

    func runFullDiagnostic() {
        guard ready, !busy, !diagnosticRunning else { return }
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
        let now = Date()
        let packetAge = lastPacketAt.map { Int(max(0, now.timeIntervalSince($0))) } ?? -1
        let streamAge = lastStreamAt.map { Int(max(0, now.timeIntervalSince($0))) } ?? -1
        let waiting = connecting ? connectionRequestedAt.map { Int(max(0, now.timeIntervalSince($0))) } ?? -1 : 0
        record("ble_health", "connected=\(connected); ready=\(ready); connecting=\(connecting); waitSeconds=\(waiting); packetAgeSeconds=\(packetAge); streamAgeSeconds=\(streamAge); peripheralState=\(current?.state.rawValue ?? -1); reconnectAttempt=\(reconnectAttempt); appState=\(UIApplication.shared.applicationState.rawValue)")
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

    @objc private func enteredBackground() {
        if scanning {
            stopScan()
            status = "Поиск приостановлен. Откройте приложение для выбора мотоцикла."
        }
    }

    private func resetRecovery() {
        reconnectPolicy.reset()
        transportRecoveryError = nil
        reconnectAttempt = 0
        reconnectBlockedReason = nil
    }

    @objc private func becameActive() {
        // An opportunity to check an existing session, not a background timer.
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
    /// CoreBluetooth owns the delay so recovery does not depend on an app timer.
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
        record("reconnect", "attempt=\(reconnectAttempt); systemDelaySeconds=\(Int(delay)); \(Self.errorDetails(error))")
        beginConnection(peripheral, delay: delay)
    }

    private func beginConnection(_ peripheral: CBPeripheral, delay: TimeInterval = 0) {
        stopScan()
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
            lastPacketAt = nil
            lastPacketPeripheralID = peripheral.identifier
        }
        lastStreamAt = nil
        connectionRequestedAt = Date()
        reconnectPolicy.connectionStarted()
        status = "Ожидание \(selectedName)…"
        record("connection", "Запрошено подключение к \(selectedName); id=\(peripheral.identifier.uuidString)")
        // A pending request is never cancelled merely because it takes time.
        // Only a completed didFail/didDisconnect creates another request.
        let options: [String: Any]? = delay > 0
            ? [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: delay)] : nil
        central.connect(peripheral, options: options)
    }

    private func prepare(_ peripheral: CBPeripheral) {
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

    private func clearTransport() {
        session = UUID()
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
        measurements = []
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
        if let current { central.cancelPeripheralConnection(current) }
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

extension MotorcycleBluetooth: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothPowered = central.state == .poweredOn
        guard bluetoothPowered else {
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
            if current.state == .connected { prepare(current) }
            else if current.state != .connecting { central.connect(current, options: nil) }
            return
        }
        status = "Bluetooth готов"
        if autoReconnect && shouldResumeAtPowerOn && reconnectBlockedReason == nil { connectRemembered() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for peripheral in peripherals {
            guard autoReconnect, peripheral.identifier == savedID else {
                central.cancelPeripheralConnection(peripheral)
                continue
            }
            current = peripheral
            peripheral.delegate = self
            connectionWanted = true
            connecting = peripheral.state != .connected
            connected = peripheral.state == .connected
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
        guard current === peripheral, connectionWanted else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        record("connection", "BLE соединение установлено; телеметрия ещё не подтверждена")
        prepare(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard current === peripheral, peripheral.state == .disconnected else { return }
        let wanted = connectionWanted
        let recoveryError = transportRecoveryError ?? error
        transportRecoveryError = nil
        clearTransport()
        current = nil
        connecting = false
        connected = false
        connectionWanted = false
        status = terminalStatus ?? "Подключение не удалось: \(error?.localizedDescription ?? "причина не указана")"
        record("error", "\(status); \(Self.errorDetails(error))")
        recordHealthSnapshot()
        // An encryption timeout is not evidence that the bond was removed.
        recoverConnection(peripheral, error: recoveryError, wanted: wanted)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard current === peripheral, peripheral.state == .disconnected else { return }
        let shouldReconnect = connectionWanted && autoReconnect && bluetoothPowered
        let recoveryError = transportRecoveryError ?? error
        transportRecoveryError = nil
        recordHealthSnapshot()
        clearTransport()
        current = nil
        connecting = false
        connected = false
        connectionWanted = false
        status = terminalStatus ?? "Связь прервана"
        record("connection", "Отключено; \(Self.errorDetails(error)); reconnect=\(shouldReconnect)")
        recoverConnection(peripheral, error: recoveryError, wanted: shouldReconnect)
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
        else { record("rssi", "dBm=\(RSSI.intValue)") }
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
        status = "Каналы готовы. Выберите диагностический запрос."
        record("ready", "Все три подписки подтверждены")
        if autoReconnect && UserDefaults.standard.bool(forKey: "MotoLink.resumeTelemetry") {
            runFullDiagnostic()
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
        if bytes.first == 0x40 {
            capabilities = MotoProtocol.capabilities(data) ?? []
            measurements = []
        }
        if BLEStreamRecoveryPolicy.isStreamFrame(data) {
            streamPackets += 1
            lastStreamAt = lastPacketAt
            streamRecovery.receivedStream(at: ProcessInfo.processInfo.systemUptime)
        }
        // Missing/sentinel values in a new valid frame must not leave the old
        // measurement looking current. Malformed frames preserve the last time.
        if bytes.count >= 3, bytes.count == Int(bytes[1]) + 3 {
            let ids: [UInt8: Set<String>] = [
                0x41: ["ecu_battery12V"],
                0x45: ["engine_water_temperature", "inlet_air_temperature"],
                0x4A: ["engine_speed", "wheel_speed", "gear_position", "throttle_position", "fuel_injection_raw"]
            ]
            if let invalidated = ids[bytes[0]] { measurements.removeAll { invalidated.contains($0.id) } }
        }
        let decoded = MotoProtocol.measurements(data, capabilities: capabilities)
        for value in decoded {
            measurements.removeAll { $0.id == value.id }
            measurements.append(value)
        }
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
