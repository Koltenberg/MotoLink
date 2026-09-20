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
    private var reenableNotifications: Set<String> = []
    private var session = UUID()
    private var scanTimeout: DispatchWorkItem?
    private var setupTimeout: DispatchWorkItem?
    private var writeTimeout: DispatchWorkItem?
    private var responseTimeout: DispatchWorkItem?
    private var pendingWrites: [(command: UInt8, frame: Data)] = []
    private var activeWrite: (command: UInt8, frame: Data)?
    private var writeConfirmed = false
    private var responseReceived = false
    private var rejectedResponse = false
    private var logStore: SessionLogStore?

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
        record("app", "MotoLink 0.3 · iOS \(UIDevice.current.systemVersion)")
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "app.motolink.central.v1",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(enteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
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
        beginConnection(peripheral)
    }

    func setAutoReconnect(_ enabled: Bool) {
        guard !enabled || hasRememberedDevice else { return }
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

    @objc private func enteredBackground() {
        if scanning {
            stopScan()
            status = "Поиск приостановлен. Откройте приложение для выбора мотоцикла."
        }
    }

    private func beginConnection(_ peripheral: CBPeripheral) {
        stopScan()
        clearTransport()
        terminalStatus = nil
        current = peripheral
        peripheral.delegate = self
        connectionWanted = true
        connecting = true
        connected = false
        packetCount = 0
        lastPacketAt = nil
        status = "Ожидание \(selectedName)…"
        record("connection", "Запрошено подключение к \(selectedName); id=\(peripheral.identifier.uuidString)")
        // CoreBluetooth keeps this request pending when the motorcycle is off.
        // No deadline/retry timer is needed for a known peripheral.
        central.connect(peripheral, options: nil)
    }

    private func prepare(_ peripheral: CBPeripheral) {
        clearTransport()
        connected = true
        connecting = false
        status = "Bluetooth подключён. Проверка каналов…"
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: MotoProtocol.service)])
        let expectedSession = session
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session == expectedSession, !self.ready else { return }
            self.failSetup("Мотоцикл не подтвердил каналы за 60 секунд")
        }
        setupTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    private func clearTransport() {
        session = UUID()
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
        activeWrite = nil
        writeConfirmed = false
        responseReceived = false
        rejectedResponse = false
        busy = false
        ready = false
        control = nil
        notifications.removeAll()
        subscribed.removeAll()
        reenableNotifications.removeAll()
    }

    private func failSetup(_ message: String) {
        record("error", message)
        terminalStatus = message
        connectionWanted = false
        clearTransport()
        status = message
        if let current { central.cancelPeripheralConnection(current) }
    }

    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        current === peripheral && connectionWanted
            && peripheral.state == .connected
    }

    private func sendNext() {
        guard ready, let current, current.state == .connected, let control else {
            pendingWrites.removeAll()
            activeWrite = nil
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
        // Register response state before writeValue: a notification can reach
        // us before didWriteValueFor confirms the ATT transaction.
        writeConfirmed = false
        responseReceived = false
        rejectedResponse = false
        record("tx", String(format: "Запрос 0x%02X", write.command), characteristic: MotoProtocol.control, data: write.frame)
        current.writeValue(write.frame, for: control, type: .withResponse)
        let expectedSession = session
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session == expectedSession, self.activeWrite != nil else { return }
            self.failSetup("Нет подтверждения BLE-записи. Запросы остановлены; повторите подключение.")
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

    private func finishRequest(received: Bool, rejected: Bool = false) {
        guard let write = activeWrite else { return }
        responseTimeout?.cancel()
        responseTimeout = nil
        activeWrite = nil
        writeConfirmed = false
        responseReceived = false
        rejectedResponse = false
        let command = String(format: "0x%02X", write.command)
        if received {
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
    }
}

extension MotorcycleBluetooth: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothPowered = central.state == .poweredOn
        guard bluetoothPowered else {
            stopScan()
            clearTransport()
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
        if autoReconnect && shouldResumeAtPowerOn { connectRemembered() }
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
        clearTransport()
        current = nil
        connecting = false
        connected = false
        connectionWanted = false
        status = terminalStatus ?? "Подключение не удалось: \(error?.localizedDescription ?? "причина не указана")"
        record("error", status)
        // Do not spin on authentication failures or replay diagnostic writes.
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard current === peripheral, peripheral.state == .disconnected else { return }
        let shouldReconnect = connectionWanted && autoReconnect && bluetoothPowered
        clearTransport()
        current = nil
        connecting = false
        connected = false
        connectionWanted = false
        status = terminalStatus ?? "Связь прервана"
        record("connection", "Отключено\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if shouldReconnect { beginConnection(peripheral) }
    }
}

extension MotorcycleBluetooth: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        if let error { failSetup("Ошибка поиска сервиса: \(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: MotoProtocol.service) }) else {
            failSetup("Ожидаемый сервис Kawasaki отсутствует. Эта модель пока не подтверждена.")
            return
        }
        let ids = ([MotoProtocol.control] + MotoProtocol.notify).map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(ids, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral), service.uuid == CBUUID(string: MotoProtocol.service) else { return }
        if let error { failSetup("Ошибка поиска каналов: \(error.localizedDescription)"); return }
        let characteristics = service.characteristics ?? []
        guard let write = characteristics.first(where: { $0.uuid == CBUUID(string: MotoProtocol.control) }),
              write.properties.contains(.write) else {
            failSetup("Канал запросов с подтверждением не найден")
            return
        }
        control = write
        for identifier in MotoProtocol.notify {
            guard let characteristic = characteristics.first(where: { $0.uuid == CBUUID(string: identifier) }),
                  characteristic.properties.contains(.notify) else {
                failSetup("Канал уведомлений отсутствует: \(identifier)")
                return
            }
            notifications[identifier.uppercased()] = characteristic
        }
        subscribed.removeAll()
        reenableNotifications.removeAll()
        for characteristic in notifications.values {
            if characteristic.isNotifying {
                // State restoration may return an already subscribed channel.
                // Re-enable once so this session gets explicit confirmations.
                reenableNotifications.insert(characteristic.uuid.uuidString.uppercased())
                peripheral.setNotifyValue(false, for: characteristic)
            } else {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        status = "Подписка на три канала…"
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.service?.uuid == CBUUID(string: MotoProtocol.service),
              notifications[characteristic.uuid.uuidString.uppercased()] === characteristic else { return }
        if let error { failSetup("Не удалось включить уведомления: \(error.localizedDescription)"); return }
        if !characteristic.isNotifying,
           reenableNotifications.remove(characteristic.uuid.uuidString.uppercased()) != nil {
            peripheral.setNotifyValue(true, for: characteristic)
            return
        }
        guard characteristic.isNotifying else { failSetup("Мотоцикл отключил уведомления"); return }
        subscribed.insert(characteristic.uuid.uuidString.uppercased())
        record("notify", "Уведомления подтверждены", characteristic: characteristic.uuid.uuidString)
        if subscribed.count == MotoProtocol.notify.count {
            setupTimeout?.cancel()
            setupTimeout = nil
            ready = true
            status = "Каналы готовы. Выберите диагностический запрос."
            record("ready", "Все три подписки подтверждены")
            if autoReconnect && UserDefaults.standard.bool(forKey: "MotoLink.resumeTelemetry") {
                runFullDiagnostic()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.service?.uuid == CBUUID(string: MotoProtocol.service),
              notifications[characteristic.uuid.uuidString.uppercased()] === characteristic else { return }
        if let error {
            record("rx_error", error.localizedDescription, characteristic: characteristic.uuid.uuidString)
            return
        }
        guard let data = characteristic.value else { return }
        packetCount += 1
        lastPacketAt = Date()
        record("rx", MotoProtocol.inspect(data), characteristic: characteristic.uuid.uuidString, data: data)
        let bytes = Array(data)
        if bytes.first == 0x40 {
            capabilities = MotoProtocol.capabilities(data) ?? []
            measurements = []
        }
        if bytes.count >= 15, bytes.count == Int(bytes[1]) + 3, bytes[0] == 0x4A { streamPackets += 1 }
        // Missing/sentinel values in a new valid frame must not leave the old
        // measurement looking current. Malformed frames preserve the last time.
        if bytes.count >= 3, bytes.count == Int(bytes[1]) + 3 {
            let ids: [UInt8: Set<String>] = [
                0x41: ["ecu_battery12V"],
                0x45: ["engine_water_temperature", "inlet_air_temperature"],
                0x4A: ["engine_speed", "wheel_speed", "gear_position", "throttle_position"]
            ]
            if let invalidated = ids[bytes[0]] { measurements.removeAll { invalidated.contains($0.id) } }
        }
        let decoded = MotoProtocol.measurements(data, capabilities: capabilities)
        for value in decoded {
            measurements.removeAll { $0.id == value.id }
            measurements.append(value)
        }
        if !decoded.isEmpty {
            if bytes.first == 0x4A { decodedStreamFrames += 1 }
            onMeasurements?(decoded)
        }
        if bytes.count == 5, bytes[0] == 0x20, bytes[1] == 2,
           let write = activeWrite, bytes[3] == write.command, bytes[4] != 0 {
            record("command_rejected", String(format: "0x%02X: код %d", write.command, bytes[4]))
            // Wait for didWriteValueFor before advancing, otherwise an old ATT
            // callback can be mistaken for the next queued write.
            rejectedResponse = true
            if writeConfirmed { finishRequest(received: false, rejected: true) }
            return
        }
        if let activeWrite, matchesResponse(data, command: activeWrite.command) {
            responseReceived = true
            if writeConfirmed { finishRequest(received: true) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), control === characteristic, let activeWrite else { return }
        writeTimeout?.cancel()
        writeTimeout = nil
        if let error { failSetup("Ошибка передачи запроса: \(error.localizedDescription)"); return }
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
