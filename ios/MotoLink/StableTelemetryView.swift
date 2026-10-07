import Combine
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
    @AppStorage(MetricColorPreferences.storageKey) private var scaleSettingsData = Data()

    private var scalePreferences: MetricColorPreferences {
        MetricColorPreferences.decoded(scaleSettingsData) ?? MetricColorPreferences.load(persistMigration: false)
    }

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
        .onAppear { _ = MetricColorPreferences.load(); visible = true; updateRefreshTimer(for: scenePhase) }
        .onDisappear { visible = false; stopRefreshTimer() }
        .onChange(of: scenePhase) { phase in updateRefreshTimer(for: phase) }
        .onReceive(bluetooth.$dashboardTelemetry.dropFirst()) { latest in
            // Render new BLE values when published. The one-second timer below
            // remains only for freshness expiry and non-BLE state changes.
            guard visible && scenePhase == .active else { return }
            sample(catalogue: latest)
        }
    }

    private func sample(fromTimer: Bool = false, catalogue latest: TelemetryPresentation? = nil) {
        #if targetEnvironment(simulator)
        defer { ProductVisualRefreshProbe.sample(panel: "telemetry", fromTimer: fromTimer) }
        if preview { catalogue = ProductVisualData.catalogue(); connected = true; ready = true; sampledAt = Date(); return }
        #endif
        catalogue = latest ?? bluetooth.dashboardTelemetry
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
                            .foregroundStyle(metricColor(row))
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
                        .foregroundStyle(metricColor(row))
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

    private func metricColor(_ row: TelemetryPresentation.Row) -> Color {
        guard let value = row.value else { return MotoTheme.secondary }
        return MetricVisualColor.color(metricID: row.id, value: value, preferences: scalePreferences) ?? .primary
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
    @AppStorage(MetricColorPreferences.storageKey) private var scaleSettingsData = Data()

    private var scalePreferences: MetricColorPreferences {
        MetricColorPreferences.decoded(scaleSettingsData) ?? MetricColorPreferences.load(persistMigration: false)
    }

    private struct Reading {
        let title: String
        let value: String
        let number: Double?
        let unit: String
        let status: String
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by:
                scenePhase == .active && (metric.id == "engine_speed" || metric.id == "wheel_speed")
                    ? TelemetryDisplayCadence.foregroundInterval : 1)) { context in
                let reading = reading(at: context.date)
                let scale = reading.number.flatMap {
                    FocusMetricScale.make(id: metric.id, value: $0, preferences: scalePreferences)
                }
                let short = geometry.size.height < 420
                    || (metric.id == "engine_speed" && geometry.size.height < 620)
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
                            .font(MotoTheme.numberFont(size: metric.id == "engine_speed" && short
                                ? min(numberSize(in: geometry.size, value: reading.value), geometry.size.height * 0.25)
                                : numberSize(in: geometry.size, value: reading.value)).monospacedDigit())
                            .foregroundStyle(scale?.currentColor ?? (reading.number == nil ? MotoTheme.secondary : Color.primary))
                            .lineLimit(1).minimumScaleFactor(0.24)
                            .frame(maxWidth: .infinity)
                        if !reading.unit.isEmpty {
                            Text(reading.unit).font(MotoTheme.font(short ? .subheadline : .title3))
                                .foregroundStyle(MotoTheme.secondary)
                        }
                        if metric.id == "engine_speed" {
                            TachometerGaugeView(scale: scale, configuration: scalePreferences[.engineSpeed], short: short)
                                .padding(.top, short ? 5 : 12)
                        } else if let scale {
                            FocusMetricScaleView(scale: scale, short: short)
                                .padding(.top, short ? 8 : 18)
                        }
                        Text(reading.status).font(MotoTheme.font(short ? .caption : .subheadline))
                            .foregroundStyle(reading.number == nil ? Color.primary : MotoTheme.secondary)
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
                    .background {
                        RacingGaugeAccent(color: scale?.currentColor ?? MotoTheme.accent,
                                          strength: scale?.progress ?? 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reading.title)
                .accessibilityValue(reading.value == "—" ? reading.status :
                    "\(reading.value) \(reading.unit). \(scale?.zone ?? ""). \(reading.status)")
                .accessibilityHint("Дважды коснитесь, чтобы вернуться к общему виду")
            }
        }
        .background(MotoTheme.backdrop.ignoresSafeArea())
        .onAppear { _ = MetricColorPreferences.load(); updateScreenAwake() }
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
        return min(min(size.width * widthFactor, size.height * 0.42), 240)
    }

    private func reading(at now: Date) -> Reading {
        if metric.id == "gps_speed" {
            #if targetEnvironment(simulator)
            if preview {
                let speed = ProductVisualData.speedComparison().gps
                return Reading(title: "Скорость GPS", value: speed.map { String(format: "%.0f", $0) } ?? "—",
                               number: speed, unit: "км/ч", status: speed == nil ? "Нет свежих данных GPS" : "Данные поступают")
            }
            #endif
            let speed: Double? = rides.lastLocationAt.flatMap { timestamp in
                let age = now.timeIntervalSince(timestamp)
                guard age >= 0, age <= 3, let metersPerSecond = rides.speedMS,
                      metersPerSecond.isFinite, metersPerSecond >= 0 else { return nil }
                return metersPerSecond * 3.6
            }
            return Reading(title: "Скорость GPS", value: speed.map { String(format: "%.0f", $0) } ?? "—", number: speed,
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
        return Reading(title: title, value: value, number: row.value, unit: field.unit, status: status)
    }
}

/// Drawn only at the focused screen's bounded sample cadence. The dial has no
/// animation clock or flashing state, and an unavailable reading leaves it unlit.
private struct TachometerGaugeView: View {
    let scale: FocusMetricScale?
    let configuration: MetricColorScale
    let short: Bool

    private var selectedLimit: Double { Double(configuration.redStart) }
    private var selectedMaximum: Double { Double(configuration.maximum) }

    var body: some View {
        VStack(spacing: short ? 3 : 7) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height - 5)
                let radius = min(size.width * 0.45, size.height - 12)
                guard radius > 0 else { return }
                let divisions = 33
                let extent = selectedMaximum
                let lastActiveTick = scale.map { Int(floor($0.progress * Double(divisions - 1))) }
                let tickLength: CGFloat = short ? 13 : 22
                for index in 0..<divisions {
                    let fraction = Double(index) / Double(divisions - 1)
                    let angle = Double.pi * (1 - fraction)
                    let direction = CGPoint(x: CGFloat(cos(angle)), y: -CGFloat(sin(angle)))
                    let inner = CGPoint(x: center.x + direction.x * (radius - tickLength),
                                        y: center.y + direction.y * (radius - tickLength))
                    let outer = CGPoint(x: center.x + direction.x * radius,
                                        y: center.y + direction.y * radius)
                    var tick = Path()
                    tick.move(to: inner)
                    tick.addLine(to: outer)
                    let color: Color
                    if fraction <= (scale?.progress ?? -1) {
                        color = index == lastActiveTick ? scale?.currentColor ?? MotoTheme.border
                            : scale?.tone(at: extent * fraction).color ?? MotoTheme.border
                    } else { color = MotoTheme.border }
                    context.stroke(tick, with: .color(color),
                                   style: StrokeStyle(lineWidth: short ? 3 : 5, lineCap: .square))
                }

                // The red mark is the rider's chosen display threshold, not a
                // claimed ECU limit for every Kawasaki model.
                let limitFraction = selectedLimit / extent
                let limitAngle = Double.pi * (1 - limitFraction)
                let limitDirection = CGPoint(x: CGFloat(cos(limitAngle)), y: -CGFloat(sin(limitAngle)))
                var mark = Path()
                mark.move(to: CGPoint(x: center.x + limitDirection.x * (radius - tickLength - 7),
                                      y: center.y + limitDirection.y * (radius - tickLength - 7)))
                mark.addLine(to: CGPoint(x: center.x + limitDirection.x * (radius + 2),
                                         y: center.y + limitDirection.y * (radius + 2)))
                context.stroke(mark, with: .color(scale == nil ? MotoTheme.border : FocusMetricScale.Tone.hot.color),
                               style: StrokeStyle(lineWidth: 2, lineCap: .square))

                if let scale {
                    let angle = Double.pi * (1 - scale.progress)
                    var needle = Path()
                    needle.move(to: center)
                    needle.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * (radius - tickLength - 11),
                                               y: center.y - CGFloat(sin(angle)) * (radius - tickLength - 11)))
                    context.stroke(needle, with: .color(scale.currentColor),
                                   style: StrokeStyle(lineWidth: short ? 2 : 4, lineCap: .square))
                    context.fill(Path(CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                                 with: .color(scale.currentColor))
                }
            }
            .frame(height: short ? 74 : 180)

            HStack {
                Text("0")
                Spacer(minLength: 4)
                Text("\(Int(selectedMaximum / 2))")
                Spacer(minLength: 4)
                Text("\(Int(selectedMaximum))")
            }
            .font(MotoTheme.font(.caption))
            .foregroundStyle(MotoTheme.secondary)
            .lineLimit(1).minimumScaleFactor(0.65)

            if let scale, scale.value >= Double(configuration.orangeStart) {
                Text(scale.value >= selectedLimit ? "Красный от \(configuration.redStart)" : "Оранжевый от \(configuration.orangeStart)")
                    .font(MotoTheme.font(.caption))
                    .foregroundStyle(scale.currentColor)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(short ? 9 : 15)
        .frame(maxWidth: 620)
        .pixelPanel(accent: scale.map { $0.value >= selectedLimit } ?? false)
        .accessibilityHidden(true)
    }
}

