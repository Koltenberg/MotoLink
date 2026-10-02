import SwiftUI
import Combine
import UserNotifications

/// Separate atomic file: editing garage records never rewrites ride journals.
final class CompanionStore: ObservableObject {
    @Published private(set) var data = CompanionData()
    @Published var error: String?
    @Published var notificationStatus: String?
    private var file: URL?
    private var readable = false

    init() {
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let url = directory.appendingPathComponent("MotoLinkCompanion.json")
            file = url
            if FileManager.default.fileExists(atPath: url.path) {
                data = try JSONDecoder().decode(CompanionData.self, from: Data(contentsOf: url))
                try data.validate()
            }
            readable = true
            scheduleReminders()
        } catch { self.error = "Не удалось открыть данные мотоцикла: \(error.localizedDescription). Исходный файл сохранён." }
    }

    @discardableResult func save(_ change: (inout CompanionData) -> Void) -> Bool {
        guard readable, let file else { return false }
        do {
            var next = data
            change(&next)
            try next.validate()
            let bytes = try JSONEncoder().encode(next)
            try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            data = next
            error = nil
            scheduleReminders()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Pull-to-refresh rereads our local atomic file, without Bluetooth or a server.
    /// Decode and validate first; a failed read never replaces the visible records.
    @MainActor func refreshFromDisk() {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let refreshed = try JSONDecoder().decode(CompanionData.self, from: Data(contentsOf: file))
            try refreshed.validate()
            data = refreshed
            readable = true
            error = nil
            scheduleReminders()
        } catch {
            self.error = "Не удалось перечитать данные мотоцикла: \(error.localizedDescription). Текущие записи сохранены."
        }
    }

    func enableReminders() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.notificationStatus = error?.localizedDescription ?? (granted
                    ? "Напомним о выбранных датах. Сроки по пробегу видны в гараже."
                    : "Уведомления выключены. Сроки видны в гараже.")
                if granted { self.scheduleReminders() }
            }
        }
    }

    private var reminderUpdateRunning = false
    private var reminderUpdateRequested = false

    /// Coalesces rapid edits; an old async pass cannot be the final schedule.
    private func scheduleReminders() {
        reminderUpdateRequested = true
        guard !reminderUpdateRunning else { return }
        reminderUpdateRunning = true
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            while reminderUpdateRequested {
                reminderUpdateRequested = false
                let tasks = data.serviceTasks
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { continue }
                let pending = await center.pendingNotificationRequests()
                center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("motolink.service.") })
                let calendar = Calendar.current
                let upcoming: [(ServiceTask, Date)] = tasks.compactMap { task in
                    guard let due = task.dueDate(calendar: calendar),
                          let fire = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: due),
                          fire > Date() else { return nil }
                    return (task, fire)
                }.sorted { $0.1 < $1.1 }
                for (task, fire) in upcoming.prefix(32) {
                    let content = UNMutableNotificationContent()
                    content.title = "Moto Link · обслуживание"
                    content.body = task.title + ": наступил выбранный срок. Проверь пробег и рекомендации руководства."
                    content.sound = .default
                    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    let request = UNNotificationRequest(identifier: "motolink.service." + task.id.uuidString,
                        content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                    do { try await center.add(request) }
                    catch { notificationStatus = error.localizedDescription }
                }
            }
            reminderUpdateRunning = false
        }
    }

}

private func decimal(_ value: String) -> Double? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "\u{00A0}", with: "")
        .replacingOccurrences(of: "\u{202F}", with: "")
    guard let number = Double(cleaned), number.isFinite else { return nil }
    return number
}

private func numberText(_ value: Double?) -> String {
    value.map { String($0) } ?? ""
}

private func fuelAmountText(_ entry: FuelEntry) -> String {
    entry.liters.map { String(format: "%.1f л", $0) } ?? "объём не указан"
}

private func recordedTrips(_ rides: RideRecorder?) -> [RecordedTripDistance] {
    guard let rides else { return [] }
    let summaries = rides.history + (rides.active.map { [$0] } ?? [])
    return summaries.map {
        RecordedTripDistance(id: $0.id, startedAt: $0.startedAt, endedAt: $0.endedAt,
                             distanceMeters: $0.distanceMeters)
    }
}

