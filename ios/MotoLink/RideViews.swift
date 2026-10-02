import CoreLocation
import SwiftUI

struct RidePanel: View {
    @ObservedObject var rides: RideRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Поездки").font(MotoTheme.font(.title2))
                Spacer()
                NavigationLink { RideHistoryView(rides: rides) } label: {
                    Label("История", systemImage: "clock.arrow.circlepath")
                }
            }
            Text(rides.status).font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            if let ride = rides.active {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            value("РАССТОЯНИЕ GPS", String(format: "%.2f км", ride.distanceMeters / 1000))
                            Spacer()
                            value("ВРЕМЯ", duration(context.date.timeIntervalSince(ride.startedAt)))
                            Spacer()
                            value("СКОРОСТЬ GPS", freshSpeed(at: context.date))
                        }
                        if let gpsStatus = rides.gpsStatus(at: context.date) {
                            Label(gpsStatus, systemImage: "location.slash").font(MotoTheme.font(.caption)).foregroundStyle(.orange)
                        }
                    }
                }
                if !rides.gaps.isEmpty {
                    Text("Пропусков GPS: \(rides.gaps.count). Неизвестный путь не входит в расстояние GPS. Запись данных байка от GPS не зависит.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                if !rides.points.isEmpty {
                    LocalRouteOverview(points: rides.points).frame(height: 200).clipShape(PixelFrame())
                } else {
                    Text("Ожидаем точную геопозицию. Маршрут и скорость поступают с iPhone.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                HStack {
                    Button("Завершить поездку", role: .destructive) { rides.stop() }.buttonStyle(PixelButtonStyle())
                    Button("Экспорт") { rides.export(ride) }.buttonStyle(PixelButtonStyle()).disabled(rides.exporting)
                }
            } else {
                Button { rides.start() } label: {
                    Label("Начать поездку", systemImage: "record.circle").frame(maxWidth: .infinity)
                }.buttonStyle(PixelButtonStyle(prominent: true))
                Text("Ручная запись GPS работает и без связи с байком.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            Toggle("Записывать при подключении", isOn: Binding(get: { rides.autoRecord }, set: rides.setAutoRecord))
                .font(MotoTheme.font(.subheadline))
            Text("Для автозаписи включи также автоподключение к байку. Начало — появление BLE-связи; это не датчик зажигания. Завершение — через 2 минуты без связи, когда приложение выполняется. После смахивания приложения открой его снова.")
                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            if rides.autoRecord && rides.authorization != .authorizedAlways {
                Button("Разрешить геопозицию для автозаписи") { rides.requestBackgroundPermission() }
                    .font(MotoTheme.font(.subheadline))
                Text("В системных настройках нужен доступ «Всегда». Уже начатую вручную поездку можно записывать с доступом «При использовании».")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            if let error = rides.error {
                Text("Ошибка сохранения: \(error)").font(MotoTheme.font(.caption)).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .pixelPanel()
    }
    private func freshSpeed(at date: Date) -> String {
        guard let time = rides.lastLocationAt, date.timeIntervalSince(time) < GPSContinuity.staleInterval,
              let speed = rides.speedMS else { return "—" }
        return String(format: "%.0f км/ч", speed * 3.6)
    }
    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            Text(text).font(MotoTheme.font(.headline))
        }
    }
}

struct MotorcycleMeasurementsView: View {
    @ObservedObject var bluetooth: MotorcycleBluetooth
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Данные мотоцикла").font(MotoTheme.font(.title2))
            if bluetooth.measurements.isEmpty {
                Text("Значения появятся после ответа байка. Наличие показателя в списке возможностей не означает, что его значение уже получено.")
                    .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bluetooth.measurements) { measurement in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(measurement.label)
                                Spacer()
                                Text(String(format: measurement.unit == "В" ? "%.2f %@" : "%.0f %@",
                                            measurement.value, measurement.unit)).font(MotoTheme.font(.title3))
                            }
                            HStack {
                                Text(context.date.timeIntervalSince(measurement.timestamp) > 15 ? "Последний замер" : "Получено")
                                Text(measurement.timestamp, style: .time).monospacedDigit()
                            }.font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                            Text(measurement.source).font(MotoTheme.font(.caption2)).foregroundStyle(MotoTheme.secondary)
                        }
                    }
                }
            }
            if !bluetooth.capabilities.isEmpty {
                Text("Поддерживается: " + bluetooth.capabilities.filter(\.supported).map(\.label).joined(separator: ", "))
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
        }
        .padding(18)
        .pixelPanel()
    }
}

