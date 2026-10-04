import CoreLocation
import MapKit
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
    @State private var expansion: [String: Bool] = [:]
    @State private var visibleLimits: [String: Int] = [:]
    @State private var pendingDelete: RideSummary?
    @State private var showingDelete = false
    @State private var showingClear = false
    @State private var clearIDs: [UUID] = []
    #if targetEnvironment(simulator)
    @State private var previewHistory: [RideSummary]?
    #endif

    private var busy: Bool { rides.changingHistory || rides.exporting || rides.finishingRide }
    private var history: [RideSummary] {
        #if targetEnvironment(simulator)
        if let previewHistory { return previewHistory }
        #endif
        return rides.history
    }
    private var totalDistance: Double {
        history.reduce(0) { total, ride in
            total + (ride.distanceMeters.isFinite ? max(0, ride.distanceMeters) : 0)
        }
    }

    private var groups: [RideHistoryOrganization.Group<RideSummary>] { RideHistoryOrganization.groups(history) }

    var body: some View {
        List {
            Section {
                if history.isEmpty {
                    Text("Завершённые поездки появятся здесь.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                } else {
                    Text(String(format: "Поездок: %d · %.1f км", history.count, totalDistance / 1000))
                        .font(MotoTheme.font(.headline))
                    Text("Расстояние по записям GPS.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                if rides.changingHistory { ProgressView("Обновляем историю…") }
                if let failure = rides.historyError { Text(failure).font(MotoTheme.font(.caption)).foregroundStyle(.orange) }
                else if let status = rides.historyRefreshStatus {
                    Text(status).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
            }.listRowBackground(MotoTheme.background)
            ForEach(groups) { group in
                Section {
                    if expanded(group) {
                        ForEach(Array(group.rides.prefix(visibleLimits[group.id] ?? 30))) { ride in
                            historyRow(ride)
                        }
                        if group.rides.count > (visibleLimits[group.id] ?? 30) {
                            Button("Показать ещё 30") { visibleLimits[group.id] = (visibleLimits[group.id] ?? 30) + 30 }
                                .font(MotoTheme.font(.subheadline)).listRowBackground(MotoTheme.background)
                        }
                    }
                } header: {
                    Button { expansion[group.id] = !expanded(group) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expanded(group) ? "chevron.down" : "chevron.right")
                            groupTitle(group.bucket)
                            Spacer(minLength: 4)
                            Text("\(group.rides.count)").foregroundStyle(MotoTheme.secondary)
                        }.font(MotoTheme.font(.subheadline)).foregroundStyle(Color.primary)
                            .padding(.vertical, 7).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityHint(expanded(group) ? "Свернуть группу" : "Показать поездки")
                }
            }
        }
        .font(MotoTheme.font(.body))
        .scrollContentBackground(.hidden).background(MotoTheme.backdrop)
        .navigationTitle("История")
        .refreshable {
            #if targetEnvironment(simulator)
            if previewHistory != nil { return }
            #endif
            await rides.refreshHistory()
        }
        .onAppear {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--review-history"), previewHistory == nil {
                previewHistory = RideHistoryVisualData.summaries()
            }
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    clearIDs = history.map(\.id); showingClear = true
                } label: { Image(systemName: "trash") }
                    .disabled(history.isEmpty || busy)
                    .accessibilityLabel("Удалить завершённые поездки")
            }
        }
        .pixelConfirmationDialog("Удалить поездку?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Удалить поездку", role: .destructive) {
                if let ride = pendingDelete { delete([ride.id]) }
                pendingDelete = nil
            }
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Будут удалены маршрут, заметка и журнал этой поездки с iPhone. Копии, которые вы сохранили отдельно, останутся. Отменить удаление нельзя.")
        }
        .pixelConfirmationDialog("Очистить историю?", isPresented: $showingClear, titleVisibility: .visible) {
            Button("Удалить поездок: \(clearIDs.count)", role: .destructive) { delete(clearIDs) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все выбранные завершённые поездки и их журналы будут удалены с iPhone. Текущая запись и отдельно сохранённые копии останутся. Отменить удаление нельзя.")
        }
    }

    private func expanded(_ group: RideHistoryOrganization.Group<RideSummary>) -> Bool {
        expansion[group.id] ?? group.bucket.initiallyExpanded
    }

    @ViewBuilder private func groupTitle(_ bucket: RideHistoryOrganization.Bucket) -> some View {
        switch bucket {
        case .favorites: Label("Избранное", systemImage: "star.fill")
        case .day(let date):
            if Calendar.current.isDateInToday(date) { Text("Сегодня") }
            else if Calendar.current.isDateInYesterday(date) { Text("Вчера") }
            else { Text(date, format: .dateTime.weekday(.wide).day().month()) }
        case .previousWeek: Text("Прошлая неделя")
        case .month(let date): Text(date, format: .dateTime.month(.wide).year())
        }
    }

    private func historyRow(_ ride: RideSummary) -> some View {
        NavigationLink { RideDetailView(rides: rides, ride: ride) } label: {
            HStack(alignment: .top, spacing: 9) {
                if ride.isFavorite { Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("Избранная поездка") }
                VStack(alignment: .leading, spacing: 6) {
                    if let title = ride.title { Text(title).font(MotoTheme.font(.headline)) }
                    Text(ride.startedAt, format: .dateTime.day().month().hour().minute())
                        .font(MotoTheme.font(.headline))
                    Text(String(format: "GPS %.2f км · %@", ride.distanceMeters / 1000, duration(ride.elapsed)))
                        .font(MotoTheme.font(.subheadline)).foregroundStyle(MotoTheme.secondary)
                }
            }.padding(.vertical, 5)
        }
        .listRowBackground(MotoTheme.background)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { pendingDelete = ride; showingDelete = true }
                label: { Label("Удалить", systemImage: "trash") }.disabled(busy)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { toggleFavorite(ride) }
                label: { Label(ride.isFavorite ? "Убрать" : "Закрепить", systemImage: ride.isFavorite ? "star.slash" : "star.fill") }
                .tint(.orange).disabled(busy)
        }
    }

    private func toggleFavorite(_ ride: RideSummary) {
        #if targetEnvironment(simulator)
        if var preview = previewHistory, let index = preview.firstIndex(where: { $0.id == ride.id }) {
            preview[index].favorite = !ride.isFavorite; previewHistory = preview; return
        }
        #endif
        rides.setRideFavorite(!ride.isFavorite, for: ride.id)
    }

    private func delete(_ ids: [UUID]) {
        #if targetEnvironment(simulator)
        if var preview = previewHistory { preview.removeAll { ids.contains($0.id) }; previewHistory = preview; return }
        #endif
        rides.deleteCompletedRides(ids)
    }
}

