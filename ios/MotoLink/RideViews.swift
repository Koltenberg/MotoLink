import CoreLocation
import MapKit
import SwiftUI

struct RidePanel: View {
    @ObservedObject var rides: RideRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Поездки").font(.title2.bold())
                Spacer()
                NavigationLink { RideHistoryView(rides: rides) } label: {
                    Label("История", systemImage: "clock.arrow.circlepath")
                }
            }
            Text(rides.status).font(.subheadline).foregroundStyle(.secondary)
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
                            Label(gpsStatus, systemImage: "location.slash").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !rides.gaps.isEmpty {
                    Text("Пропусков GPS: \(rides.gaps.count). Они не соединяются линиями и не входят в расстояние GPS. Дорожный вариант можно запросить в истории поездки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !rides.points.isEmpty {
                    RouteMap(points: rides.points).frame(height: 200).clipShape(PixelFrame())
                } else {
                    Text("Ожидаем точную геопозицию. Маршрут и скорость поступают с iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Записывать при подключении", isOn: Binding(get: { rides.autoRecord }, set: rides.setAutoRecord))
                .font(.subheadline)
            Text("Для автозаписи включи также автоподключение к байку. Начало — появление BLE-связи; это не датчик зажигания. Завершение — через 2 минуты без связи, когда приложение выполняется. После смахивания приложения открой его снова.")
                .font(.caption).foregroundStyle(.secondary)
            if rides.autoRecord && rides.authorization != .authorizedAlways {
                Button("Разрешить геопозицию для автозаписи") { rides.requestBackgroundPermission() }
                    .font(.subheadline)
                Text("В системных настройках нужен доступ «Всегда». Уже начатую вручную поездку можно записывать с доступом «При использовании».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = rides.error {
                Text("Ошибка сохранения: \(error)").font(.caption).foregroundStyle(.orange)
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
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.headline.monospacedDigit())
        }
    }
}