/// Shared by the dashboard, speed comparison and focused gauges. A missing or
/// stale reading receives no zone; display colors never alter measured values.
enum MetricVisualColor {
    static func color(metricID: String, value: Double?, preferences: MetricColorPreferences) -> Color? {
        guard let value, let kind = MetricColorKind.forMetric(metricID),
              let zone = preferences[kind].zone(at: value) else { return nil }
        return color(zone)
    }

    static func color(_ zone: MetricColorZone) -> Color {
        Color(UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            switch zone {
            case .green: return dark ? UIColor(red: 0.43, green: 0.83, blue: 0.56, alpha: 1)
                                    : UIColor(red: 0.06, green: 0.46, blue: 0.19, alpha: 1)
            case .orange: return dark ? UIColor(red: 1, green: 0.63, blue: 0.31, alpha: 1)
                                     : UIColor(red: 0.68, green: 0.28, blue: 0.03, alpha: 1)
            case .red: return dark ? UIColor(red: 1, green: 0.40, blue: 0.43, alpha: 1)
                                  : UIColor(red: 0.69, green: 0.06, blue: 0.13, alpha: 1)
            }
        })
    }
}

/// These colors are a rider-customizable visual aid, not bike diagnostics or
/// traffic-law limits. A missing or stale reading never receives a color zone.
private struct FocusMetricScale {
    enum Tone {
        case calm, warm, hot
        var color: Color {
            switch self {
            case .calm: return MetricVisualColor.color(.green)
            case .warm: return MetricVisualColor.color(.orange)
            case .hot: return MetricVisualColor.color(.red)
            }
        }
    }