#if targetEnvironment(simulator)
/// Small in-memory sample for the real grouped List and swipe controls. No
/// manifest, raw journal, or user's history is created/changed for screenshot QA.
private enum RideHistoryVisualData {
    static func summaries(at now: Date = Date(), calendar: Calendar = .current) -> [RideSummary] {
        let today = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let olderWeek = calendar.date(byAdding: .day, value: -2, to: week) ?? today
        let olderMonth = calendar.date(byAdding: .month, value: -2, to: today) ?? today
        let dates = [olderMonth, today, calendar.date(byAdding: .day, value: -1, to: today) ?? today,
                     olderWeek, calendar.date(byAdding: .month, value: -1, to: today) ?? today]
        return dates.enumerated().map { index, date in
            let start = date.addingTimeInterval(8 * 3600)
            var ride = RideSummary(id: UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", index + 1))!,
                startedAt: start, endedAt: start.addingTimeInterval(1800), lastSavedAt: start.addingTimeInterval(1800), trigger: "simulator")
            ride.title = ["Любимый маршрут", "На работу", "Вечерняя поездка", "За город", "Короткая поездка"][index]
            ride.distanceMeters = Double(12 + index * 5) * 1000
            ride.favorite = index == 0
            return ride
        }
    }
}
#endif

struct RideDetailView: View {
    @ObservedObject var rides: RideRecorder
    let ride: RideSummary
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var showingDelete = false
    @State private var points: [TrackPoint] = []
    @State private var routeGeometry: LocalTrackGeometry?
    @State private var ranges: [RideMeasurementRange] = []
    @State private var trends: [RideTrend] = []
    @State private var selectedTrendIDs: Set<String> = []
    @State private var showingExpandedTrends = false
    @State private var gaps: [GPSGap] = []
    @State private var showGapBoundaries = false
    @State private var showingExpandedRoute = false
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
                    HStack {
                        Text("Схема маршрута").font(MotoTheme.font(.title3))
                        Spacer(minLength: 8)
                        Button { showingExpandedRoute = true } label: {
                            Label("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right")
                        }.font(MotoTheme.font(.caption))
                    }
                    LocalRouteOverview(points: points, showGapBoundaries: showGapBoundaries,
                                       cachedGeometry: routeGeometry)
                        .frame(height: 280).clipShape(PixelFrame())
                    Text("Схема по записанным точкам, без загрузки карт. Красный — GPS; белая точка — конец записи.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    if gaps.contains(where: { $0.from != nil && $0.to != nil }) {
                        Toggle("Показать границы пропусков", isOn: $showGapBoundaries)
                            .font(MotoTheme.font(.subheadline))
                        if showGapBoundaries {
                            Text("Серый пунктир лишь отмечает границы; это не записанный путь и не дорога.")
                                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
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
                    HStack {
                        Text("Графики поездки").font(MotoTheme.font(.title3))
                        Spacer(minLength: 8)
                        Button { showingExpandedTrends = true } label: {
                            Label("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .font(MotoTheme.font(.caption))
                    }
                    RideTrendPicker(trends: trends, selectedIDs: $selectedTrendIDs)
                    RideTrendPlot(trends: trends.filter { selectedTrendIDs.contains($0.id) }, elapsed: ride.elapsed)
                        .frame(height: 224)
                        .clipShape(PixelFrame())
                    RideTrendLegend(trends: trends.filter { selectedTrendIDs.contains($0.id) })
                    Text("У каждой линии свой масштаб. Разрывы означают отсутствие замеров; график построен на iPhone без сети.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
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
        .background(MotoTheme.backdrop)
        .navigationTitle("Поездка")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Изменить") { showingEditor = true }.font(MotoTheme.font(.body))
                    .disabled(rides.changingHistory || rides.exporting || rides.active?.id == ride.id)
            }
        }
        .sheet(isPresented: $showingEditor) { RideMetadataEditor(rides: rides, ride: ride) }
        .fullScreenCover(isPresented: $showingExpandedTrends) {
            RideTrendFullscreen(trends: trends, selectedIDs: $selectedTrendIDs, elapsed: ride.elapsed)
        }
        .fullScreenCover(isPresented: $showingExpandedRoute) {
            RouteFullscreenView(points: points, gaps: gaps, ride: ride, rides: rides,
                                preparedGeometry: routeGeometry)
        }
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
            points = []; routeGeometry = nil; ranges = []; trends = []; gaps = []
            selectedTrendIDs = []
            showGapBoundaries = false
            rides.load(ride) { result in
                guard loadRequestID == requestID else { return }
                switch result {
                case .success(let records):
                    // Archive reading is asynchronous; reducing a large JSONL
                    // into route, ranges and chart bins must also stay off the
                    // main thread so opening History cannot freeze the controls.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let summary = RideDetailVisualSummary.make(records: records, ride: ride)
                        DispatchQueue.main.async {
                            guard loadRequestID == requestID else { return }
                            loading = false
                            points = summary.points
                            routeGeometry = summary.routeGeometry
                            ranges = summary.ranges
                            trends = summary.trends
                            selectedTrendIDs = summary.selectedTrendIDs
                            gaps = summary.gaps
                        }
                    }
                case .failure(let failure):
                    loading = false
                    error = failure.localizedDescription
                }
            }
        }
        .onDisappear { loadRequestID = UUID() }
    }
}

