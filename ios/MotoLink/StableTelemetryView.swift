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
    @AppStorage("MotoLink.visual.rpmRedline") private var rpmRedline = 11_000
    @AppStorage("MotoLink.visual.speedWarm") private var speedWarm = 130
    @AppStorage("MotoLink.visual.speedHot") private var speedHot = 190

    private struct Reading {
        let title: String
        let value: String
        let number: Double?
        let unit: String
        let status: String
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let reading = reading(at: context.date)
                let scale = reading.number.flatMap {
                    FocusMetricScale.make(id: metric.id, value: $0,
                        rpmRedline: rpmRedline, speedWarm: speedWarm, speedHot: speedHot)
                }
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
                            .foregroundStyle(scale?.currentColor ?? (reading.number == nil ? MotoTheme.secondary : Color.primary))
                            .lineLimit(1).minimumScaleFactor(0.24)
                            .frame(maxWidth: .infinity)
                        if !reading.unit.isEmpty {
                            Text(reading.unit).font(MotoTheme.font(short ? .subheadline : .title3))
                                .foregroundStyle(MotoTheme.secondary)
                        }
                        if let scale {
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reading.title)
                .accessibilityValue(reading.value == "—" ? reading.status :
                    "\(reading.value) \(reading.unit). \(scale?.zone ?? ""). \(reading.status)")
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
        return min(min(size.width * widthFactor, size.height * 0.42), 240)
    }

    private func reading(at now: Date) -> Reading {
        if metric.id == "gps_speed" {
            #if targetEnvironment(simulator)
            if preview { return Reading(title: "Скорость GPS", value: "64", number: 64, unit: "км/ч", status: "Данные поступают") }
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

/// These colors are a rider-customizable visual aid, not bike diagnostics or
/// traffic-law limits. A missing or stale reading never receives a color zone.
private struct FocusMetricScale {
    enum Tone {
        case cold, calm, rising, warm, hot

        var color: Color {
            Color(UIColor { trait in
                let dark = trait.userInterfaceStyle == .dark
                switch self {
                case .cold: return dark ? UIColor(red: 0.43, green: 0.76, blue: 1, alpha: 1)
                                   : UIColor(red: 0.06, green: 0.37, blue: 0.75, alpha: 1)
                case .calm: return dark ? UIColor(red: 0.43, green: 0.83, blue: 0.56, alpha: 1)
                                   : UIColor(red: 0.06, green: 0.46, blue: 0.19, alpha: 1)
                case .rising: return dark ? UIColor(red: 1, green: 0.85, blue: 0.35, alpha: 1)
                                     : UIColor(red: 0.56, green: 0.38, blue: 0.02, alpha: 1)
                case .warm: return dark ? UIColor(red: 1, green: 0.63, blue: 0.31, alpha: 1)
                                   : UIColor(red: 0.68, green: 0.28, blue: 0.03, alpha: 1)
                case .hot: return dark ? UIColor(red: 1, green: 0.40, blue: 0.43, alpha: 1)
                                  : UIColor(red: 0.69, green: 0.06, blue: 0.13, alpha: 1)
                }
            })
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

    static func make(id: String, value: Double, rpmRedline: Int,
                     speedWarm: Int, speedHot: Int) -> Self? {
        guard value.isFinite else { return nil }
        switch id {
        case "engine_speed":
            let redline = Double(max(6_000, min(16_000, rpmRedline)))
            let stops: [(Double, Tone)] = [(redline * 0.60, .calm), (redline * 0.80, .rising),
                                           (redline, .warm), (.infinity, .hot)]
            let zone = value >= redline ? "Выше выбранной красной зоны"
                : value >= redline * 0.80 ? "Высокие обороты"
                : value >= redline * 0.60 ? "Обороты растут" : "Низкие обороты"
            return Self(value: value, minimum: 0, maximum: redline * 1.08, stops: stops,
                        zone: zone, note: "Порог настрой по приборке", leftLabel: "0",
                        rightLabel: String(format: "%.0f об/мин", redline))
        case "wheel_speed", "gps_speed":
            let first = Double(max(30, min(250, speedWarm)))
            let second = Double(max(Int(first) + 10, min(300, speedHot)))
            let zone = value >= second ? "Выше второго порога"
                : value >= first ? "Между порогами" : "До первого порога"
            return Self(value: value, minimum: 0, maximum: second + 20,
                        stops: [(first, .calm), (second, .warm), (.infinity, .hot)],
                        zone: zone, note: "Выбранные пороги цвета",
                        leftLabel: "0", rightLabel: "\(Int(first)) / \(Int(second)) км/ч")
        case "engine_water_temperature":
            let zone = value >= 110 ? "Очень высокая зона охлаждения"
                : value >= 100 ? "Высокая зона охлаждения"
                : value >= 60 ? "Средняя зона охлаждения" : "Низкая зона охлаждения"
            return Self(value: value, minimum: 0, maximum: 120,
                        stops: [(60, .cold), (100, .calm), (110, .warm), (.infinity, .hot)],
                        zone: zone, note: "Условная шкала охлаждения",
                        leftLabel: "0 °C", rightLabel: "120 °C")
        case "inlet_air_temperature":
            let zone = value >= 40 ? "Очень тёплый воздух"
                : value >= 30 ? "Тёплый воздух"
                : value >= 0 ? "Умеренная температура" : "Холодный воздух"
            return Self(value: value, minimum: -20, maximum: 60,
                        stops: [(0, .cold), (30, .calm), (40, .warm), (.infinity, .hot)],
                        zone: zone, note: "Воздух на впуске · не погода",
                        leftLabel: "−20 °C", rightLabel: "60 °C")
        default: return nil
        }
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
                    let sample = scale.minimum + (scale.maximum - scale.minimum) * Double(index + 1) / 16
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
    @AppStorage("MotoLink.visual.rpmRedline") private var rpmRedline = 11_000
    @AppStorage("MotoLink.visual.speedWarm") private var speedWarm = 130
    @AppStorage("MotoLink.visual.speedHot") private var speedHot = 190

    var body: some View {
        Form {
            PixelSection("Обороты") {
                Stepper(value: $rpmRedline, in: 6_000...16_000, step: 500) {
                    LabeledContent("Красная зона", value: "\(rpmRedline) об/мин")
                }
                Text("Укажи начало красной зоны по приборной панели своего мотоцикла. Исходные 11 000 об/мин — только ориентир для цветной шкалы.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            PixelSection("Скорость") {
                Stepper(value: $speedWarm, in: 30...max(30, min(250, speedHot - 10)), step: 10) {
                    LabeledContent("Оранжевый от", value: "\(speedWarm) км/ч")
                }
                Stepper(value: $speedHot, in: min(300, speedWarm + 10)...300, step: 10) {
                    LabeledContent("Красный от", value: "\(speedHot) км/ч")
                }
                Text("Это личные пороги оформления для скорости GPS и байка. Они не определяют разрешённую скорость и не исправляют показания.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
            PixelSection("Температура") {
                Text("Охлаждающая жидкость: синий ниже 60 °C, оранжевый от 100 °C, красный от 110 °C. Воздух на впуске: синий ниже 0 °C, красный от 40 °C.")
                Text("Цвета температуры условны и не заменяют указания на приборке или в руководстве мотоцикла.")
                    .font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            }
        }
        .font(MotoTheme.font(.body))
        .scrollContentBackground(.hidden)
        .background(MotoTheme.background)
        .navigationTitle("Цветовые шкалы")
        .navigationBarTitleDisplayMode(.inline)
    }
}