struct RideHistoryView: View {
    @ObservedObject var rides: RideRecorder
    @State private var visibleLimit = 30
    @State private var pendingDelete: RideSummary?
    @State private var showingDelete = false
    @State private var showingClear = false
    @State private var clearIDs: [UUID] = []

    private var busy: Bool { rides.changingHistory || rides.exporting || rides.finishingRide }
    private var totalDistance: Double {
        rides.history.reduce(0) { total, ride in
            total + (ride.distanceMeters.isFinite ? max(0, ride.distanceMeters) : 0)
        }
    }

    private var months: [RideHistoryMonth] {
        let latest = rides.history.sorted { $0.startedAt > $1.startedAt }.prefix(visibleLimit)
        let grouped = Dictionary(grouping: latest) {
            Calendar.current.dateInterval(of: .month, for: $0.startedAt)?.start ?? $0.startedAt
        }
        return grouped.keys.sorted(by: >).map { RideHistoryMonth(month: $0, rides: grouped[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                Text(rides.history.isEmpty ? "Завершённые поездки появятся здесь." : "Все поездки хранятся на этом iPhone. Для просмотра и экспорта интернет не нужен.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                if !rides.history.isEmpty {
                    Text(String(format: "Поездок: %d · %.1f км", rides.history.count, totalDistance / 1000))
                        .font(MotoTheme.font(.headline))
                    Text("По записям GPS, без неизвестных участков. Это не одометр мотоцикла.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    Text("Показано \(min(visibleLimit, rides.history.count)) из \(rides.history.count)")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                if rides.changingHistory { ProgressView("Обновляем историю…") }
                if let failure = rides.historyError { Text(failure).font(MotoTheme.font(.caption)).foregroundStyle(.orange) }
                else if let status = rides.historyRefreshStatus {
                    Text(status).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
            }.listRowBackground(MotoTheme.background)
            ForEach(months) { group in
                Section {
                    ForEach(group.rides) { ride in
                        NavigationLink { RideDetailView(rides: rides, ride: ride) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                if let title = ride.title { Text(title).font(MotoTheme.font(.headline)) }
                                Text(ride.startedAt, format: .dateTime.day().month().hour().minute())
                                    .font(MotoTheme.font(.headline))
                                Text(String(format: "GPS %.2f км · %@", ride.distanceMeters / 1000, duration(ride.elapsed)))
                                    .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                        .listRowBackground(MotoTheme.background)
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = ride; showingDelete = true
                            } label: { Label("Удалить", systemImage: "trash") }
                            .disabled(busy)
                        }
                    }
                } header: {
                    Text(group.month, format: .dateTime.month(.wide).year())
                        .font(MotoTheme.font(.subheadline))
                }
            }
            if visibleLimit < rides.history.count {
                Button("Показать ещё 30") { visibleLimit += 30 }
                    .listRowBackground(MotoTheme.background)
            }
        }
        .font(MotoTheme.font(.body))
        .scrollContentBackground(.hidden).background(MotoTheme.background)
        .navigationTitle("Мои поездки")
        .refreshable { await rides.refreshHistory() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    clearIDs = rides.history.map(\.id); showingClear = true
                } label: { Image(systemName: "trash") }
                    .disabled(rides.history.isEmpty || busy)
                    .accessibilityLabel("Удалить завершённые поездки")
            }
        }
        .pixelConfirmationDialog("Удалить поездку?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Удалить поездку", role: .destructive) {
                if let ride = pendingDelete { rides.deleteCompletedRides([ride.id]) }
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Будут удалены маршрут, заметка и журнал этой поездки с iPhone. Копии, которые вы сохранили отдельно, останутся. Отменить удаление нельзя.")
        }
        .pixelConfirmationDialog("Очистить историю?", isPresented: $showingClear, titleVisibility: .visible) {
            Button("Удалить поездок: \(clearIDs.count)", role: .destructive) { rides.deleteCompletedRides(clearIDs) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все выбранные завершённые поездки и их журналы будут удалены с iPhone. Текущая запись и отдельно сохранённые копии останутся. Отменить удаление нельзя.")
        }
    }
}

private struct RideHistoryMonth: Identifiable {
    var id: Date { month }
    let month: Date
    let rides: [RideSummary]
}

struct RideDetailView: View {
    @ObservedObject var rides: RideRecorder
    let ride: RideSummary
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var showingDelete = false
    @State private var points: [TrackPoint] = []
    @State private var ranges: [RideMeasurementRange] = []
    @State private var trends: [RideTrend] = []
    @State private var selectedTrendID: String?
    @State private var gaps: [GPSGap] = []
    @State private var showGapBoundaries = false
    @State private var loading = true
    @State private var error: String?
    @State private var loadRequestID = UUID()

    var body: some View {
        let ride = rides.history.first(where: { $0.id == self.ride.id }) ?? self.ride
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loading { ProgressView("Открываем запись с iPhone…") }
                if let error { Text(error).foregroundStyle(.orange) }
                if let failure = rides.historyError { Text(failure).font(MotoTheme.font(.caption)).foregroundStyle(.orange) }
                if let title = ride.title { Text(title).font(MotoTheme.font(.title2)) }
                Text(ride.startedAt, format: .dateTime.day().month().year().hour().minute())
                    .font(MotoTheme.font(.title2))
                Text(String(format: "GPS %.2f км · %@", ride.distanceMeters / 1000, duration(ride.elapsed)))
                    .font(MotoTheme.font(.title3))
                if let note = ride.note {
                    Text(note).font(MotoTheme.font(.body)).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Text(ride.acceptedSpeedCount == 0 ? "Скорость GPS: нет надёжных замеров"
                     : String(format: "Максимальная скорость GPS: %.0f км/ч", ride.maxSpeedMS * 3.6))
                    .monospacedDigit()
                if ride.gpsSpeedQualityVersion == nil {
                    Text("Старая запись: скорость GPS могла содержать выбросы. Исходный журнал сохранён.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                if let coverage = ride.streamCoverage {
                    Text("Данные байка: \(duration(coverage.observedSeconds)) из \(duration(ride.elapsed))")
                        .font(MotoTheme.font(.headline))
                    Text(coverage.frameCount == 0 ? "За эту поездку данные движения не поступали."
                         : "Время, когда поступали данные движения. Пропуски связи не учитываются.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(coverage.frameCount == 0 ? Color.orange : MotoTheme.secondary)
                }
                if !points.isEmpty {
                    Text("Схема маршрута").font(MotoTheme.font(.title3))
                    LocalRouteOverview(points: points, showGapBoundaries: showGapBoundaries)
                        .frame(height: 280).clipShape(PixelFrame())
                    Text("Схема по записанным точкам, без загрузки карт. Красный — GPS; белая точка — конец записи.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    if gaps.contains(where: { $0.from != nil && $0.to != nil }) {
                        Toggle("Соединить границы пропусков", isOn: $showGapBoundaries)
                            .font(MotoTheme.font(.subheadline))
                        if showGapBoundaries {
                            Text("Оранжевый пунктир — прямая между известными точками, а не дорога. Он не входит в расстояние GPS.")
                                .font(MotoTheme.font(.caption)).foregroundStyle(.orange)
                        }
                    }
                } else if !loading && error == nil {
                    Text("Точек GPS нет. Данные мотоцикла и журнал доступны отдельно.")
                        .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                }
                if !gaps.isEmpty {
                    DisclosureGroup {
                        ForEach(gaps) { gap in GPSGapCard(gap: gap) }
                    } label: {
                        Text("Пропуски GPS: \(gaps.count)")
                            .font(MotoTheme.font(.headline))
                    }
                }
                Text("Расстояние и скорость здесь — по GPS iPhone. Неизвестные участки не входят в расстояние. Данные байка сохраняются независимо от GPS.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                if !trends.isEmpty {
                    Text("Графики поездки").font(MotoTheme.font(.title3))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(trends) { trend in
                                Button(trend.label) { selectedTrendID = trend.id }
                                    .buttonStyle(PixelButtonStyle(prominent: selectedTrendID == trend.id))
                            }
                        }
                    }
                    if let trend = trends.first(where: { $0.id == selectedTrendID }) ?? trends.first {
                        RideTrendChart(trend: trend, elapsed: ride.elapsed)
                            .frame(height: 226)
                            .clipShape(PixelFrame())
                        Text("Пустые участки — данные не поступали. График построен на iPhone без сети и не дорисовывает пропуски.")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }
                }
                if !ranges.isEmpty {
                    Text("Показатели за поездку").font(MotoTheme.font(.title3))
                    ForEach(ranges) { range in
                        HStack(alignment: .firstTextBaseline) {
                            Text(range.label)
                            Spacer(minLength: 12)
                            Text(String(format: "%.2f–%.2f %@", range.minimum, range.maximum, range.unit))
                                .monospacedDigit().multilineTextAlignment(.trailing)
                        }.font(MotoTheme.font(.subheadline))
                    }
                }
                DisclosureGroup("Подробности записи") {
                    if let version = ride.recordedAppVersion {
                        Text("Записано в Moto Link \(version) · сборка \(ride.recordedAppBuild ?? "—")")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }
                    Text("Точек GPS: \(points.count). Измерений байка: \(ride.telemetryCount). Разрывов процесса: \(ride.interruptionCount).")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    Text("Автостарт означает подключение Bluetooth, а не включение зажигания. Просмотр этой поездки не включает GPS и не отправляет координаты в интернет.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }.font(MotoTheme.font(.subheadline))
                Button { rides.export(ride) } label: { Label("Сохранить единый журнал", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PixelButtonStyle()).disabled(rides.exporting || rides.changingHistory || loading || error != nil)
                Button { rides.exportGPX(ride) } label: { Label("Отдельно: GPX и маршрут", systemImage: "map") }
                    .buttonStyle(PixelButtonStyle()).disabled(rides.exporting || rides.changingHistory || loading || error != nil)
                Button(role: .destructive) { showingDelete = true } label: {
                    Label("Удалить поездку", systemImage: "trash")
                }.buttonStyle(PixelButtonStyle())
                    .disabled(rides.exporting || rides.changingHistory || rides.active?.id == ride.id)
            }.padding(20)
        }
        .font(MotoTheme.font(.body))
        .background(MotoTheme.background)
        .navigationTitle("Поездка")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Изменить") { showingEditor = true }.font(MotoTheme.font(.body))
                    .disabled(rides.changingHistory || rides.exporting || rides.active?.id == ride.id)
            }
        }
        .sheet(isPresented: $showingEditor) { RideMetadataEditor(rides: rides, ride: ride) }
        .pixelConfirmationDialog("Удалить поездку?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Удалить поездку", role: .destructive) {
                rides.deleteCompletedRides([ride.id]) { success in if success { dismiss() } }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Маршрут, заметка и журнал этой поездки будут удалены с iPhone. Отдельно сохранённые копии останутся. Отменить удаление нельзя.")
        }
        .task(id: ride.id) {
            let requestID = UUID()
            loadRequestID = requestID
            loading = true
            error = nil
            points = []; ranges = []; trends = []; gaps = []
            selectedTrendID = nil
            showGapBoundaries = false
            rides.load(ride) { result in
                guard loadRequestID == requestID else { return }
                loading = false
                switch result {
                case .success(let records):
                    points = records.compactMap(\.point)
                    ranges = RideMeasurementRange.summarize(records)
                    trends = RideTrend.summarize(records, ride: ride)
                    selectedTrendID = trends.first?.id
                    gaps = gpsGaps(in: records, ride: ride)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
        .onDisappear { loadRequestID = UUID() }
    }
}

private struct RideMetadataEditor: View {
    @ObservedObject var rides: RideRecorder
    let ride: RideSummary
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String

    init(rides: RideRecorder, ride: RideSummary) {
        self.rides = rides
        self.ride = ride
        _title = State(initialValue: ride.title ?? "")
        _note = State(initialValue: ride.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                PixelSection("Название") {
                    TextField("Например, до работы", text: $title)
                        .font(MotoTheme.font(.body)).frame(minHeight: 44)
                        .onChange(of: title) { value in if value.count > 80 { title = String(value.prefix(80)) } }
                }
                PixelSection("Заметка") {
                    TextEditor(text: $note).font(MotoTheme.font(.body)).frame(minHeight: 150)
                        .onChange(of: note) { value in if value.count > 4000 { note = String(value.prefix(4000)) } }
                    Text("\(note.count) / 4000").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                Section {
                    Text("Название и заметка не меняют маршрут, показатели и исходный журнал.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    if let failure = rides.historyError { Text(failure).font(MotoTheme.font(.caption)).foregroundStyle(.orange) }
                    if rides.changingHistory { ProgressView("Сохраняем…") }
                }
            }
            .font(MotoTheme.font(.body))
            .navigationTitle("Изменить поездку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.font(MotoTheme.font(.body)).disabled(rides.changingHistory) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        rides.updateRideMetadata(ride, title: title, note: note) { success in if success { dismiss() } }
                    }.font(MotoTheme.font(.body)).disabled(rides.changingHistory || rides.exporting)
                }
            }
            .interactiveDismissDisabled(rides.changingHistory)
        }
    }
}

/// Keep only extrema in view state, rather than retaining every telemetry sample
/// a second time after a detail file is loaded. The exported journal is unchanged.
private struct RideMeasurementRange: Identifiable {
    let id: String
    let label: String
    let unit: String
    var minimum: Double
    var maximum: Double

    static func summarize(_ records: [RideRecord]) -> [Self] {
        var values: [String: Self] = [:]
        for record in records {
            guard let measurement = record.measurement, measurement.value.isFinite else { continue }
            if var range = values[measurement.id] {
                range.minimum = min(range.minimum, measurement.value)
                range.maximum = max(range.maximum, measurement.value)
                values[measurement.id] = range
            } else {
                values[measurement.id] = Self(id: measurement.id, label: measurement.label, unit: measurement.unit,
                    minimum: measurement.value, maximum: measurement.value)
            }
        }
        return values.values.sorted { $0.id < $1.id }
    }
}

/// A fixed-size summary for the on-device graphs. Large JSONL rides do not
/// leave another copy of every measurement in SwiftUI state. Empty time bins
/// remain empty, so a Bluetooth or GPS outage cannot look like valid data.
private struct RideTrend: Identifiable {
    let id: String
    let label: String
    let unit: String
    let buckets: [RideTrendBucket]
    let gapBins: [Bool]
    let gapCount: Int
    let minimum: Double
    let maximum: Double

    static func summarize(_ records: [RideRecord], ride: RideSummary) -> [Self] {
        let definitions: [(id: String, label: String, unit: String)] = [
            ("gps_speed", "Скорость GPS", "км/ч"),
            ("wheel_speed", "Скорость байка", "км/ч"),
            ("engine_speed", "Обороты", "об/мин"),
            ("gear_position", "Передача", ""),
            ("throttle_position", "Дроссель", "%"),
            ("engine_water_temperature", "Охлаждение", "°C"),
            ("inlet_air_temperature", "Воздух", "°C")
        ]
        let indices = Dictionary(uniqueKeysWithValues: definitions.enumerated().map { ($0.element.id, $0.offset) })
        let binCount = 160
        let span = max(1, (ride.endedAt ?? ride.lastSavedAt).timeIntervalSince(ride.startedAt))
        var series = Array(repeating: Array(repeating: RideTrendBucket(), count: binCount), count: definitions.count)
        var gapBins = Array(repeating: Array(repeating: false, count: binCount), count: definitions.count)
        var gapCounts = Array(repeating: 0, count: definitions.count)
        var lastSeen = Array<Date?>(repeating: nil, count: definitions.count)

        func bin(_ offset: Double) -> Int {
            min(binCount - 1, Int(offset / span * Double(binCount)))
        }

        for record in records {
            let id: String
            let value: Double
            if let measurement = record.measurement {
                id = measurement.id
                value = measurement.value
            } else if ride.gpsSpeedQualityVersion != nil, let speed = record.point?.speed {
                id = "gps_speed"
                value = speed * 3.6
            } else { continue }
            guard let metricIndex = indices[id], value.isFinite else { continue }
            let offset = record.timestamp.timeIntervalSince(ride.startedAt)
            guard offset.isFinite, offset >= 0, offset <= span else { continue }
            let binIndex = bin(offset)
            let threshold: TimeInterval = id == "gps_speed" ? 20 : 15
            if let previous = lastSeen[metricIndex] {
                let silence = record.timestamp.timeIntervalSince(previous)
                guard silence >= 0 else { continue }
                if silence > threshold {
                    gapCounts[metricIndex] += 1
                    let first = bin(previous.timeIntervalSince(ride.startedAt))
                    for index in first...binIndex { gapBins[metricIndex][index] = true }
                }
            } else if offset > threshold {
                gapCounts[metricIndex] += 1
                for index in 0...binIndex { gapBins[metricIndex][index] = true }
            }
            lastSeen[metricIndex] = record.timestamp
            series[metricIndex][binIndex].append(value)
        }

        return definitions.enumerated().compactMap { index, definition in
            let buckets = series[index]
            let populated = buckets.filter { $0.count > 0 }
            guard let minimum = populated.map(\.minimum).min(),
                  let maximum = populated.map(\.maximum).max() else { return nil }
            return Self(id: definition.id, label: definition.label, unit: definition.unit,
                        buckets: buckets, gapBins: gapBins[index], gapCount: gapCounts[index],
                        minimum: minimum, maximum: maximum)
        }
    }
}

private struct RideTrendBucket {
    private(set) var count = 0
    private(set) var sum = 0.0
    private(set) var last = 0.0
    private(set) var minimum = Double.infinity
    private(set) var maximum = -Double.infinity
    var mean: Double { count > 0 ? sum / Double(count) : 0 }

    mutating func append(_ value: Double) {
        count += 1
        sum += value
        last = value
        minimum = min(minimum, value)
        maximum = max(maximum, value)
    }
}

private struct RideTrendChart: View {
    let trend: RideTrend
    let elapsed: TimeInterval

    private var lower: Double {
        if trend.id == "engine_water_temperature" || trend.id == "inlet_air_temperature" {
            return floor(trend.minimum / 10) * 10 - 5
        }
        return 0
    }

    private var upper: Double { max(lower + 1, trend.maximum + max(1, (trend.maximum - lower) * 0.05)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(trend.label).font(MotoTheme.font(.headline))
                Spacer()
                Text(String(format: "%.0f–%.0f %@", trend.minimum, trend.maximum, trend.unit))
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    .monospacedDigit()
            }
            if trend.gapCount > 0 {
                Text("Паузы без замеров: \(trend.gapCount)")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 6)
                guard bounds.width > 0, bounds.height > 0 else { return }
                var grid = Path()
                for fraction in [0.25, 0.5, 0.75] {
                    let y = bounds.minY + bounds.height * CGFloat(fraction)
                    grid.move(to: CGPoint(x: bounds.minX, y: y))
                    grid.addLine(to: CGPoint(x: bounds.maxX, y: y))
                }
                context.stroke(grid, with: .color(MotoTheme.secondary.opacity(0.2)), lineWidth: 1)
                for index in trend.gapBins.indices where trend.gapBins[index] {
                    let step = bounds.width / CGFloat(trend.buckets.count)
                    let stripe = CGRect(x: bounds.minX + CGFloat(index) * step, y: bounds.minY,
                                        width: step, height: bounds.height)
                    context.fill(Path(stripe), with: .color(MotoTheme.secondary.opacity(0.12)))
                }
                func point(_ index: Int, _ value: Double) -> CGPoint {
                    CGPoint(x: bounds.minX + bounds.width * (CGFloat(index) + 0.5) / CGFloat(trend.buckets.count),
                            y: bounds.maxY - bounds.height * CGFloat((value - lower) / (upper - lower)))
                }
                var line = Path()
                var previousWasMeasured = false
                for (index, bucket) in trend.buckets.enumerated() {
                    guard bucket.count > 0 && !trend.gapBins[index] else {
                        previousWasMeasured = false
                        continue
                    }
                    var spread = Path()
                    spread.move(to: point(index, bucket.minimum))
                    spread.addLine(to: point(index, bucket.maximum))
                    context.stroke(spread, with: .color(MotoTheme.accent.opacity(0.45)), lineWidth: 2)
                    let center = point(index, trend.id == "gear_position" ? bucket.last : bucket.mean)
                    context.fill(Path(CGRect(x: center.x - 2, y: center.y - 2,
                                             width: 4, height: 4)), with: .color(MotoTheme.accent))
                    // A gear is a category. Mark the last observed gear in each
                    // bucket instead of inventing fractional intermediate gears.
                    if trend.id != "gear_position" {
                        if previousWasMeasured { line.addLine(to: center) }
                        else { line.move(to: center) }
                    }
                    previousWasMeasured = true
                }
                context.stroke(line, with: .color(MotoTheme.accent),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            HStack {
                Text("СТАРТ")
                Spacer()
                Text(duration(elapsed))
            }
            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
        }
        .padding(14)
        .background(MotoTheme.panel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trend.label): минимум \(Int(trend.minimum)), максимум \(Int(trend.maximum)) \(trend.unit). Пробелы означают отсутствие данных.")
    }
}

private struct GPSGapCard: View {
    let gap: GPSGap
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Без GPS: \(duration(gap.duration))")
                .font(MotoTheme.font(.headline))
            Text("\(gap.startedAt.formatted(date: .abbreviated, time: .standard)) — \(gap.endedAt.formatted(date: .abbreviated, time: .standard))")
                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            Text(gap.reason).font(MotoTheme.font(.caption))
            Text(gap.from != nil && gap.to != nil
                ? "Границы известны; дорога между ними не записана."
                : "Начало или конец пропуска без точной координаты.")
                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(Color.orange.opacity(0.08))
    }
}

/// A local diagram, not a map: no tiles, geocoding, directions, location requests,
/// network calls, or inferred samples. Rendering cannot change distance/export.
private struct LocalRouteOverview: View {
    let points: [TrackPoint]
    var showGapBoundaries = false

    var body: some View {
        LocalRouteDrawing(points: points, showGapBoundaries: showGapBoundaries)
            .equatable()
            .background(MotoTheme.panel)
            .overlay(alignment: .topTrailing) {
                Text("СЕВЕР ↑").font(MotoTheme.font(.caption))
                    .foregroundStyle(MotoTheme.secondary).padding(12)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Схема записанных точек GPS. Север сверху. Пропуски не входят в расстояние.")
    }
}

/// RideRecorder also publishes telemetry changes. Avoid rebuilding the whole GPS
/// drawing for each unrelated measurement; stored/recorded points are append-only.
private struct LocalRouteDrawing: View, Equatable {
    let points: [TrackPoint]
    let showGapBoundaries: Bool

    static func == (left: Self, right: Self) -> Bool {
        left.points.count == right.points.count && left.points.first?.timestamp == right.points.first?.timestamp
            && left.points.last?.timestamp == right.points.last?.timestamp
            && left.points.last?.latitude == right.points.last?.latitude
            && left.points.last?.longitude == right.points.last?.longitude
            && left.showGapBoundaries == right.showGapBoundaries
    }

    var body: some View {
        let geometry = LocalTrackGeometry(points)
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 32)
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(bounds.width / geometry.width, bounds.height / geometry.height)
            func screen(_ point: CGPoint) -> CGPoint {
                CGPoint(x: bounds.midX + (point.x - geometry.midX) * scale,
                        y: bounds.midY - (point.y - geometry.midY) * scale)
            }
            var grid = Path()
            for step in 1..<4 {
                let fraction = CGFloat(step) / 4
                grid.move(to: CGPoint(x: bounds.minX + bounds.width * fraction, y: bounds.minY))
                grid.addLine(to: CGPoint(x: bounds.minX + bounds.width * fraction, y: bounds.maxY))
                grid.move(to: CGPoint(x: bounds.minX, y: bounds.minY + bounds.height * fraction))
                grid.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY + bounds.height * fraction))
            }
            context.stroke(grid, with: .color(.white.opacity(0.045)), lineWidth: 1)
            if showGapBoundaries {
                for (previous, next) in zip(geometry.segments, geometry.segments.dropFirst()) {
                    guard let from = previous.last, let to = next.first else { continue }
                    var gap = Path()
                    gap.move(to: screen(from)); gap.addLine(to: screen(to))
                    context.stroke(gap, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                }
            }
            for segment in geometry.segments {
                guard let first = segment.first else { continue }
                if segment.count == 1 {
                    let point = screen(first)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(MotoTheme.accent))
                } else {
                    var path = Path()
                    path.move(to: screen(first))
                    for point in segment.dropFirst() { path.addLine(to: screen(point)) }
                    context.stroke(path, with: .color(MotoTheme.accent),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            if let end = geometry.segments.last?.last {
                let point = screen(end)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.white))
            }
        }
    }
}

private struct LocalTrackGeometry {
    let segments: [[CGPoint]]
    let midX: CGFloat
    let midY: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ points: [TrackPoint]) {
        // Invalid coordinates must also break a line, not silently disappear and
        // create an apparently measured bridge in a corrupt/legacy journal.
        var validRuns: [[TrackPoint]] = []
        var run: [TrackPoint] = []
        for point in points {
            if point.latitude.isFinite && point.longitude.isFinite
                && (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude) {
                run.append(point)
            } else if !run.isEmpty { validRuns.append(run); run = [] }
        }
        if !run.isEmpty { validRuns.append(run) }
        let continuous = validRuns.flatMap { continuousTrackSegments($0) }
        let reference = continuous.first?.first?.longitude ?? 0
        func project(_ point: TrackPoint) -> CGPoint {
            // Longitude wrapping keeps a crossing of the date line local.
            var longitude = point.longitude - reference
            if longitude > 180 { longitude -= 360 }
            if longitude < -180 { longitude += 360 }
            let latitude = min(85.05112878, max(-85.05112878, point.latitude)) * .pi / 180
            return CGPoint(x: longitude * .pi / 180, y: log(tan(.pi / 4 + latitude / 2)))
        }
        let all = continuous.map { $0.map(project) }
        let flattened = all.flatMap { $0 }
        let minX = flattened.map(\.x).min() ?? 0, maxX = flattened.map(\.x).max() ?? 0
        let minY = flattened.map(\.y).min() ?? 0, maxY = flattened.map(\.y).max() ?? 0
        midX = (minX + maxX) / 2; midY = (minY + maxY) / 2
        // A stationary/single-point ride has a finite viewport, without zooming
        // centimetres of GPS noise to the whole screen. All coordinates stay local.
        let minimumSpan: CGFloat = 0.000005
        width = max(minimumSpan, maxX - minX); height = max(minimumSpan, maxY - minY)
        // Bound drawing work for long trips. Every segment and its endpoints stay
        // separate; only the diagram is sampled, never saved/exported observations.
        let step = max(1, Int(ceil(Double(flattened.count) / 4000)))
        segments = all.map { segment in
            guard segment.count > 2 && step > 1 else { return segment }
            var sampled = stride(from: 0, to: segment.count - 1, by: step).map { segment[$0] }
            if let end = segment.last { sampled.append(end) }
            return sampled
        }
    }
}

private func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}