private struct RideDetailVisualSummary {
    let points: [TrackPoint]
    let routeGeometry: LocalTrackGeometry
    let ranges: [RideMeasurementRange]
    let trends: [RideTrend]
    let selectedTrendIDs: Set<String>
    let gaps: [GPSGap]

    static func make(records: [RideRecord], ride: RideSummary) -> Self {
        let points = records.compactMap(\.point)
        let trends = RideTrend.summarize(records, ride: ride)
        let preferred = ["gps_speed", "throttle_position"]
        var selected = Set(preferred.filter { id in trends.contains { $0.id == id } })
        for trend in trends where selected.count < 2 { selected.insert(trend.id) }
        return Self(points: points, routeGeometry: LocalTrackGeometry(points),
                    ranges: RideMeasurementRange.summarize(records), trends: trends,
                    selectedTrendIDs: selected, gaps: gpsGaps(in: records, ride: ride))
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
    let series: RideChartSeries
    let minimum: Double
    let maximum: Double

    var color: Color {
        switch id {
        case "gps_speed": return Color(red: 1.00, green: 0.31, blue: 0.37)
        case "wheel_speed": return Color(red: 1.00, green: 0.77, blue: 0.30)
        case "engine_speed": return Color(red: 0.75, green: 0.61, blue: 1.00)
        case "gear_position": return Color(red: 0.58, green: 0.89, blue: 0.51)
        case "throttle_position": return Color(red: 0.31, green: 0.83, blue: 0.93)
        case "engine_water_temperature": return Color(red: 1.00, green: 0.56, blue: 0.30)
        default: return Color(red: 0.52, green: 0.69, blue: 1.00)
        }
    }

    var plotMinimum: Double {
        if id == "engine_water_temperature" || id == "inlet_air_temperature" {
            return floor(minimum / 10) * 10 - 5
        }
        return min(0, floor(minimum / 10) * 10)
    }

    var plotMaximum: Double {
        ceil(max(plotMinimum + 1, maximum + max(1, (maximum - plotMinimum) * 0.05)))
    }

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
        var series = definitions.map { definition in
            RideChartSeries(binCount: binCount, span: span,
                            maximumSilence: definition.id == "gps_speed" ? 20 : 15)
        }
        var interrupted = Array(repeating: false, count: definitions.count)
        var previousGPSSegment: Int?

        for record in records {
            if record.kind == "gap" {
                interrupted = Array(repeating: true, count: definitions.count)
            } else if record.kind == "bluetooth", record.detail == "disconnected" {
                for index in definitions.indices where definitions[index].id != "gps_speed" {
                    interrupted[index] = true
                }
            } else if record.kind == "gps_gap_started" || record.kind == "gps_gap" {
                if let speedIndex = indices["gps_speed"] { interrupted[speedIndex] = true }
            }
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
            if id == "gps_speed", let segment = record.point?.segment,
               let previousGPSSegment, segment != previousGPSSegment {
                interrupted[metricIndex] = true
            }
            if series[metricIndex].append(offset: offset, value: value,
                                          interrupted: interrupted[metricIndex]) {
                interrupted[metricIndex] = false
                if id == "gps_speed" { previousGPSSegment = record.point?.segment }
            }
        }

        return definitions.enumerated().compactMap { index, definition in
            let populated = series[index].buckets.filter { $0.count > 0 }
            guard let minimum = populated.map(\.minimum).min(),
                  let maximum = populated.map(\.maximum).max() else { return nil }
            return Self(id: definition.id, label: definition.label, unit: definition.unit,
                        series: series[index], minimum: minimum, maximum: maximum)
        }
    }
}