private func currentRideSnapshot(_ rides: RideRecorder?) -> RideDistanceSnapshot? {
    guard let active = rides?.active else { return nil }
    return RideDistanceSnapshot(rideID: active.id, distanceMeters: active.distanceMeters)
}

private func serviceStatusColor(_ task: ServiceTask, odometerKm: Double?) -> Color {
    if task.isDue(odometerKm: odometerKm) { return .red }
    if task.isDueSoon(odometerKm: odometerKm) {
        let progress: Double
        if let start = task.rangeStartOdometerKm, let end = task.dueOdometerKm,
           let odometerKm, end > start {
            progress = min(1, max(0, (odometerKm - start) / (end - start)))
        } else { progress = 0 }
        // Keep light-theme text dark enough while the selected range moves
        // from amber toward red. The written mileage remains the primary cue.
        return Color(UIColor { traits in
            let p = CGFloat(progress)
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0.82 - 0.59 * p, blue: 0.2 - 0.01 * p, alpha: 1)
                : UIColor(red: 0.49 + 0.31 * p, green: 0.35 - 0.2 * p, blue: 0.1 * p, alpha: 1)
        })
    }
    return MotoTheme.secondary
}


/// Reusable idle reminder; all readings come from the user's garage entries.
struct ServiceReminderCard: View {
    @ObservedObject var store: CompanionStore
    @State private var selectedTask: ServiceTask?

    private var nextTask: ServiceTask? {
        store.data.serviceTasks.sorted { lhs, rhs in
            let odo = store.data.currentOdometerKm
            let leftDue = lhs.isDue(odometerKm: odo)
            let rightDue = rhs.isDue(odometerKm: odo)
            if leftDue != rightDue { return leftDue }
            let leftSoon = lhs.isDueSoon(odometerKm: odo)
            let rightSoon = rhs.isDueSoon(odometerKm: odo)
            if leftSoon != rightSoon { return leftSoon }
            // Order by stable dimensions; mixing pairwise date/km comparisons
            // would make the sort non-transitive for mixed reminder types.
            if (lhs.dueOdometerKm != nil) != (rhs.dueOdometerKm != nil) { return lhs.dueOdometerKm != nil }
            let leftKm = lhs.dueOdometerKm ?? .greatestFiniteMagnitude
            let rightKm = rhs.dueOdometerKm ?? .greatestFiniteMagnitude
            if leftKm != rightKm { return leftKm < rightKm }
            let leftDate = lhs.dueDate() ?? .distantFuture
            let rightDate = rhs.dueDate() ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first
    }

    var body: some View {
        if let task = nextTask {
            Button { selectedTask = task } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Label(task.isDue(odometerKm: store.data.currentOdometerKm)
                          ? "Пора обслужить" : (task.isDueSoon(odometerKm: store.data.currentOdometerKm)
                          ? "Скоро обслуживание" : "Следующее обслуживание"),
                          systemImage: "wrench.and.screwdriver")
                        .font(MotoTheme.font(.subheadline))
                        .foregroundStyle(serviceStatusColor(task, odometerKm: store.data.currentOdometerKm))
                    Text(task.title).font(MotoTheme.font(.headline))
                    ServiceScheduleText(task: task, odometerKm: store.data.currentOdometerKm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).pixelPanel()
            }
            .buttonStyle(.plain)
            .sheet(item: $selectedTask) { ServiceEditor(store: store, task: $0) }
        }
    }
}

