import SwiftUI

/// Stable identities and sampled values keep telemetry readable while the BLE
/// parser and journal retain every packet independently of the screen refresh.
struct MotorcycleDashboardView: View, Equatable {
    let bluetooth: MotorcycleBluetooth
    var preview = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var speedSize = 54.0
    @State private var catalogue = TelemetryPresentation()
    @State private var connected = false
    @State private var ready = false
    @State private var sampledAt = Date()
    @State private var refreshTimer: Timer?
    @State private var visible = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bluetooth === rhs.bluetooth && lhs.preview == rhs.preview }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: typeSize.isAccessibilitySize ? 1 : 3)
    }

    var body: some View {
        Group {
            let primary = ["gear_position", "engine_water_temperature", "engine_speed"].map { id in
                catalogue.row(catalogue.fields.first(where: { $0.id == id }) ?? TelemetryPresentation.placeholder(id),
                    connected: connected, ready: ready, now: sampledAt)
            }
            let additional = catalogue.rows(connected: connected, ready: ready, now: sampledAt)
                .filter { !TelemetryPresentation.primaryIDs.contains($0.id) && $0.id != "fuel_injection_raw" && $0.field.decoded }
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(primary) { row in card(row) }
                }
                if !additional.isEmpty {
                    DisclosureGroup("Другие показатели") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(additional) { row in card(row) }
                        }.padding(.top, 10)
                    }.font(MotoTheme.font(.subheadline))
                }
            }
            .transaction { $0.animation = nil }
        }
        .onAppear { visible = true; updateRefreshTimer() }
        .onDisappear { visible = false; stopRefreshTimer() }
        .onChange(of: scenePhase) { _ in updateRefreshTimer() }
    }

    private func sample() {
        #if targetEnvironment(simulator)
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

    private func updateRefreshTimer() {
        stopRefreshTimer()
        guard visible, scenePhase == .active else { return }
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in sample() }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func card(_ row: TelemetryPresentation.Row, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.id == "engine_water_temperature" ? "Температура" : row.id == "engine_speed" ? "Обороты" : row.field.label).font(.system(.caption))
                .fixedSize(horizontal: false, vertical: true)
            Text(number(row)).font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(row.value == nil ? Color.secondary : Color.primary)
            // Units get their own line so a three-digit speed or five-digit RPM
            // does not wrap on an iPhone SE beside the fixed gear card.
            Text(row.field.unit.isEmpty ? " " : row.field.unit).font(.system(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .pixelPanel(accent: prominent)
        .accessibilityElement(children: .combine)
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