private struct RideTrendPicker: View {
    let trends: [RideTrend]
    @Binding var selectedIDs: Set<String>
    var vertical = false

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(trends) { trend in option(trend) }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(trends) { trend in option(trend) }
                    }
                }
            }
        }
    }

    private func option(_ trend: RideTrend) -> some View {
        let selected = selectedIDs.contains(trend.id)
        return Button {
            if selected {
                if selectedIDs.count > 1 { selectedIDs.remove(trend.id) }
            } else {
                selectedIDs.insert(trend.id)
            }
        } label: {
            HStack(spacing: 7) {
                Capsule().fill(trend.color).frame(width: 19, height: 3)
                Text(trend.label).lineLimit(1)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? trend.color : MotoTheme.secondary)
            }
            .font(MotoTheme.font(.caption))
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(selected ? trend.color.opacity(0.15) : MotoTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? trend.color.opacity(0.7) : MotoTheme.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(trend.label)
        .accessibilityValue(selected ? "Показан" : "Скрыт")
    }
}

private struct RideTrendLegend: View {
    let trends: [RideTrend]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(trends) { trend in
                HStack(alignment: .top, spacing: 8) {
                    Capsule().fill(trend.color).frame(width: 20, height: 3).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trend.label).font(MotoTheme.font(.subheadline))
                        Text(detail(for: trend))
                            .font(MotoTheme.font(.caption))
                            .foregroundStyle(MotoTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func range(_ lower: Double, _ upper: Double, unit: String) -> String {
        String(format: "%.0f–%.0f", lower, upper) + (unit.isEmpty ? "" : " \(unit)")
    }

    private func detail(for trend: RideTrend) -> String {
        let scale = range(trend.plotMinimum, trend.plotMaximum, unit: trend.unit)
        let shown = range(trend.minimum, trend.maximum, unit: trend.unit)
        let gaps = trend.series.gapCount > 0 ? " · пропуски \(trend.series.gapCount)" : ""
        return "Шкала \(scale) · показано \(shown)\(gaps)"
    }
}

private struct RideTrendPlot: View {
    let trends: [RideTrend]
    let elapsed: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
                guard bounds.width > 0, bounds.height > 0 else { return }
                var grid = Path()
                for fraction in [0.25, 0.5, 0.75] {
                    let y = bounds.minY + bounds.height * CGFloat(fraction)
                    grid.move(to: CGPoint(x: bounds.minX, y: y))
                    grid.addLine(to: CGPoint(x: bounds.maxX, y: y))
                }
                context.stroke(grid, with: .color(MotoTheme.secondary.opacity(0.2)), lineWidth: 1)

                for trend in trends {
                    let buckets = trend.series.buckets
                    var line = Path()
                    var previousIndex: Int?
                    var previousPoint: CGPoint?
                    for (index, bucket) in buckets.enumerated() where bucket.count > 0 {
                        let value = trend.id == "gear_position" ? bucket.last : bucket.mean
                        let point = CGPoint(
                            x: bounds.minX + bounds.width * (CGFloat(index) + 0.5) / CGFloat(buckets.count),
                            y: bounds.maxY - bounds.height
                                * CGFloat((value - trend.plotMinimum) / (trend.plotMaximum - trend.plotMinimum))
                        )
                        if trend.series.connects(previousIndex, to: index) {
                            if trend.id == "gear_position", let previousPoint {
                                // Gear is a category; a step avoids fractional gears.
                                line.addLine(to: CGPoint(x: point.x, y: previousPoint.y))
                            }
                            line.addLine(to: point)
                        } else {
                            line.move(to: point)
                        }
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5,
                                                           width: 3, height: 3)),
                                     with: .color(trend.color))
                        previousIndex = index
                        previousPoint = point
                    }
                    context.stroke(line, with: .color(trend.color),
                                   style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("СТАРТ")
                Spacer()
                Text(duration(elapsed))
            }
            .font(MotoTheme.font(.caption))
            .foregroundStyle(MotoTheme.secondary)
        }
        .padding(12)
        .background(MotoTheme.panel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("График поездки: \(trends.map(\.label).joined(separator: ", ")). Каждая линия имеет свой масштаб; пробелы означают отсутствие данных.")
    }
}