private struct ServiceScheduleText: View {
    let task: ServiceTask
    let odometerKm: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let next = task.dueOdometerKm {
                Text(task.rangeStartOdometerKm.map { String(format: "Обслужить на %.0f–%.0f км", $0, next) }
                     ?? String(format: "Следующее — на %.0f км", next))
                    .font(MotoTheme.font(.subheadline))
            }
            if let start = task.rangeStartOdometerKm, let odometerKm, odometerKm >= start,
               !task.isDue(odometerKm: odometerKm) {
                Text("Можно обслужить · выбранный диапазон начался")
                    .font(MotoTheme.font(.caption))
                    .foregroundStyle(serviceStatusColor(task, odometerKm: odometerKm))
            }
            if let remaining = task.kilometersRemaining(odometerKm: odometerKm) {
                Text(remaining > 0
                     ? String(format: task.intervalStartKm == nil
                         ? "Осталось %.0f км по последнему пробегу" : "До конца диапазона — %.0f км", remaining)
                     : (remaining < 0 ? String(format: "Срок пройден на %.0f км", -remaining) : "Пробег для обслуживания достигнут"))
                    .font(MotoTheme.font(.caption)).foregroundStyle(serviceStatusColor(task, odometerKm: odometerKm))
            }
            if let progress = task.mileageProgress(odometerKm: odometerKm) {
                ProgressView(value: progress)
                    .tint(serviceStatusColor(task, odometerKm: odometerKm))
                    .accessibilityLabel("Пробег до обслуживания")
                    .accessibilityValue(String(format: "%.0f процентов интервала", progress * 100))
            }
            if let date = task.dueDate() {
                Text("По дате — до " + date.formatted(date: .abbreviated, time: .omitted))
                    .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            }
        }
    }
}

/// Kept for callers that present the garage as a card rather than a tab.
struct CompanionHomeCard: View {
    @ObservedObject var store: CompanionStore
    @ObservedObject var rides: RideRecorder
    var body: some View {
        NavigationLink { CompanionView(store: store, rides: rides) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(store.data.bikeName, systemImage: "wrench.and.screwdriver")
                    .font(MotoTheme.font(.headline))
                Text(store.data.estimatedOdometer(from: recordedTrips(rides)).map {
                    String(format: "≈ %.0f км · оценка GPS", $0.kilometers)
                } ?? store.data.currentOdometerKm.map { String(format: "%.0f км с приборки", $0) }
                     ?? "Добавь пробег с приборки")
                    .font(MotoTheme.font(.title3))
                Text("Заправки и обслуживание").font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).pixelPanel()
        }.buttonStyle(.plain)
    }
}

struct CompanionView: View {
    @ObservedObject var store: CompanionStore
    @ObservedObject var rides: RideRecorder
    @State private var editingBike = false
    @State private var newFuel = false
    @State private var newService = false
    @State private var selectedService: ServiceTask?