    let value: Double
    let minimum: Double
    let maximum: Double
    let stops: [(upper: Double, tone: Tone)]
    let zone: String
    let note: String
    let leftLabel: String
    let rightLabel: String

    var currentColor: Color { tone(at: value).color }
    var progress: Double { min(1, max(0, (value - minimum) / (maximum - minimum))) }

    func tone(at value: Double) -> Tone {
        stops.first { value < $0.upper }?.tone ?? .hot
    }

    static func make(id: String, value: Double, preferences: MetricColorPreferences) -> Self? {
        guard value.isFinite, let kind = MetricColorKind.forMetric(id) else { return nil }
        let configuration = preferences[kind]
        let zone: String
        switch configuration.zone(at: value) {
        case .green: zone = "Зелёная зона"
        case .orange: zone = "Оранжевая зона"
        case .red: zone = "Красная зона"
        case nil: return nil
        }
        let suffix = kind.unit.isEmpty ? "" : " " + kind.unit
        return Self(value: value, minimum: Double(kind.settingRange.lowerBound), maximum: Double(configuration.maximum),
                    stops: [(Double(configuration.orangeStart), .calm), (Double(configuration.redStart), .warm), (.infinity, .hot)],
                    zone: zone, note: "От \(configuration.orangeStart) / \(configuration.redStart)",
                    leftLabel: "\(kind.settingRange.lowerBound)\(suffix)", rightLabel: "\(configuration.maximum)\(suffix)")
    }
}

