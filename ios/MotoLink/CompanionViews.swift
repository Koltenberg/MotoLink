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

    func enableReminders() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.notificationStatus = error?.localizedDescription ?? (granted
                    ? "Напоминания по датам включены. Пробег проверяется в приложении."
                    : "Уведомления выключены. Сроки остаются в приложении.")
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
    guard let number = Double(cleaned), number.isFinite else { return nil }
    return number
}

private func numberText(_ value: Double?) -> String {
    value.map { String($0) } ?? ""
}

struct CompanionHomeCard: View {
    @ObservedObject var store: CompanionStore
    @ObservedObject var rides: RideRecorder
    var body: some View {
        NavigationLink { CompanionView(store: store, rides: rides) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Мой мотоцикл", systemImage: "wrench.and.screwdriver")
                        .font(MotoTheme.font(.headline))
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                if let odo = store.data.currentOdometerKm {
                    Text(String(format: "%.0f км · %@", odo, store.data.bikeName))
                        .font(.system(.title3).monospacedDigit())
                } else { Text("Пробег, заправки и обслуживание").font(.system(.subheadline)) }
                let due = store.data.serviceTasks.filter { $0.isDue(odometerKm: store.data.currentOdometerKm) }
                if !due.isEmpty {
                    Text("Пора проверить: " + due.map(\.title).joined(separator: ", "))
                        .font(.system(.subheadline)).foregroundStyle(.orange)
                } else if let fuel = store.data.fuelEntries.max(by: { $0.date < $1.date }) {
                    Text("Заправка: " + fuel.date.formatted(date: .abbreviated, time: .omitted)
                         + String(format: " · %.1f л", fuel.liters)).font(.system(.subheadline)).foregroundStyle(.secondary)
                }
                if let error = store.error { Text(error).font(.system(.caption)).foregroundStyle(.orange) }
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
    @State private var selectedFuel: FuelEntry?
    @State private var selectedService: ServiceTask?

    var body: some View {
        List {
            Section("Мой мотоцикл") {
                Text(store.data.bikeName).font(MotoTheme.font(.headline))
                LabeledContent("Пробег по записям", value: store.data.currentOdometerKm.map { String(format: "%.0f км", $0) } ?? "Не указан")
                Button("Указать пробег и название") { editingBike = true }
                Text("Пробег вводится с приборки. GPS-расстояние поездок хранится отдельно и не меняет одометр.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Заправки") {
                Button { newFuel = true } label: { Label("Добавить заправку", systemImage: "fuelpump") }
                if let consumption = store.data.fuelConsumptions.last {
                    LabeledContent("Последний расход", value: String(format: "%.2f л/100 км", consumption.litersPer100Km))
                    Text("Между полными баками · по внесённым заправкам. Для верного расчёта нужны все заправки.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Расход появится после двух заправок до полного бака. Промежуточные доливы тоже записывай.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.data.fuelEntries.sorted { $0.date > $1.date }) { fuel in
                    Button { selectedFuel = fuel } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fuel.date.formatted(date: .abbreviated, time: .shortened))
                            Text(String(format: "%.1f л · %.0f км", fuel.liters, fuel.odometerKm)
                                 + (fuel.fullTank ? " · полный" : " · долив"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.tint(.primary)
                }
            }
            Section("Обслуживание") {
                Button { newService = true } label: { Label("Добавить задачу", systemImage: "wrench") }
                ForEach(store.data.serviceTasks) { task in
                    Button { selectedService = task } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(task.title)
                                if task.isDue(odometerKm: store.data.currentOdometerKm) {
                                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                                }
                            }
                            if let km = task.dueOdometerKm { Text(String(format: "Следующее: %.0f км", km)).font(.subheadline).foregroundStyle(.secondary) }
                            if let date = task.dueDate() { Text("До " + date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }.tint(.primary)
                }
                Text("Масло, цепь, тормозная жидкость — добавь нужные задачи и интервалы из руководства своего байка. По пробегу и дате действует более ранний срок.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Включить напоминания по датам") { store.enableReminders() }
                if let status = store.notificationStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                NavigationLink("Сводка поездок") { RideStatisticsView(rides: rides) }
                NavigationLink("История поездок") { RideHistoryView(rides: rides) }
            }
            if let error = store.error { Section { Text(error).foregroundStyle(.orange) } }
        }
        .font(.system(.body))
        .scrollContentBackground(.hidden).background(MotoTheme.background)
        .navigationTitle("Мой мотоцикл")
        .sheet(isPresented: $editingBike) { BikeProfileEditor(store: store) }
        .sheet(isPresented: $newFuel) { FuelEditor(store: store, entry: nil) }
        .sheet(item: $selectedFuel) { FuelEditor(store: store, entry: $0) }
        .sheet(isPresented: $newService) { ServiceEditor(store: store, task: nil) }
        .sheet(item: $selectedService) { ServiceEditor(store: store, task: $0) }
    }
}

private struct BikeProfileEditor: View {
    @ObservedObject var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var odometer = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Название мотоцикла", text: $name)
                TextField("Пробег с приборки, км", text: $odometer).keyboardType(.decimalPad)
                Text("Записи заправок и обслуживания тоже содержат пробег. Здесь нельзя понизить показание ниже этих записей — сначала исправь ошибочную запись.").font(.caption)
                if let error = store.error { Text(error).foregroundStyle(.orange) }
            }.font(.system(.body)).navigationTitle("Мотоцикл")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") {
                        guard odometer.isEmpty || decimal(odometer) != nil else { store.error = "Укажи пробег числом."; return }
                        if store.save({ $0.bikeName = name; $0.odometerKm = decimal(odometer) }) { dismiss() }
                    } }
                }
                .onAppear { name = store.data.bikeName; odometer = numberText(store.data.odometerKm) }
        }
    }
}