    private var odometerEstimate: OdometerEstimate? {
        store.data.estimatedOdometer(from: recordedTrips(rides))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        Text(store.data.bikeName).font(MotoTheme.font(.title2))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button { editingBike = true } label: { Image(systemName: "pencil") }
                            .accessibilityLabel("Изменить название и пробег")
                    }
                    BikeArtworkView()
                    if let actual = odometerEstimate?.anchorKilometers ?? store.data.currentOdometerKm {
                        Text(String(format: "%.0f км", actual)).font(MotoTheme.font(.title2))
                        Text("Последнее подтверждённое показание с приборки")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    } else {
                        Text("Пробег с приборки пока не указан").font(MotoTheme.font(.title2))
                    }
                    if let estimate = odometerEstimate {
                        Text(String(format: "≈ %.0f км", estimate.kilometers))
                            .font(MotoTheme.font(.title3)).monospacedDigit()
                        Text(String(format: "Расчёт: %@ %@ · %.0f км + %.1f км по GPS iPhone%@. Пропуски GPS не включены.",
                                    estimate.anchorSource == .profile ? "показание в гараже" : "заправка",
                                    estimate.anchorDate.formatted(date: .abbreviated, time: .shortened),
                                    estimate.anchorKilometers, estimate.addedGPSKilometers,
                                    estimate.includesActiveRide ? ", включая текущую запись" : ""))
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                        if estimate.skippedOverlappingRide {
                            Text("Часть поездки до точки отсчёта неизвестна: оценка может быть занижена.")
                                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                        }
                    } else if store.data.currentOdometerKm != nil {
                        Text("Для расчётного пробега подтверди текущее показание с приборки. Старые записи без даты нельзя безопасно сложить с поездками.")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }
                    Button("Обновить пробег") { editingBike = true }
                }.padding(.vertical, 8)
            }
            if !store.data.serviceTasks.isEmpty {
                Section { ServiceReminderCard(store: store) }.listRowBackground(Color.clear)
            }
            PixelSection("Обслуживание") {
                Button { newService = true } label: { Label("Добавить обслуживание", systemImage: "plus") }
                if store.data.serviceTasks.isEmpty {
                    Text("Запиши, на каком пробеге менял масло или обслуживал цепь. Дату можно не указывать.")
                        .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                }
                ForEach(store.data.serviceTasks) { task in
                    Button { selectedService = task } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(task.title).font(MotoTheme.font(.body))
                                Spacer()
                                Image(systemName: "chevron.right").font(MotoTheme.font(.caption))
                            }
                            Text(String(format: "Последнее — на %.0f км", task.lastDoneOdometerKm)
                                 + (task.lastDoneAt.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                            ServiceScheduleText(task: task, odometerKm: store.data.currentOdometerKm)
                        }.padding(.vertical, 4)
                    }.tint(.primary)
                }
                if store.data.serviceTasks.contains(where: { $0.intervalMonths != nil }) {
                    Button("Напоминать о сроках по датам") { store.enableReminders() }
                    if let status = store.notificationStatus { Text(status).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary) }
                }
            }
            PixelSection("Заправки") {
                Button { newFuel = true } label: { Label("Добавить заправку", systemImage: "fuelpump") }
                if rides.active != nil {
                    Text("Заправку можно сохранить сейчас: запись поездки продолжится после остановки и нового подключения байка.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                if let consumption = store.data.latestFullTankConsumption {
                    LabeledContent("Расход между полными баками",
                                   value: String(format: "%@%.2f л/100 км", consumption.usesEstimatedOdometer ? "≈ " : "", consumption.litersPer100Km))
                        .monospacedDigit()
                }
                if let fuel = store.data.fuelEntries.max(by: { $0.date < $1.date }) {
                    Text("Последняя — " + fuel.date.formatted(date: .abbreviated, time: .omitted)
                         + " · " + fuelAmountText(fuel))
                        .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                    NavigationLink("Все заправки") { FuelHistoryView(store: store, rides: rides) }
                } else {
                    Text("Полный бак можно сохранить без литров. Для расчёта расхода записывай объём каждой заправки между полными баками.")
                        .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                }
                if !store.data.fuelEntries.isEmpty, store.data.latestFullTankConsumption == nil {
                    Text("Для последнего полного бака расход пока не рассчитан. Нужен полный бак в начале и известный объём всех следующих заправок до нового полного бака.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
            }
            if let error = store.error { Section { Text(error).foregroundStyle(MotoTheme.accent) } }
        }
        .font(MotoTheme.font(.body))
        .scrollContentBackground(.hidden).background(MotoTheme.background)
        .navigationTitle("Гараж")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshFromDisk() }
        .sheet(isPresented: $editingBike) { BikeProfileEditor(store: store, rides: rides) }
        .sheet(isPresented: $newFuel) { FuelEditor(store: store, rides: rides, entry: nil) }
        .sheet(isPresented: $newService) { ServiceEditor(store: store, task: nil) }
        .sheet(item: $selectedService) { ServiceEditor(store: store, task: $0) }
    }
}

private struct CompanionNumberField: View {
    let title: String
    var example: String = ""
    @Binding var value: String
    var wholeNumber = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            TextField(example, text: $value)
                .keyboardType(wholeNumber ? .numberPad : .decimalPad)
                .font(MotoTheme.font(.body))
                .frame(minHeight: 44)
                .accessibilityLabel(title)
        }.padding(.vertical, 3)
    }
}

