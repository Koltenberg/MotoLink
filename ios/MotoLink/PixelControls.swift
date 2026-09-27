import SwiftUI

struct PixelInfoButton: View {
    let title: String
    let detail: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "info.circle") }
            .accessibilityLabel(title)
            .sheet(isPresented: $showing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(title).font(MotoTheme.font(.title2))
                        Text(detail).font(MotoTheme.font(.body))
                        Button("Готово") { showing = false }.buttonStyle(PixelButtonStyle())
                    }.padding(20)
                }.background(MotoTheme.background).presentationDetents([.medium, .large])
            }
    }
}

extension View {
    func pixelConfirmationDialog<Actions: View>(_ title: String, isPresented: Binding<Bool>,
        titleVisibility: Visibility = .visible, @ViewBuilder actions: () -> Actions) -> some View {
        pixelConfirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility,
                                actions: actions, message: { EmptyView() })
    }

    func pixelConfirmationDialog<Actions: View, Message: View>(_ title: String,
        isPresented: Binding<Bool>, titleVisibility: Visibility = .visible,
        @ViewBuilder actions: () -> Actions, @ViewBuilder message: () -> Message) -> some View {
        let buttons = actions()
        let explanation = message()
        return sheet(isPresented: isPresented) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        Text(title).font(MotoTheme.font(.title2))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button { isPresented.wrappedValue = false } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }.accessibilityLabel("Закрыть").buttonStyle(.plain)
                    }
                    explanation.font(MotoTheme.font(.body))
                    VStack(spacing: 12) { buttons }
                        .buttonStyle(PixelDialogActionStyle(isPresented: isPresented))
                }.padding(20)
            }.background(MotoTheme.background)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
}

private struct PixelDialogActionStyle: PrimitiveButtonStyle {
    @Binding var isPresented: Bool
    func makeBody(configuration: Configuration) -> some View {
        Button {
            isPresented = false
            configuration.trigger()
        } label: {
            configuration.label.font(MotoTheme.font(.headline))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(12)
                .foregroundStyle(configuration.role == .destructive ? MotoTheme.accent : Color.primary)
                .pixelPanel(accent: configuration.role == .destructive)
        }.buttonStyle(.plain)
    }
}

struct PixelChoiceOption: Identifiable, Equatable {
    let value: String
    let label: String
    var id: String { value }
}

/// A field owned by Moto Link; the system keyboard remains the standard iPhone keyboard.
struct PixelDateField: View {
    let title: String
    @Binding var selection: Date
    var includesTime = false
    @State private var editing = false

    private var value: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = includesTime ? "dd.MM.yyyy · HH:mm" : "dd.MM.yyyy"
        return formatter.string(from: selection)
    }

    var body: some View {
        Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(value).font(MotoTheme.font(.body)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil").foregroundStyle(MotoTheme.accent)
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(title).accessibilityValue(value)
            .sheet(isPresented: $editing) {
                PixelDateEditor(title: title, initial: selection, includesTime: includesTime) {
                    selection = $0
                }
            }
    }
}

struct PixelChoiceField: View {
    let title: String
    @Binding var selection: String
    let options: [PixelChoiceOption]
    @State private var editing = false

    private var value: String { options.first { $0.value == selection }?.label ?? "Выбрать" }