private struct FuelEditor: View {
    @ObservedObject var store: CompanionStore
    let entry: FuelEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var odometer = ""
    @State private var liters = ""
    @State private var cost = ""
    @State private var full = true
    @State private var delete = false
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Дата", selection: $date, in: ...Date())
                TextField("Одометр, км", text: $odometer).keyboardType(.decimalPad)
                TextField("Залито, литров", text: $liters).keyboardType(.decimalPad)
                TextField("Стоимость, ₽ (необязательно)", text: $cost).keyboardType(.decimalPad)
                Toggle("До полного бака", isOn: $full)
                Text("Отметка полного бака нужна для расчёта расхода. Уровень топлива и расход из байка пока не подтверждены.").font(.caption)
                if entry != nil { Button("Удалить заправку", role: .destructive) { delete = true } }
                if let error = store.error { Text(error).foregroundStyle(.orange) }
            }.font(.system(.body)).navigationTitle("Заправка")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") {
                        guard let km = decimal(odometer), let l = decimal(liters), cost.isEmpty || decimal(cost) != nil else {
                            store.error = "Проверь пробег, литры и стоимость: нужны числа."; return
                        }
                        let fuel = FuelEntry(id: entry?.id ?? UUID(), date: date, odometerKm: km,
                                             liters: l, cost: decimal(cost), fullTank: full)
                        if store.save({ data in
                            data.fuelEntries.removeAll { $0.id == fuel.id }; data.fuelEntries.append(fuel)
                        }) { dismiss() }
                    } }
                }
                .onAppear {
                    date = entry?.date ?? Date(); odometer = numberText(entry?.odometerKm ?? store.data.currentOdometerKm)
                    liters = numberText(entry?.liters); cost = numberText(entry?.cost); full = entry?.fullTank ?? true
                }
                .confirmationDialog("Удалить эту заправку? Расход будет пересчитан.", isPresented: $delete, titleVisibility: .visible) {
                    Button("Удалить", role: .destructive) {
                        if store.save({ $0.fuelEntries.removeAll { $0.id == entry?.id } }) { dismiss() }
                    }
                }
        }
    }
}