struct BikeProfileEditor: View {
    @ObservedObject var store: CompanionStore
    @ObservedObject var rides: RideRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var odometer = ""
    @State private var confirmReading = false
    @State private var prepared = false
    var body: some View {
        NavigationStack {
            Form {
                PixelSection("Как зовут твой байк") {
                    TextField("Например, Тахиро", text: $name)
                        .font(MotoTheme.font(.body)).frame(minHeight: 44)
                        .accessibilityLabel("Название мотоцикла")
                }
                PixelSection("Пробег с приборки") {
                    CompanionNumberField(title: "Одометр, км", example: "Например, 26 500", value: $odometer)
                    Text("Укажи фактическое показание. От него отдельно считаем примерный пробег по следующим записанным поездкам.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    if !odometer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(confirmReading ? "Показание будет подтверждено при сохранении" : "Подтвердить это показание сейчас") {
                            confirmReading = true
                        }
                        .font(MotoTheme.font(.subheadline))
                    }
                    if let recorded = CompanionData(fuelEntries: store.data.fuelEntries,
                                                    serviceTasks: store.data.serviceTasks).currentOdometerKm {
                        Text(String(format: "В записях уже есть %.0f км. Если там ошибка, исправь соответствующую заправку или обслуживание.", recorded))
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }
                }
                if let error = store.error { Text(error).foregroundStyle(MotoTheme.accent) }
            }.font(MotoTheme.font(.body)).navigationTitle("Мой байк").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.font(MotoTheme.font(.body)) }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") {
                        guard odometer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || decimal(odometer) != nil else {
                            store.error = "Укажи пробег числом."; return
                        }
                        let reading = decimal(odometer)
                        let snapshot = currentRideSnapshot(rides)
                        let recordedAt = Date()
                        if store.save({
                            $0.bikeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if $0.odometerKm != reading || confirmReading {
                                $0.odometerRecordedAt = reading == nil ? nil : recordedAt
                                $0.odometerRideSnapshot = reading == nil ? nil : snapshot
                            }
                            $0.odometerKm = reading
                        }) { dismiss() }
                    }.font(MotoTheme.font(.body)) }
                }
                .onAppear {
                    guard !prepared else { return }; prepared = true
                    name = store.data.bikeName; odometer = numberText(store.data.odometerKm)
                }
        }
    }
}

private struct FuelHistoryView: View {
    @ObservedObject var store: CompanionStore
    @ObservedObject var rides: RideRecorder
    @State private var selected: FuelEntry?
    @State private var adding = false
    var body: some View {
        List {
            ForEach(store.data.fuelEntries.sorted { $0.date > $1.date }) { fuel in
                Button { selected = fuel } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(fuel.date.formatted(date: .abbreviated, time: .shortened))
                            .font(MotoTheme.font(.body))
                        Text(fuelAmountText(fuel) + String(format: " · %@%.0f км", fuel.hasInstrumentOdometer ? "" : "≈ ", fuel.odometerKm)
                             + (fuel.fullTank ? " · полный бак" : " · долив"))
                            .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                        if let cost = fuel.cost { Text(String(format: "%.0f ₽", cost)).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary) }
                    }.padding(.vertical, 4)
                }.tint(.primary)
            }
            if store.data.fuelEntries.isEmpty { Text("Здесь появятся твои заправки.").foregroundStyle(MotoTheme.secondary) }
        }.font(MotoTheme.font(.body)).navigationTitle("Заправки").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(MotoTheme.background)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Добавить") { adding = true }.font(MotoTheme.font(.body)) } }
            .sheet(item: $selected) { FuelEditor(store: store, rides: rides, entry: $0) }
            .sheet(isPresented: $adding) { FuelEditor(store: store, rides: rides, entry: nil) }
    }
}