private struct FocusMetricScaleView: View {
    let scale: FocusMetricScale
    let short: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: short ? 5 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(scale.zone).foregroundStyle(scale.currentColor)
                Spacer(minLength: 4)
                Text(scale.note).foregroundStyle(MotoTheme.secondary)
            }
            .font(MotoTheme.font(.caption))
            .lineLimit(1).minimumScaleFactor(0.7)
            HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    // The last lit cell reflects the exact current zone instead
                    // of turning red early at its quantized right-hand edge.
                    let sample = min(scale.value,
                        scale.minimum + (scale.maximum - scale.minimum) * Double(index + 1) / 16)
                    Rectangle()
                        .fill(Double(index) / 16 < scale.progress ? scale.tone(at: sample).color : MotoTheme.border)
                        .frame(maxWidth: .infinity, minHeight: short ? 8 : 12, maxHeight: short ? 8 : 12)
                }
            }.accessibilityHidden(true)
            HStack {
                Text(scale.leftLabel)
                Spacer(minLength: 4)
                Text(scale.rightLabel)
            }
            .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: 600)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Цветовая шкала: \(scale.zone). \(scale.note)")
    }
}

struct MetricVisualSettingsView: View {
    var preview = false
    @AppStorage(MetricColorPreferences.storageKey) private var scaleSettingsData = Data()

    private var preferences: MetricColorPreferences {
        #if targetEnvironment(simulator)
        if preview { return MetricScaleVisualCheckView.preferences }
        #endif
        return MetricColorPreferences.decoded(scaleSettingsData) ?? MetricColorPreferences.load(persistMigration: false)
    }