private struct RideTrendFullscreen: View {
    let trends: [RideTrend]
    @Binding var selectedIDs: Set<String>
    let elapsed: TimeInterval
    @Environment(\.dismiss) private var dismiss

    private var selectedTrends: [RideTrend] {
        trends.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: landscape ? 8 : 14) {
                HStack {
                    Text("Графики поездки").font(MotoTheme.font(.title3))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть график")
                }
                if landscape {
                    HStack(alignment: .top, spacing: 12) {
                        RideTrendPlot(trends: selectedTrends, elapsed: elapsed)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                RideTrendPicker(trends: trends, selectedIDs: $selectedIDs, vertical: true)
                                RideTrendLegend(trends: selectedTrends)
                                explanation
                            }
                        }
                        .frame(width: min(300, geometry.size.width * 0.34))
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            RideTrendPicker(trends: trends, selectedIDs: $selectedIDs)
                            RideTrendPlot(trends: selectedTrends, elapsed: elapsed)
                                .frame(height: max(300, geometry.size.height * 0.48))
                            RideTrendLegend(trends: selectedTrends)
                            explanation
                        }
                    }
                }
            }
            .padding(landscape ? 10 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MotoTheme.background.ignoresSafeArea())
    }

    private var explanation: some View {
        Text("Каждая линия использует собственную шкалу. Разрывы означают отсутствие замеров; данные построены на iPhone без сети.")
            .font(MotoTheme.font(.caption))
            .foregroundStyle(MotoTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if targetEnvironment(simulator)
/// Uses the same chart controls as a saved ride, with fictional telemetry only.
/// The fixture is never built for a physical iPhone or written to ride history.
struct RideGraphVisualCheckView: View {
    @State private var selectedIDs: Set<String> = ["wheel_speed", "engine_speed", "throttle_position"]
    private let trends = RideTrend.summarize(ProductVisualData.graphRecords,
                                              ride: ProductVisualData.graphRide)

    private var selectedTrends: [RideTrend] { trends.filter { selectedIDs.contains($0.id) } }
    private var fullscreen: Bool {
        ProcessInfo.processInfo.arguments.contains("--review-graphs-fullscreen")
    }

    var body: some View {
        Group {
            if fullscreen {
                RideTrendFullscreen(trends: trends, selectedIDs: $selectedIDs,
                                    elapsed: ProductVisualData.graphRide.elapsed)
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Графики поездки").font(MotoTheme.font(.title2))
                            RideTrendPicker(trends: trends, selectedIDs: $selectedIDs)
                            RideTrendPlot(trends: selectedTrends,
                                          elapsed: ProductVisualData.graphRide.elapsed)
                                .frame(height: 260).clipShape(PixelFrame())
                            RideTrendLegend(trends: selectedTrends)
                            Text("Разрыв линий — отсутствие данных мотоцикла. Значения для проверки вымышлены.")
                                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                        }.padding(16)
                    }
                    .background(MotoTheme.backdrop)
                    .navigationTitle("Поездка · пример")
                }
            }
        }
    }
}

/// Deterministic offline visual review; never asks Apple for tiles or directions.
struct RouteVisualCheckView: View {
    @ObservedObject var rides: RideRecorder
    var body: some View {
        let estimates = ProcessInfo.processInfo.arguments.contains("--review-route-estimates")
            ? ProductVisualData.routeEstimates : []
        RouteFullscreenView(points: ProductVisualData.routePoints,
            gaps: ProductVisualData.routeGaps, ride: ProductVisualData.routeRide,
            rides: rides, previewEstimates: estimates)
    }
}
#endif

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