struct FuelEditor: View {
    @ObservedObject var store: CompanionStore
    @ObservedObject var rides: RideRecorder
    let entry: FuelEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var dateEdited = false
    @State private var odometer = ""
    @State private var liters = ""
    @State private var cost = ""
    @State private var full = true
    @State private var delete = false
    @State private var prepared = false
    private var odometerEstimate: OdometerEstimate? {
        store.data.estimatedOdometer(from: recordedTrips(rides))
    }
    var body: some View {
        NavigationStack {
            Form {
                PixelDateField(title: "Дата", selection: Binding(get: { date }, set: {
                    date = $0
                    dateEdited = true
                }), includesTime: true)
                CompanionNumberField(title: "Одометр с приборки, км", example: "Если не знаешь, оставь пустым", value: $odometer)
                if let entry, !entry.hasInstrumentOdometer {
                    Text(String(format: "Пустое поле: оставим сохранённую оценку ≈ %.0f км. Чтобы уточнить, введи пробег с приборки.", entry.odometerKm))
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                } else if let estimate = odometerEstimate {
                    Text(String(format: "Пустое поле: сохраним ≈ %.0f км по GPS и отметим как оценку. Проверь и исправь позже по приборке.", estimate.kilometers))
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                } else {
                    Text("Для заправки нужен пробег с приборки. После нового показания приложение сможет показывать примерный общий пробег по записанным поездкам.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                if rides.active != nil {
                    Text("Сохранение заправки не завершит запись поездки.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                Toggle("До полного бака", isOn: $full)
                CompanionNumberField(title: full ? "Залито, л · необязательно" : "Залито, л", value: $liters)
                CompanionNumberField(title: "Стоимость, ₽ · необязательно", value: $cost)
                Text(full
                     ? "Не помнишь литры — оставь поле пустым. Сохраним полный бак и пробег. Объём бака не подставляем: он не равен количеству залитого топлива."
                     : "Для долива укажи залитые литры. Для расхода нужны все заправки между двумя полными баками.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                if entry != nil { Button("Удалить заправку", role: .destructive) { delete = true } }
                if let error = store.error { Text(error).foregroundStyle(MotoTheme.accent) }
            }.font(MotoTheme.font(.body)).navigationTitle("Заправка").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.font(MotoTheme.font(.body)) }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") {
                        let savedAt = Date()
                        let fuelDate = entry == nil && !dateEdited ? savedAt : date
                        let enteredKm = decimal(odometer)
                        let blankOdometer = odometer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let estimatedKm = entry?.odometerSource == .gpsEstimate ? entry?.odometerKm : odometerEstimate?.kilometers
                        if blankOdometer, let entry, !entry.hasInstrumentOdometer,
                           abs(fuelDate.timeIntervalSince(entry.date)) > 60 {
                            store.error = "Для изменения даты оценочной заправки укажи пробег с приборки. Старая оценка GPS относится к прежнему времени."
                            return
                        }
                        if blankOdometer && entry?.odometerSource != .gpsEstimate && abs(savedAt.timeIntervalSince(fuelDate)) > 300 {
                            store.error = "Для заправки в другое время укажи пробег с приборки: текущая оценка GPS относится к настоящему моменту."
                            return
                        }
                        guard let km = enteredKm ?? (blankOdometer ? estimatedKm : nil),
                              (full && liters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || decimal(liters) != nil,
                              cost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || decimal(cost) != nil else {
                            store.error = "Проверь пробег, литры и стоимость. Если нет показания с приборки, сначала обнови пробег для оценки GPS."; return
                        }
                        let source: FuelOdometerSource = blankOdometer ? .gpsEstimate : .instrument
                        let snapshot: RideDistanceSnapshot?
                        if source == .instrument {
                            if let entry, entry.hasInstrumentOdometer, entry.odometerKm == km,
                               abs(fuelDate.timeIntervalSince(entry.date)) <= 60 {
                                snapshot = entry.rideSnapshot
                            } else if abs(savedAt.timeIntervalSince(fuelDate)) < 300 {
                                snapshot = currentRideSnapshot(rides)
                            } else { snapshot = nil }
                        } else { snapshot = nil }
                        let fuel = FuelEntry(id: entry?.id ?? UUID(), date: fuelDate, odometerKm: km,
                                             liters: decimal(liters), cost: decimal(cost), fullTank: full,
                                             odometerSource: source, rideSnapshot: snapshot)
                        if store.save({ data in
                            data.fuelEntries.removeAll { $0.id == fuel.id }; data.fuelEntries.append(fuel)
                        }) { dismiss() }
                    }.font(MotoTheme.font(.body)) }
                }
                .onAppear {
                    guard !prepared else { return }; prepared = true
                    date = entry?.date ?? Date()
                    odometer = entry?.hasInstrumentOdometer == true ? numberText(entry?.odometerKm) : ""
                    liters = numberText(entry?.liters); cost = numberText(entry?.cost); full = entry?.fullTank ?? true
                }
                .pixelConfirmationDialog("Удалить эту заправку? Расход будет пересчитан.", isPresented: $delete, titleVisibility: .visible) {
                    Button("Удалить", role: .destructive) {
                        if store.save({ $0.fuelEntries.removeAll { $0.id == entry?.id } }) { dismiss() }
                    }
                }
        }
    }
}

struct ServiceEditor: View {
    @ObservedObject var store: CompanionStore
    let task: ServiceTask?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date()
    @State private var knowsDate = false
    @State private var calendarInterval = false
    @State private var odometer = ""
    @State private var km = ""
    @State private var usesRange = false
    @State private var startKm = ""
    @State private var months = ""
    @State private var delete = false
    @State private var prepared = false