struct MotorcycleMeasurementsView: View {
    @ObservedObject var bluetooth: MotorcycleBluetooth
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Данные мотоцикла").font(.title2.bold())
            if bluetooth.measurements.isEmpty {
                Text("Значения появятся после ответа байка. Наличие показателя в списке возможностей не означает, что его значение уже получено.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bluetooth.measurements) { measurement in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(measurement.label)
                                Spacer()
                                Text(String(format: measurement.unit == "В" ? "%.2f %@" : "%.0f %@",
                                            measurement.value, measurement.unit)).font(.title3.monospacedDigit())
                            }
                            HStack {
                                Text(context.date.timeIntervalSince(measurement.timestamp) > 15 ? "Последний замер" : "Получено")
                                Text(measurement.timestamp, style: .time)
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(measurement.source).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !bluetooth.capabilities.isEmpty {
                Text("Поддерживается: " + bluetooth.capabilities.filter(\.supported).map(\.label).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .pixelPanel()
    }
}

struct RideHistoryView: View {
    @ObservedObject var rides: RideRecorder
    var body: some View {
        List {
            if rides.history.isEmpty { Text("Завершённые поездки появятся здесь.") }
            ForEach(rides.history) { ride in
                NavigationLink { RideDetailView(rides: rides, ride: ride) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ride.startedAt, format: .dateTime.day().month().year().hour().minute()).font(.headline)
                        Text(String(format: "%.2f км · %@ · максимум GPS %.0f км/ч", ride.distanceMeters / 1000,
                                    duration(ride.elapsed), ride.maxSpeedMS * 3.6))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(MotoTheme.background)
                .listRowSeparator(.hidden)
                .padding(.vertical, 4)
                .pixelPanel()
            }
        }.scrollContentBackground(.hidden).background(MotoTheme.background)
            .navigationTitle("Мои поездки")
    }
}

struct RideDetailView: View {
    @ObservedObject var rides: RideRecorder
    let ride: RideSummary
    @State private var points: [TrackPoint] = []
    @State private var measurements: [MotoProtocol.Measurement] = []
    @State private var gaps: [GPSGap] = []
    @StateObject private var roadEstimates = RoadEstimateController()
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.orange) }
                if !points.isEmpty {
                    RouteMap(points: points, estimates: roadEstimates.estimates)
                        .frame(height: 320).clipShape(PixelFrame())
                    if !roadEstimates.estimates.isEmpty {
                        Text("Зелёный — записанный GPS. Оранжевый пунктир — возможный дорожный путь; он не подтверждает, где вы ехали.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(ride.startedAt, format: .dateTime.day().month().year().hour().minute()).font(.title2.bold())
                Text(String(format: "%.2f км · %@", ride.distanceMeters / 1000, duration(ride.elapsed))).font(.title3)
                Text(String(format: "Максимальная скорость GPS: %.0f км/ч", ride.maxSpeedMS * 3.6))
                Text("Точек маршрута: \(points.count). Измерений байка: \(ride.telemetryCount). Разрывов процесса: \(ride.interruptionCount).")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Маршрут, расстояние и скорость — по GPS iPhone. Разрывы GPS показаны разными отрезками и не включены в расстояние. Автостарт означает BLE-связь, а не запуск двигателя.")
                    .font(.caption).foregroundStyle(.secondary)
                if !gaps.isEmpty {
                    Text("Пропуски GPS").font(.title3.bold())
                    Text("Дорожные варианты запрашиваются только по кнопке. Начальная и конечная координаты пропуска передаются Apple Maps; нужен интернет. Сохранённый вариант доступен без сети, но подложка карты может не загрузиться.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(gaps) { gap in
                        GPSGapCard(gap: gap, estimate: roadEstimates.estimates.first { $0.gapID == gap.id },
                            busy: roadEstimates.busyGap == gap.id, anyBusy: roadEstimates.busyGap != nil) {
                                roadEstimates.calculate(gap, ride: ride, using: rides)
                            }
                    }
                    if let message = roadEstimates.message {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                    if roadEstimates.busyGap != nil {
                        Button("Отменить запрос") { roadEstimates.cancel() }.font(.caption)
                    }
                }
                ForEach(Array(Set(measurements.map(\.id))).sorted(), id: \.self) { id in
                    if let first = measurements.first(where: { $0.id == id }) {
                        let values = measurements.filter { $0.id == id }.map(\.value)
                        Text(String(format: "%@: %.2f–%.2f %@", first.label, values.min() ?? 0, values.max() ?? 0, first.unit))
                            .font(.subheadline)
                    }
                }
                Button { rides.export(ride) } label: { Label("Сохранить единый журнал", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PixelButtonStyle()).disabled(rides.exporting)
                Button { rides.exportGPX(ride) } label: { Label("Отдельно: GPX и маршрут", systemImage: "map") }
                    .buttonStyle(PixelButtonStyle()).disabled(rides.exporting)
            }.padding(20)
        }
        .background(MotoTheme.background)
        .navigationTitle("Поездка")
        .task {
            roadEstimates.load(ride, using: rides)
            rides.load(ride) { result in
                loading = false
                switch result {
                case .success(let records):
                    points = records.compactMap(\.point)
                    measurements = records.compactMap(\.measurement)
                    gaps = gpsGaps(in: records, ride: ride)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
        .onDisappear { roadEstimates.cancel() }
    }
}

private struct GPSGapCard: View {
    let gap: GPSGap
    let estimate: GPSRouteEstimate?
    let busy: Bool
    let anyBusy: Bool
    let calculate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Без подтверждённого GPS: \(duration(gap.duration))").font(.headline)
            Text("\(gap.startedAt.formatted(date: .abbreviated, time: .standard)) — \(gap.endedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            Text(gap.reason).font(.caption)
            Text(gap.isLong
                ? "Длительный пропуск: уверенность низкая. Остановки, петли и объезды неизвестны; по двум точкам нельзя восстановить реальный путь."
                : "Реальный путь неизвестен. Дорожный вариант — предположение между двумя точками, без учёта ваших остановок и объездов.")
                .font(.caption).foregroundStyle(.orange)
            if let estimate {
                Text(String(format: "Дорожный вариант: %.2f км (не входит в расстояние GPS)", estimate.distanceMeters / 1000))
                    .font(.subheadline)
                Text("Рассчитан \(estimate.calculatedAt.formatted(date: .abbreviated, time: .shortened)). Дороги и ограничения могут отличаться от времени поездки.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if gap.from != nil && gap.to != nil {
                Button(estimate == nil ? "Запросить дорожный вариант у Apple" : "Повторить запрос к Apple") { calculate() }
                    .buttonStyle(PixelButtonStyle()).disabled(anyBusy)
                if busy { ProgressView("Запрос маршрута…") }
            } else {
                Text("Нет двух надёжных границ пропуска. Дорожный вариант построить нельзя.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixelPanel(Color.orange.opacity(0.08))
    }
}

struct RouteMap: UIViewRepresentable {
    let points: [TrackPoint]
    var estimates: [GPSRouteEstimate] = []
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.isRotateEnabled = false
        return view
    }
    func updateUIView(_ view: MKMapView, context: Context) {
        guard context.coordinator.count != points.count || context.coordinator.lastDate != points.last?.timestamp
            || context.coordinator.estimates != estimates else { return }
        context.coordinator.count = points.count; context.coordinator.lastDate = points.last?.timestamp
        context.coordinator.estimates = estimates
        view.removeOverlays(view.overlays)
        var rect = MKMapRect.null
        for segment in continuousTrackSegments(points) {
            var coordinates = segment.map(\.coordinate)
            guard coordinates.count > 1 else { continue }
            let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            view.addOverlay(line)
            rect = rect.union(line.boundingMapRect)
        }
        for estimate in estimates {
            var coordinates = estimate.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            guard coordinates.count > 1 else { continue }
            let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            line.title = "road-estimate"
            view.addOverlay(line)
            rect = rect.union(line.boundingMapRect)
        }
        // Initial fitting only. Do not override a user's map gesture on each GPS fix.
        if !context.coordinator.fitted, !rect.isNull {
            view.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 35, left: 30, bottom: 35, right: 30), animated: false)
            context.coordinator.fitted = true
        } else if !context.coordinator.fitted, let point = points.first {
            view.setRegion(MKCoordinateRegion(center: point.coordinate,
                latitudinalMeters: 1000, longitudinalMeters: 1000), animated: false)
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var count = -1
        var lastDate: Date?
        var estimates: [GPSRouteEstimate] = []
        var fitted = false
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            if line.title == "road-estimate" {
                renderer.strokeColor = .systemOrange
                renderer.lineDashPattern = [8, 7]
            } else {
                renderer.strokeColor = UIColor(red: 0.56, green: 0.93, blue: 0.37, alpha: 1)
            }
            renderer.lineWidth = 4
            return renderer
        }
    }
}

private func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}