/// Opening a saved ride starts in this fully local view. Map tiles and road
/// directions are separate, explicit actions; neither affects recorded GPS km.
private struct RouteFullscreenView: View {
    let points: [TrackPoint]
    let gaps: [GPSGap]
    let ride: RideSummary
    @ObservedObject var rides: RideRecorder
    let previewEstimates: [GPSRouteEstimate]?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roads = RoadEstimateController()
    @State private var showingMap = false
    @State private var showingGaps = false
    @State private var showGapBoundaries = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var bearing = Angle.zero
    @GestureState private var gestureZoom: CGFloat = 1
    @GestureState private var gestureOffset: CGSize = .zero
    @GestureState private var gestureBearing = Angle.zero
    private let preparedGeometry: LocalTrackGeometry

    init(points: [TrackPoint], gaps: [GPSGap], ride: RideSummary, rides: RideRecorder,
         previewEstimates: [GPSRouteEstimate]? = nil, preparedGeometry: LocalTrackGeometry? = nil) {
        self.points = points
        self.gaps = gaps
        self.ride = ride
        self.rides = rides
        self.previewEstimates = previewEstimates
        self.preparedGeometry = preparedGeometry ?? LocalTrackGeometry(points)
    }

    private var displayedEstimates: [GPSRouteEstimate] { previewEstimates ?? roads.estimates }

    private var viewport: LocalRouteViewport {
        LocalRouteViewport(zoom: min(20, max(1, zoom * gestureZoom)),
            offset: CGSize(width: offset.width + gestureOffset.width,
                           height: offset.height + gestureOffset.height),
            rotation: bearing.radians + gestureBearing.radians)
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                if showingMap {
                    RecordedRouteMap(points: points, estimates: displayedEstimates)
                        .ignoresSafeArea()
                } else {
                    LocalRouteDrawing(points: points, showGapBoundaries: showGapBoundaries,
                        estimates: displayedEstimates, viewport: viewport, cachedGeometry: preparedGeometry)
                        .background(MotoTheme.panel)
                        .clipped()
                        .simultaneousGesture(MagnificationGesture()
                            .updating($gestureZoom) { value, state, _ in state = value }
                            .onEnded { zoom = min(20, max(1, zoom * $0)) })
                        .simultaneousGesture(DragGesture(minimumDistance: 4)
                            .updating($gestureOffset) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                            })
                        .simultaneousGesture(RotationGesture()
                            .updating($gestureBearing) { value, state, _ in state = value }
                            .onEnded { bearing = Angle(radians: bearing.radians + $0.radians) })
                }
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button("Готово") { dismiss() }
                        Spacer(minLength: 4)
                        Text(showingMap ? "КАРТА APPLE" : "СХЕМА GPS")
                            .font(MotoTheme.font(.subheadline)).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        Button(showingMap ? "Схема" : "Карта") { showingMap.toggle() }
                    }
                    .buttonStyle(PixelButtonStyle())
                    .padding(landscape ? 8 : 12)
                    .background(MotoTheme.panel.opacity(0.96), in: PixelFrame())
                    Spacer(minLength: 8)
                    VStack(spacing: 7) {
                        Text(showingMap
                             ? "Карта загружает данные Apple при наличии сети; без сети могут остаться только сохранённые плитки."
                             : "Схема без сети: красная линия — записанный GPS. «Карта» может загрузить плитки Apple через интернет.")
                            .font(MotoTheme.font(.caption))
                            .lineLimit(landscape ? 2 : 3).minimumScaleFactor(0.7)
                        if !displayedEstimates.isEmpty {
                            Text("Оранжевый пунктир — предположение по дорогам, не пройденный путь.")
                                .font(MotoTheme.font(.caption)).foregroundStyle(.orange)
                                .lineLimit(landscape ? 1 : 2).minimumScaleFactor(0.7)
                        }
                        HStack(spacing: 10) {
                            if !showingMap {
                                Button("−") { zoom = max(1, zoom / 1.5) }
                                Button("+") { zoom = min(20, zoom * 1.5) }
                                Button("Сброс") { zoom = 1; offset = .zero; bearing = .zero }
                            }
                            Spacer(minLength: 0)
                            if !gaps.isEmpty {
                                Button("Пропуски · \(gaps.count)") { showingGaps = true }
                            }
                        }
                        .buttonStyle(PixelButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(landscape ? 8 : 12)
                    .background(MotoTheme.panel.opacity(0.96), in: PixelFrame())
                }
                .padding(landscape ? 8 : 12)
            }
        }
        .background(MotoTheme.background.ignoresSafeArea())
        .font(MotoTheme.font(.body))
        .onAppear { if previewEstimates == nil { roads.load(ride, using: rides) } }
        .onDisappear { roads.cancel() }
        .sheet(isPresented: $showingGaps) { gapInspector }
    }

    private var gapInspector: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Записанное расстояние GPS: \(String(format: "%.2f", ride.distanceMeters / 1000)) км. Предположения не меняют это число и одометр.")
                        .font(MotoTheme.font(.subheadline))
                    Toggle("Границы пропусков на схеме", isOn: $showGapBoundaries)
                        .font(MotoTheme.font(.subheadline))
                    Text("Для варианта по дорогам только после нажатия координаты границ пропуска отправятся Apple Maps. Нужен интернет; реальный путь между ними неизвестен.")
                        .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    if let message = roads.message {
                        Text(message).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                    }
                    ForEach(gaps) { gap in
                        GPSGapCard(gap: gap)
                        if let estimate = displayedEstimates.first(where: { $0.gapID == gap.id }) {
                            Text(String(format: "Вариант по дорогам: %.2f км · %@",
                                        estimate.distanceMeters / 1000, estimate.source))
                                .font(MotoTheme.font(.caption)).foregroundStyle(.orange)
                        }
                        if previewEstimates == nil && gap.from != nil && gap.to != nil {
                            Button(roads.busyGap == gap.id ? "Ищем дорогу…" : "Вариант по дорогам") {
                                roads.calculate(gap, ride: ride, using: rides)
                            }
                            .buttonStyle(PixelButtonStyle())
                            .disabled(roads.busyGap != nil)
                        }
                    }
                }.padding(16)
            }
            .background(MotoTheme.backdrop)
            .navigationTitle("Пропуски GPS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { showingGaps = false }
            } }
        }
    }
}