    private var preview: ServiceTask? {
        guard let reading = decimal(odometer),
              !usesRange || (decimal(startKm) != nil && decimal(km) != nil) else { return nil }
        return ServiceTask(title: title, lastDoneAt: knowsDate ? date : nil,
                           lastDoneOdometerKm: reading, intervalKm: decimal(km),
                           intervalStartKm: usesRange ? decimal(startKm) : nil,
                           intervalMonths: calendarInterval ? Int(months) : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                PixelSection("Что обслуживать") {
                    TextField("Например, масло и фильтр", text: $title)
                        .font(MotoTheme.font(.body)).frame(minHeight: 44)
                        .accessibilityLabel("Название обслуживания")
                }
                PixelSection("Последнее обслуживание") {
                    CompanionNumberField(title: "На каком пробеге, км", example: "Например, 23 000", value: $odometer)
                    Toggle("Помню дату", isOn: $knowsDate)
                    if knowsDate { PixelDateField(title: "Дата", selection: $date) }
                    if task != nil {
                        Button("Выполнено сегодня") {
                            knowsDate = true; date = Date(); odometer = numberText(store.data.currentOdometerKm)
                        }
                        Text("После выполнения проверь пробег и сохрани — следующий срок сдвинется.")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }
                }
                PixelSection("Как часто повторять") {
                    Toggle("Диапазон пробега", isOn: $usesRange)
                    if usesRange {
                        CompanionNumberField(title: "От, км после обслуживания", example: "Например, 3 000", value: $startKm)
                        CompanionNumberField(title: "До, км после обслуживания", example: "Например, 4 000", value: $km)
                        Text("Жёлтое напоминание — с начала диапазона, красное — когда достигнут конец. Интервал отсчитывается от последнего обслуживания.")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    } else {
                        CompanionNumberField(title: "Интервал, км", example: "Например, 3 000", value: $km)
                    }
                    Toggle("Учитывать срок в месяцах", isOn: $calendarInterval)
                    if calendarInterval {
                        CompanionNumberField(title: "Интервал, месяцев", example: "Например, 12", value: $months, wholeNumber: true)
                        if !knowsDate {
                            Text("Для срока в месяцах укажи дату последнего обслуживания. Для пробега дата не нужна.")
                                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                        }
                    }
                }
                if let preview, (try? preview.validate()) != nil {
                    PixelSection("Следующий раз") { ServiceScheduleText(task: preview, odometerKm: store.data.currentOdometerKm) }
                }
                if task != nil { Button("Удалить обслуживание", role: .destructive) { delete = true } }
                if let error = store.error { Text(error).foregroundStyle(MotoTheme.accent) }
            }.font(MotoTheme.font(.body)).navigationTitle("Обслуживание").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.font(MotoTheme.font(.body)) }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save).font(MotoTheme.font(.body)) }
                }
                .onAppear {
                    guard !prepared else { return }; prepared = true
                    title = task?.title ?? ""; date = task?.lastDoneAt ?? Date()
                    knowsDate = task?.lastDoneAt != nil; calendarInterval = task?.intervalMonths != nil
                    odometer = numberText(task?.lastDoneOdometerKm)
                    km = numberText(task?.intervalKm); months = task?.intervalMonths.map(String.init) ?? ""
                    usesRange = task?.intervalStartKm != nil; startKm = numberText(task?.intervalStartKm)
                }
                .pixelConfirmationDialog("Удалить это обслуживание?", isPresented: $delete, titleVisibility: .visible) {
                    Button("Удалить", role: .destructive) {
                        if store.save({ $0.serviceTasks.removeAll { $0.id == task?.id } }) { dismiss() }
                    }
                }
        }
    }

    private func save() {
        guard let odo = decimal(odometer),
              km.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || decimal(km) != nil,
              !usesRange || (decimal(startKm) != nil && decimal(km) != nil),
              !calendarInterval || Int(months) != nil else {
            store.error = "Проверь пробег и интервалы."; return
        }
        let value = ServiceTask(id: task?.id ?? UUID(), title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                lastDoneAt: knowsDate ? date : nil, lastDoneOdometerKm: odo,
                                intervalKm: decimal(km), intervalStartKm: usesRange ? decimal(startKm) : nil,
                                intervalMonths: calendarInterval ? Int(months) : nil)
        if store.save({ data in
            if let i = data.serviceTasks.firstIndex(where: { $0.id == value.id }) { data.serviceTasks[i] = value }
            else { data.serviceTasks.append(value) }
        }) { dismiss() }
    }
}