    var body: some View {
        Form {
            PixelSection("Показатели") {
                ForEach(MetricColorKind.configurable) { kind in
                    NavigationLink {
                        MetricColorEditorView(kind: kind, previewScale: preview ? preferences[kind] : nil)
                    } label: {
                        let settings = preferences[kind]
                        VStack(alignment: .leading, spacing: 5) {
                            Text(kind.title).foregroundStyle(Color.primary)
                            Text("\(settings.orangeStart) / \(settings.redStart)\(kind.unit.isEmpty ? "" : " " + kind.unit)")
                                .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                            if kind == .speed {
                                Text("GPS и мотоцикл").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .font(MotoTheme.font(.body))
        .scrollContentBackground(.hidden)
        .background(MotoTheme.backdrop)
        .navigationTitle("Цветовые шкалы")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !preview { _ = MetricColorPreferences.load() } }
    }
}

private struct MetricColorEditorView: View {
    let kind: MetricColorKind
    var previewScale: MetricColorScale? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft = MetricColorDraft(MetricColorKind.speed.defaultScale)
    @State private var prepared = false
    @State private var attemptedSave = false
    @State private var saveError: String?
    @FocusState private var focusedField: MetricColorField?

    private var validation: (scale: MetricColorScale?, errors: [MetricColorField: String]) {
        draft.validation(for: kind)
    }

    private var editorTitle: String {
        switch kind {
        case .speed: return "Скорость"
        case .engineSpeed: return "Обороты"
        case .coolantTemperature: return "Охлаждение"
        case .inletTemperature: return "Воздух"
        case .throttle: return "Дроссель"
        case .gear: return "Передача"
        case .voltage: return "Напряжение"
        }
    }

    var body: some View {
        Form {
            PixelSection(kind.unit.isEmpty ? "Границы цвета" : "Границы цвета · \(kind.unit)") {
                numberField(.orangeStart, color: FocusMetricScale.Tone.warm.color)
                numberField(.redStart, color: FocusMetricScale.Tone.hot.color)
                Text("Зелёный ниже первого порога. Равные пороги — сразу красный.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            PixelSection("Шкала") {
                numberField(.maximum)
                Text("Диапазон \(kind.settingRange.lowerBound)…\(kind.settingRange.upperBound)\(kind.unit.isEmpty ? "" : " " + kind.unit)")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            if kind == .speed {
                Text("Одинаково для GPS и скорости мотоцикла.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            if let saveError { Text(saveError).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.accent) }
        }
        .font(MotoTheme.font(.body))
        .scrollContentBackground(.hidden)
        .background(MotoTheme.backdrop)
        .navigationTitle(editorTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить", action: save).font(MotoTheme.font(.subheadline))
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { focusedField = nil }.font(MotoTheme.font(.subheadline))
            }
        }
        .onAppear {
            guard !prepared else { return }
            draft = MetricColorDraft(previewScale ?? MetricColorPreferences.load()[kind])
            prepared = true
        }
    }

    private func numberField(_ field: MetricColorField, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(field.title + (kind.unit.isEmpty ? "" : " · " + kind.unit))
                .font(MotoTheme.font(.subheadline)).foregroundStyle(color)
            if typeSize.isAccessibilitySize {
                numberInput(field)
                HStack(spacing: 12) {
                    Spacer()
                    adjustmentButton(field, delta: -1)
                    adjustmentButton(field, delta: 1)
                }
            } else {
                HStack(spacing: 12) {
                    numberInput(field)
                    adjustmentButton(field, delta: -1)
                    adjustmentButton(field, delta: 1)
                }
            }
            if attemptedSave, let error = validation.errors[field] {
                Text(error).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 4)
    }

    private func numberInput(_ field: MetricColorField) -> some View {
        TextField("Число", text: Binding(get: { draft[field] }, set: { draft[field] = $0; saveError = nil }))
            .font(MotoTheme.numberFont(size: 25).monospacedDigit())
            .keyboardType(.numbersAndPunctuation)
            .focused($focusedField, equals: field)
            .accessibilityLabel("\(field.title), \(kind.unit)")
            .frame(minHeight: 44)
    }

    private func adjustmentButton(_ field: MetricColorField, delta: Int) -> some View {
        let next = MetricColorDraft.integer(draft[field]).map { $0.addingReportingOverflow(delta) }
        let allowed = next.map { !$0.overflow && kind.settingRange.contains($0.partialValue) } ?? false
        return Button {
            if let next, allowed { draft[field] = String(next.partialValue); saveError = nil }
        } label: {
            Image(systemName: delta > 0 ? "plus" : "minus")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 44, height: 44)
                .background(MotoTheme.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(allowed ? MotoTheme.accent : MotoTheme.secondary.opacity(0.5))
        .disabled(!allowed)
        .accessibilityLabel("\(field.title): \(delta > 0 ? "плюс" : "минус") один")
    }

    private func save() {
        attemptedSave = true
        guard let scale = validation.scale else {
            focusedField = MetricColorField.allCases.first { validation.errors[$0] != nil }
            return
        }
        if previewScale != nil { focusedField = nil; dismiss(); return }
        do {
            var preferences = MetricColorPreferences.load()
            preferences[kind] = scale
            try preferences.save()
            focusedField = nil
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}

#if targetEnvironment(simulator)
/// Renders the real settings and editor with disposable fixture values.
/// Never changes stored rider settings, on BLE hardware or in the simulator.
struct MetricScaleVisualCheckView: View {
    var editor = false

    static var preferences: MetricColorPreferences {
        var value = MetricColorPreferences()
        value[.speed] = MetricColorScale(orangeStart: 128, redStart: 160, maximum: 210)
        return value
    }

    var body: some View {
        NavigationStack {
            if editor {
                MetricColorEditorView(kind: .speed, previewScale: Self.preferences[.speed])
            } else {
                MetricVisualSettingsView(preview: true)
            }
        }
    }
}
#endif