private struct LocalRouteViewport: Equatable {
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    var rotation: Double = 0
}

/// A local diagram, not a map: no tiles, geocoding, directions, location requests,
/// network calls, or inferred samples. Rendering cannot change distance/export.
private struct LocalRouteOverview: View {
    let points: [TrackPoint]
    var showGapBoundaries = false
    var cachedGeometry: LocalTrackGeometry? = nil

    var body: some View {
        LocalRouteDrawing(points: points, showGapBoundaries: showGapBoundaries,
                          cachedGeometry: cachedGeometry)
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
    let estimates: [GPSRouteEstimate]
    let viewport: LocalRouteViewport
    private let cachedGeometry: LocalTrackGeometry?

    init(points: [TrackPoint], showGapBoundaries: Bool = false,
         estimates: [GPSRouteEstimate] = [], viewport: LocalRouteViewport = .init(),
         cachedGeometry: LocalTrackGeometry? = nil) {
        self.points = points
        self.showGapBoundaries = showGapBoundaries
        self.estimates = estimates
        self.viewport = viewport
        self.cachedGeometry = cachedGeometry
    }

    static func == (left: Self, right: Self) -> Bool {
        left.points.count == right.points.count && left.points.first?.timestamp == right.points.first?.timestamp
            && left.points.last?.timestamp == right.points.last?.timestamp
            && left.points.last?.latitude == right.points.last?.latitude
            && left.points.last?.longitude == right.points.last?.longitude
            && left.showGapBoundaries == right.showGapBoundaries
            && left.estimates == right.estimates && left.viewport == right.viewport
    }

    var body: some View {
        let geometry = cachedGeometry ?? LocalTrackGeometry(points)
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 32)
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(bounds.width / geometry.width, bounds.height / geometry.height)
            func screen(_ point: CGPoint) -> CGPoint {
                let x = (point.x - geometry.midX) * scale
                let y = (geometry.midY - point.y) * scale
                let c = CGFloat(cos(viewport.rotation)), s = CGFloat(sin(viewport.rotation))
                return CGPoint(x: bounds.midX + (x * c - y * s) * viewport.zoom + viewport.offset.width,
                               y: bounds.midY + (x * s + y * c) * viewport.zoom + viewport.offset.height)
            }
            var grid = Path()
            for step in 1..<4 {
                let fraction = CGFloat(step) / 4
                grid.move(to: CGPoint(x: bounds.minX + bounds.width * fraction, y: bounds.minY))
                grid.addLine(to: CGPoint(x: bounds.minX + bounds.width * fraction, y: bounds.maxY))
                grid.move(to: CGPoint(x: bounds.minX, y: bounds.minY + bounds.height * fraction))
                grid.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY + bounds.height * fraction))
            }
            context.stroke(grid, with: .color(Color.primary.opacity(0.07)), lineWidth: 1)
            // Saved Apple road suggestions are separate dashed overlays. They
            // never create TrackPoint values or change recorded distance.
            for estimate in estimates {
                let projected = estimate.coordinates.compactMap(geometry.project)
                guard let first = projected.first, projected.count > 1 else { continue }
                var path = Path()
                path.move(to: screen(first))
                for point in projected.dropFirst() { path.addLine(to: screen(point)) }
                context.stroke(path, with: .color(.orange.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 5]))
            }
            if showGapBoundaries {
                for (previous, next) in zip(geometry.segments, geometry.segments.dropFirst()) {
                    guard let from = previous.last, let to = next.first else { continue }
                    var gap = Path()
                    gap.move(to: screen(from)); gap.addLine(to: screen(to))
                    context.stroke(gap, with: .color(MotoTheme.secondary.opacity(0.65)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
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
    let referenceLongitude: Double

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
        referenceLongitude = reference
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

    func project(_ coordinate: GPSCoordinate) -> CGPoint? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else { return nil }
        var longitude = coordinate.longitude - referenceLongitude
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        let latitude = min(85.05112878, max(-85.05112878, coordinate.latitude)) * .pi / 180
        return CGPoint(x: longitude * .pi / 180, y: log(tan(.pi / 4 + latitude / 2)))
    }
}

/// Constructed only after the rider taps "Карта" in the fullscreen route.
/// Opening History or the default offline scheme never creates MKMapView.
private struct RecordedRouteMap: UIViewRepresentable {
    let points: [TrackPoint]
    let estimates: [GPSRouteEstimate]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        map.preferredConfiguration = configuration
        map.showsUserLocation = false
        map.isPitchEnabled = false
        map.isRotateEnabled = true
        map.showsCompass = true
        map.showsScale = true
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let key = "\(points.count)|\(points.first?.timestamp.timeIntervalSince1970 ?? 0)|\(points.last?.timestamp.timeIntervalSince1970 ?? 0)|"
            + estimates.map { "\($0.gapID):\($0.calculatedAt.timeIntervalSince1970)" }.joined(separator: ",")
        guard context.coordinator.renderedKey != key else { return }
        context.coordinator.renderedKey = key
        map.removeOverlays(map.overlays)
        var fitted: MKMapRect?
        var overlays: [any MKOverlay] = []
        let recorded = recordedRouteRuns(points)
        map.removeAnnotations(map.annotations)
        if let first = recorded.first?.first {
            let pin = MKPointAnnotation()
            pin.coordinate = first
            pin.title = "Начало записи GPS"
            map.addAnnotation(pin)
        }
        if let last = recorded.last?.last, recorded.first?.first?.latitude != last.latitude
            || recorded.first?.first?.longitude != last.longitude {
            let pin = MKPointAnnotation()
            pin.coordinate = last
            pin.title = "Конец записи GPS"
            map.addAnnotation(pin)
        }
        for run in recorded where run.count > 1 {
            let line = MKPolyline(coordinates: run, count: run.count)
            line.title = "GPS"
            overlays.append(line)
            fitted = fitted.map { $0.union(line.boundingMapRect) } ?? line.boundingMapRect
        }
        for estimate in estimates {
            let coordinates = estimate.coordinates.compactMap { value -> CLLocationCoordinate2D? in
                let coordinate = CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
                return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
            }
            guard coordinates.count > 1 else { continue }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            line.title = "ESTIMATE"
            overlays.append(line)
        }
        map.addOverlays(overlays)
        if !context.coordinator.didFit {
            if let fitted {
                map.setVisibleMapRect(fitted, edgePadding: UIEdgeInsets(top: 90, left: 35, bottom: 90, right: 35),
                                      animated: false)
                context.coordinator.didFit = true
            } else if let first = recorded.first?.first {
                map.setRegion(MKCoordinateRegion(center: first,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)), animated: false)
                context.coordinator.didFit = true
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderedKey: String?
        var didFit = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            let estimated = line.title == "ESTIMATE"
            renderer.strokeColor = estimated ? .systemOrange : .systemRed
            renderer.lineWidth = estimated ? 3 : 4
            if estimated { renderer.lineDashPattern = [NSNumber(value: 7), NSNumber(value: 5)] }
            return renderer
        }
    }
}

private func recordedRouteRuns(_ points: [TrackPoint]) -> [[CLLocationCoordinate2D]] {
    var validRuns: [[TrackPoint]] = []
    var current: [TrackPoint] = []
    for point in points {
        if point.latitude.isFinite && point.longitude.isFinite
            && (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude) {
            current.append(point)
        } else if !current.isEmpty {
            validRuns.append(current)
            current = []
        }
    }
    if !current.isEmpty { validRuns.append(current) }
    let segmented = validRuns.flatMap { continuousTrackSegments($0) }
    let count = segmented.reduce(0) { $0 + $1.count }
    let step = max(1, Int(ceil(Double(count) / 4000)))
    return segmented.map { run in
        let sampled: [TrackPoint]
        if run.count > 2 && step > 1 {
            sampled = stride(from: 0, to: run.count - 1, by: step).map { run[$0] } + [run.last!]
        } else { sampled = run }
        return sampled.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

private func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}