    var body: some View {
        Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(value).font(MotoTheme.font(.body)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").foregroundStyle(MotoTheme.accent)
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(title).accessibilityValue(value)
            .sheet(isPresented: $editing) {
                PixelChoiceEditor(title: title, initial: selection, options: options) {
                    selection = $0
                }
            }
    }
}

private struct PixelDateEditor: View {
    let title: String
    let initial: Date
    let includesTime: Bool
    let onCommit: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var day: String
    @State private var month: String
    @State private var year: String
    @State private var hour: String
    @State private var minute: String

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    init(title: String, initial: Date, includesTime: Bool, onCommit: @escaping (Date) -> Void) {
        self.title = title
        self.initial = initial
        self.includesTime = includesTime
        self.onCommit = onCommit
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.day, .month, .year, .hour, .minute], from: initial)
        _day = State(initialValue: String(parts.day ?? 1))
        _month = State(initialValue: String(parts.month ?? 1))
        _year = State(initialValue: String(parts.year ?? 2000))
        _hour = State(initialValue: String(format: "%02d", parts.hour ?? 0))
        _minute = State(initialValue: String(format: "%02d", parts.minute ?? 0))
    }

    private func validated(now: Date = Date()) -> (date: Date?, error: String?) {
        func number(_ text: String) -> Int? {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(clean)
        }
        guard let d = number(day), let m = number(month), let y = number(year),
              (1...31).contains(d), (1...12).contains(m), (1...9999).contains(y) else {
            return (nil, "Укажи день, месяц и год.")
        }
        let h = includesTime ? number(hour) : 0
        let min = includesTime ? number(minute) : 0
        guard let h, let min, (0...23).contains(h), (0...59).contains(min) else {
            return (nil, "Часы: от 0 до 23. Минуты: от 0 до 59.")
        }
        var parts = DateComponents()
        parts.year = y; parts.month = m; parts.day = d
        parts.hour = h; parts.minute = min; parts.second = 0
        guard let value = calendar.date(from: parts), value.timeIntervalSince1970.isFinite else {
            return (nil, "Такой даты нет. Проверь числа.")
        }
        // Calendar.date normalises 31 February and daylight-saving time gaps.
        // Round-trip validation prevents silently saving a different date/time.
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: value)
        guard check.year == y, check.month == m, check.day == d,
              !includesTime || (check.hour == h && check.minute == min) else {
            return (nil, includesTime ? "Такой даты или местного времени нет." : "Такой даты нет. Проверь числа.")
        }
        guard value <= now else { return (nil, "Будущую дату указывать нельзя.") }

        let original = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: initial)
        let unchanged = original.year == y && original.month == m && original.day == d
            && (!includesTime || (original.hour == h && original.minute == min))
        // Opening and confirming a field does not remove the original seconds.
        if unchanged, initial <= now { return (initial, nil) }
        return (value, nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(MotoTheme.font(.title2)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("День, месяц и год").font(MotoTheme.font(.body)).foregroundStyle(MotoTheme.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top),
                    count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 12) {
                    numberField("День", text: $day, example: "27")
                    numberField("Месяц", text: $month, example: "09")
                    numberField("Год", text: $year, example: "2026")
                }
                if includesTime {
                    HStack(alignment: .top, spacing: 12) {
                        numberField("Часы", text: $hour, example: "14")
                        numberField("Минуты", text: $minute, example: "30")
                    }
                    Text("Время на этом iPhone").font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
                }
                Button(includesTime ? "Сейчас" : "Сегодня") { useToday() }
                    .buttonStyle(PixelButtonStyle())
                if let error = validated().error {
                    Text(error).font(MotoTheme.font(.body)).foregroundStyle(MotoTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(20)
        }.background(MotoTheme.background)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Отмена") { dismiss() }.buttonStyle(PixelButtonStyle())
                    Spacer(minLength: 0)
                    Button("Готово") {
                        guard let value = validated().date else { return }
                        onCommit(value)
                        dismiss()
                    }.buttonStyle(PixelButtonStyle(prominent: true)).disabled(validated().date == nil)
                }.padding(16).background(MotoTheme.background)
            }
            .presentationDragIndicator(.visible)
    }

    private func numberField(_ label: String, text: Binding<String>, example: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(MotoTheme.font(.caption)).foregroundStyle(MotoTheme.secondary)
            TextField(example, text: text)
                .font(MotoTheme.font(.title3)).keyboardType(.numberPad)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).pixelPanel()
                .accessibilityLabel(label)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func useToday() {
        let parts = calendar.dateComponents([.day, .month, .year, .hour, .minute], from: Date())
        day = String(parts.day ?? 1)
        month = String(parts.month ?? 1)
        year = String(parts.year ?? 2000)
        if includesTime {
            hour = String(format: "%02d", parts.hour ?? 0)
            minute = String(format: "%02d", parts.minute ?? 0)
        }
    }
}

private struct PixelChoiceEditor: View {
    let title: String
    let options: [PixelChoiceOption]
    let onCommit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(title: String, initial: String, options: [PixelChoiceOption], onCommit: @escaping (String) -> Void) {
        self.title = title
        self.options = options
        self.onCommit = onCommit
        _draft = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(MotoTheme.font(.title2)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(options) { option in
                    Button { draft = option.value } label: {
                        HStack(alignment: .center, spacing: 14) {
                            Rectangle().fill(draft == option.value ? MotoTheme.accent : Color.clear)
                                .frame(width: 12, height: 12)
                                .overlay(Rectangle().stroke(MotoTheme.accent, lineWidth: 2))
                                .accessibilityHidden(true)
                            Text(option.label).font(MotoTheme.font(.body)).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(12).pixelPanel(accent: draft == option.value)
                    }.buttonStyle(.plain)
                        .accessibilityValue(draft == option.value ? "Выбрано" : "")
                }
            }.padding(20)
        }.background(MotoTheme.background)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Отмена") { dismiss() }.buttonStyle(PixelButtonStyle())
                    Spacer(minLength: 0)
                    Button("Готово") {
                        guard options.contains(where: { $0.value == draft }) else { return }
                        onCommit(draft)
                        dismiss()
                    }.buttonStyle(PixelButtonStyle(prominent: true))
                        .disabled(!options.contains(where: { $0.value == draft }))
                }.padding(16).background(MotoTheme.background)
            }
            .presentationDragIndicator(.visible)
    }
}