private struct ServiceEditor: View {
    @ObservedObject var store: CompanionStore
    let task: ServiceTask?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date()
    @State private var odometer = ""
    @State private var km = ""
    @State private var months = ""
    @State private var delete = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Например, масло или чистка цепи", text: $title)
                Section("Когда выполнено последний раз") {
                    DatePicker("Дата", selection: $date, in: ...Date(), displayedComponents: .date)
                    TextField("Одометр, км", text: $odometer).keyboardType(.decimalPad)
                    if task != nil {
                        Button("Выполнено сегодня") { date = Date(); odometer = numberText(store.data.currentOdometerKm) }
                        Text("Проверь пробег и нажми «Сохранить», чтобы отсчитать следующий срок.").font(.caption)
                    }
                }
                Section("Повторять — укажи хотя бы один интервал") {
                    TextField("Через километры", text: $km).keyboardType(.decimalPad)
                    TextField("Через месяцы", text: $months).keyboardType(.numberPad)
                }
                if task != nil { Button("Удалить задачу", role: .destructive) { delete = true } }
                if let error = store.error { Text(error).foregroundStyle(.orange) }
            }.font(.system(.body)).navigationTitle("Обслуживание")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Сохранить") {
                        guard let odo = decimal(odometer), km.isEmpty || decimal(km) != nil,
                              months.isEmpty || Int(months) != nil else { store.error = "Проверь пробег и интервалы."; return }
                        let value = ServiceTask(id: task?.id ?? UUID(), title: title, lastDoneAt: date,
                            lastDoneOdometerKm: odo, intervalKm: decimal(km), intervalMonths: Int(months))
                        if store.save({ data in
                            if let i = data.serviceTasks.firstIndex(where: { $0.id == value.id }) { data.serviceTasks[i] = value }
                            else { data.serviceTasks.append(value) }
                        }) { dismiss() }
                    } }
                }
                .onAppear {
                    title = task?.title ?? ""; date = task?.lastDoneAt ?? Date()
                    odometer = numberText(task?.lastDoneOdometerKm ?? store.data.currentOdometerKm)
                    km = numberText(task?.intervalKm); months = task?.intervalMonths.map(String.init) ?? ""
                }
                .confirmationDialog("Удалить задачу обслуживания?", isPresented: $delete, titleVisibility: .visible) {
                    Button("Удалить", role: .destructive) { if store.save({ $0.serviceTasks.removeAll { $0.id == task?.id } }) { dismiss() } }
                }
        }
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
            Section("Привычные маршруты") {
                Text("Дай поездкам одинаковое название в истории, например «На работу». Сравнение учитывает всё время записи, включая остановки.").font(.caption)
                ForEach(named, id: \.0) { title, group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title.capitalized).font(.headline)
                        let average = group.reduce(0) { $0 + $1.elapsed } / Double(group.count)
                        Text("Среднее: \(minutes(average)) · поездок: \(group.count)")
                        if let last = group.max(by: { $0.startedAt < $1.startedAt }) {
                            Text("Последняя: " + minutes(last.elapsed)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("Расстояние рассчитано по принятым точкам GPS. Пропуски не входят в километраж; это не одометр мотоцикла.").font(.caption).foregroundStyle(.secondary)
        }.font(.system(.body)).scrollContentBackground(.hidden).background(MotoTheme.background).navigationTitle("Сводка поездок")
    }
    private func summary(_ title: String, _ group: [RideSummary]) -> some View {
        Section(title) {
            LabeledContent("Поездок", value: String(group.count))
            LabeledContent("Расстояние GPS", value: String(format: "%.1f км", group.reduce(0) { $0 + $1.distanceMeters } / 1000))
            LabeledContent("Время записи", value: minutes(group.reduce(0) { $0 + $1.elapsed }))
        }
    }
    private func minutes(_ seconds: Double) -> String {
        let n = max(0, Int(seconds / 60)); return "\(n / 60) ч \(n % 60) мин"
    }
}
