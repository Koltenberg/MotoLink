import SwiftUI
import UIKit

/// Stable identities and sampled values keep telemetry readable while the BLE
/// parser and journal retain every packet independently of the screen refresh.
struct MotorcycleDashboardView: View, Equatable {
    let bluetooth: MotorcycleBluetooth
    var preview = false
    var compact = false
    var onSelect: (String) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var speedSize = 54.0
    @State private var catalogue = TelemetryPresentation()
    @State private var connected = false
    @State private var ready = false
    @State private var sampledAt = Date()
    @State private var refreshTimer: Timer?
    @State private var visible = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bluetooth === rhs.bluetooth && lhs.preview == rhs.preview && lhs.compact == rhs.compact
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: compact ? 3 : typeSize.isAccessibilitySize ? 1 : 3)
    }

    private var display: (catalogue: TelemetryPresentation, connected: Bool, ready: Bool, at: Date) {
        #if targetEnvironment(simulator)
        if preview {
            let now = Date()
            return (ProductVisualData.catalogue(at: now), true, true, now)
        }
        #endif
        return (catalogue, connected, ready, sampledAt)
    }

    var body: some View {
        Group {
            let snapshot = display
            let primary = ["gear_position", "engine_water_temperature", "engine_speed"].map { id in
                snapshot.catalogue.row(snapshot.catalogue.fields.first(where: { $0.id == id }) ?? TelemetryPresentation.placeholder(id),
                    connected: snapshot.connected, ready: snapshot.ready, now: snapshot.at)
            }
            let additional = snapshot.catalogue.rows(connected: snapshot.connected, ready: snapshot.ready, now: snapshot.at)
                .filter { !TelemetryPresentation.primaryIDs.contains($0.id) && $0.id != "fuel_injection_raw" && $0.field.decoded }
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(primary) { row in card(row) }
                }
                if !compact && !additional.isEmpty {
                    DisclosureGroup("Другие показатели") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(additional) { row in card(row) }
                        }.padding(.top, 10)
                    }.font(MotoTheme.font(.subheadline))
                }
            }
            .transaction { $0.animation = nil }
        }
        .onAppear { visible = true; updateRefreshTimer(for: scenePhase) }
        .onDisappear { visible = false; stopRefreshTimer() }
        .onChange(of: scenePhase) { phase in updateRefreshTimer(for: phase) }
    }

    private func sample(fromTimer: Bool = false) {
        #if targetEnvironment(simulator)
        defer { ProductVisualRefreshProbe.sample(panel: "telemetry", fromTimer: fromTimer) }
        if preview { catalogue = ProductVisualData.catalogue(); connected = true; ready = true; sampledAt = Date(); return }
        #endif
        catalogue = bluetooth.dashboardTelemetry
        connected = bluetooth.connected
        ready = bluetooth.ready
        sampledAt = Date()
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func updateRefreshTimer(for phase: ScenePhase) {
        stopRefreshTimer()
        guard visible else { return }
        sample()
        // Legacy onChange captures the previous View state. Its argument is
        // the new phase: reading self.scenePhase here can leave the timer off
        // after returning to the foreground until this view appears again.
        guard phase == .active else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in sample(fromTimer: true) }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @ViewBuilder private func card(_ row: TelemetryPresentation.Row, prominent: Bool = false) -> some View {
        Button { onSelect(row.id) } label: {
            if compact {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.id == "engine_water_temperature" ? "Температура" : row.id == "engine_speed" ? "Обороты" : row.field.label)
                        .font(MotoTheme.font(.caption)).lineLimit(1).minimumScaleFactor(0.8)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(number(row)).font(MotoTheme.numberFont(size: 24).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .foregroundStyle(row.value == nil ? MotoTheme.secondary : Color.primary)
                        if !row.field.unit.isEmpty {
                            Text(row.field.unit).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .pixelPanel(accent: prominent)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.id == "engine_water_temperature" ? "Температура" : row.id == "engine_speed" ? "Обороты" : row.field.label).font(MotoTheme.font(.caption))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(number(row)).font(MotoTheme.font(.title).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(row.value == nil ? MotoTheme.secondary : Color.primary)
                    // Units get their own line so a three-digit speed or five-digit RPM
                    // does not wrap on an iPhone SE beside the fixed gear card.
                    Text(row.field.unit.isEmpty ? " " : row.field.unit).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .pixelPanel(accent: prominent)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(row.field.label)
        .accessibilityValue(row.value == nil ? status(row) : "\(number(row)) \(row.field.unit)")
        .accessibilityHint("Дважды коснитесь, чтобы увеличить показатель")
    }

    private func number(_ row: TelemetryPresentation.Row) -> String {
        guard let value = row.value else { return "—" }
        return String(format: row.field.unit == "В" ? "%.2f" : "%.0f", value)
    }

    private func overallStatus(_ rows: [TelemetryPresentation.Row]) -> String {
        if !connected { return "Нет связи с байком" }
        if !ready { return "Ожидаем показатели" }
        let fresh = rows.filter { $0.value != nil }.count
        if fresh == rows.count { return "Данные поступают" }
        return fresh > 0 ? "Часть показателей пока недоступна" : "Нет свежих данных"
    }

    private func status(_ row: TelemetryPresentation.Row) -> String {
        switch row.state {
        case .receiving: return row.id == "fuel_injection_raw" ? "Исходное значение без расшифровки" : "Данные поступают"
        case .stale: return "Нет свежих данных"
        case .disconnected: return "Нет связи с байком"
        case .notDecoded: return "Формат не расшифрован"
        case .unavailable: return "Недоступно у этого байка"
        case .waiting: return "Нет данных"
        }
    }
}

struct FocusedRideMetric: Identifiable {
    let id: String
}

/// A single large reading uses the same in-memory telemetry and freshness rules
/// as the dashboard. Opening it does not start a BLE request or location update.
struct FocusedRideMetricView: View {
    let bluetooth: MotorcycleBluetooth
    let rides: RideRecorder
    let metric: FocusedRideMetric
    var preview = false
    let onDismiss: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("MotoLink.keepScreenOn") private var keepScreenOn = false

    private struct Reading {
        let title: String
        let value: String
        let unit: String
        let status: String
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let reading = reading(at: context.date)
                let short = geometry.size.height < 420
                Button(action: onDismiss) {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 12) {
                            Text(reading.title).font(MotoTheme.font(short ? .subheadline : .title3))
                                .lineLimit(2).minimumScaleFactor(0.75)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.title3).foregroundStyle(MotoTheme.secondary)
                                .accessibilityHidden(true)
                        }
                        Spacer(minLength: 8)
                        Text(reading.value)
                            .font(MotoTheme.numberFont(size: numberSize(in: geometry.size, value: reading.value)).monospacedDigit())
                            .foregroundStyle(reading.value == "—" ? MotoTheme.secondary : Color.primary)
                            .lineLimit(1).minimumScaleFactor(0.24)
                            .frame(maxWidth: .infinity)
                        if !reading.unit.isEmpty {
                            Text(reading.unit).font(MotoTheme.font(short ? .subheadline : .title3))
                                .foregroundStyle(MotoTheme.secondary)
                        }
                        Text(reading.status).font(MotoTheme.font(short ? .caption : .subheadline))
                            .foregroundStyle(MotoTheme.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .padding(.top, short ? 6 : 12)
                        Spacer(minLength: 8)
                        Text("Коснитесь экрана, чтобы вернуться")
                            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2).minimumScaleFactor(0.7)
                    }
                    .padding(geometry.size.height < 420 ? 16 : 24)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reading.title)
                .accessibilityValue(reading.value == "—" ? reading.status :
                    "\(reading.value) \(reading.unit). \(reading.status)")
                .accessibilityHint("Дважды коснитесь, чтобы вернуться к общему виду")
            }
        }
        .background(MotoTheme.background.ignoresSafeArea())
        .onAppear { updateScreenAwake() }
        .onChange(of: scenePhase) { phase in updateScreenAwake(phase: phase) }
        .onChange(of: keepScreenOn) { _ in updateScreenAwake() }
        .onChange(of: rides.active?.id) { _ in updateScreenAwake() }
    }

    private func updateScreenAwake(phase: ScenePhase? = nil) {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn && rides.active != nil
            && (phase ?? scenePhase) == .active
    }

    private func numberSize(in size: CGSize, value: String) -> CGFloat {
        let widthFactor: CGFloat = value.count <= 2 ? 0.70 : value.count <= 3 ? 0.48 : 0.33
        return min(min(size.width * widthFactor, size.height * 0.54), 260)
    }

    private func reading(at now: Date) -> Reading {
        if metric.id == "gps_speed" {
            #if targetEnvironment(simulator)
            if preview { return Reading(title: "Скорость GPS", value: "64", unit: "км/ч", status: "Данные поступают") }
            #endif
            let speed: Double? = rides.lastLocationAt.flatMap { timestamp in
                let age = now.timeIntervalSince(timestamp)
                guard age >= 0, age <= 3, let metersPerSecond = rides.speedMS,
                      metersPerSecond.isFinite, metersPerSecond >= 0 else { return nil }
                return metersPerSecond * 3.6
            }
            return Reading(title: "Скорость GPS", value: speed.map { String(format: "%.0f", $0) } ?? "—",
                           unit: "км/ч", status: speed == nil ? "Нет свежих данных GPS" : "Данные поступают")
        }

        let catalogue: TelemetryPresentation
        let connected: Bool
        let ready: Bool
        #if targetEnvironment(simulator)
        if preview {
            catalogue = ProductVisualData.catalogue(at: now)
            connected = true
            ready = true
        } else {
            catalogue = bluetooth.dashboardTelemetry
            connected = bluetooth.connected
            ready = bluetooth.ready
        }
        #else
        catalogue = bluetooth.dashboardTelemetry
        connected = bluetooth.connected
        ready = bluetooth.ready
        #endif
        let field = catalogue.fields.first { $0.id == metric.id }
            ?? TelemetryPresentation.placeholder(metric.id)
        let row = catalogue.row(field, connected: connected, ready: ready, now: now)
        let title: String
        switch metric.id {
        case "wheel_speed": title = "Скорость мотоцикла"
        case "engine_speed": title = "Обороты двигателя"
        case "engine_water_temperature": title = "Температура охлаждения"
        default: title = field.label
        }
        let value = row.value.map { String(format: field.unit == "В" ? "%.2f" : "%.0f", $0) } ?? "—"
        let status: String
        switch row.state {
        case .receiving: status = "Данные поступают"
        case .waiting: status = "Ожидаем показатель"
        case .stale: status = "Нет свежих данных"
        case .disconnected: status = "Нет связи с байком"
        case .notDecoded: status = "Формат не расшифрован"
        case .unavailable: status = "Недоступно у этого байка"
        }
        return Reading(title: title, value: value, unit: field.unit, status: status)
    }
}