struct RideStatisticsView: View {
    @ObservedObject var rides: RideRecorder
    private var complete: [RideSummary] { rides.history.filter { $0.endedAt != nil } }
    private func period(_ component: Calendar.Component) -> [RideSummary] {
        guard let range = Calendar.current.dateInterval(of: component, for: Date()) else { return [] }
        return complete.filter { range.contains($0.startedAt) }
    }
    private var named: [(String, [RideSummary])] {
        Dictionary(grouping: complete.filter { !($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    var body: some View {
        List {
            summary("Эта неделя", period(.weekOfYear))
            summary("Этот месяц", period(.month))
            summary("Все сохранённые поездки", complete)
            PixelSection("Привычные маршруты") {
                Text("Дай поездкам одинаковое название в истории, например «На работу». Сравнение учитывает всё время записи, включая остановки.").font(MotoTheme.font(.caption))
                ForEach(named, id: \.0) { title, group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title.capitalized).font(MotoTheme.font(.headline))
                        let average = group.reduce(0) { $0 + $1.elapsed } / Double(group.count)
                        Text("Среднее: \(minutes(average)) · поездок: \(group.count)")
                        if let last = group.max(by: { $0.startedAt < $1.startedAt }) {
                            Text("Последняя: " + minutes(last.elapsed)).foregroundStyle(MotoTheme.secondary)
                        }
                    }
                }
            }
            Text("Расстояние рассчитано по принятым точкам GPS. Пропуски не входят в километраж; это не одометр мотоцикла.").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
        }.font(MotoTheme.font(.body)).scrollContentBackground(.hidden).background(MotoTheme.background).navigationTitle("Сводка поездок")
        .refreshable { await rides.refreshHistory() }
    }
    private func summary(_ title: String, _ group: [RideSummary]) -> some View {
        PixelSection(title) {
            LabeledContent("Поездок", value: String(group.count))
            LabeledContent("Расстояние GPS", value: String(format: "%.1f км", group.reduce(0) { $0 + $1.distanceMeters } / 1000))
            LabeledContent("Время записи", value: minutes(group.reduce(0) { $0 + $1.elapsed }))
        }
    }
    private func minutes(_ seconds: Double) -> String {
        let n = max(0, Int(seconds / 60)); return "\(n / 60) ч \(n % 60) мин"
    }
}
