import SwiftUI
import UIKit

@main
struct MotoLinkApp: App {
    @UIApplicationDelegateAdaptor(MotoLinkAppDelegate.self) private var delegate
    @AppStorage("MotoLink.appearance") private var appearance = "system"

    init() { MotoTheme.configureNavigationFonts() }

    var body: some Scene {
        WindowGroup {
            appContent
                .background {
                    #if targetEnvironment(simulator)
                    ProductVisualReadyProbe()
                    #endif
                }
                .preferredColorScheme(selectedScheme)
                .tint(MotoTheme.accent)
                .font(MotoTheme.font(.body))
                .onAppear {
                    #if targetEnvironment(simulator)
                    if ProcessInfo.processInfo.arguments.contains("--review-landscape") {
                        ProductVisualData.prepareLandscapeReview()
                    }
                    #endif
                }
        }
    }
    private var selectedScheme: ColorScheme? {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--review-light") { return .light }
        if ProcessInfo.processInfo.arguments.contains("--review-dark")
            || ProcessInfo.processInfo.arguments.contains("--review-ride")
            || ProcessInfo.processInfo.arguments.contains("--review-route-fullscreen")
            || ProcessInfo.processInfo.arguments.contains("--review-graphs")
            || ProcessInfo.processInfo.arguments.contains("--review-graphs-fullscreen") { return .dark }
        #endif
        return appearance == "light" ? .light : appearance == "dark" ? .dark : nil
    }
    @ViewBuilder private var appContent: some View {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--review-route-fullscreen") {
            RouteVisualCheckView(rides: delegate.controller.rides)
        } else if ProcessInfo.processInfo.arguments.contains("--review-scale-settings")
            || ProcessInfo.processInfo.arguments.contains("--review-scale-editor") {
            MetricScaleVisualCheckView(editor: ProcessInfo.processInfo.arguments.contains("--review-scale-editor"))
        } else if ProcessInfo.processInfo.arguments.contains("--review-graphs")
            || ProcessInfo.processInfo.arguments.contains("--review-graphs-fullscreen") {
            RideGraphVisualCheckView()
        } else if ProcessInfo.processInfo.arguments.contains("--companion-visual-check") {
            CompanionVisualCheckView(rides: delegate.controller.rides)
        } else {
            ContentView(bluetooth: delegate.controller.bluetooth, rides: delegate.controller.rides)
        }
        #else
        ContentView(bluetooth: delegate.controller.bluetooth, rides: delegate.controller.rides)
        #endif
    }
}

enum AppBuild {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    static let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
}


/// One readable rounded family across SwiftUI and UIKit; the motorcycle keeps
/// its pixel artwork independently of text and controls.
enum MotoTheme {
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.045, green: 0.047, blue: 0.055, alpha: 1)
        : UIColor(red: 0.95, green: 0.945, blue: 0.93, alpha: 1) })
    static let panel = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.10, green: 0.105, blue: 0.12, alpha: 1) : .white })
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0.34, blue: 0.38, alpha: 1)
        : UIColor(red: 0.70, green: 0.06, blue: 0.13, alpha: 1) })
    static let button = Color(red: 0.69, green: 0.06, blue: 0.12)
    static let secondary = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.70, green: 0.70, blue: 0.73, alpha: 1)
        : UIColor(red: 0.34, green: 0.34, blue: 0.37, alpha: 1) })
    static let border = Color.primary.opacity(0.18)
    static let live = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.32, green: 0.85, blue: 0.56, alpha: 1)
        : UIColor(red: 0.08, green: 0.43, blue: 0.25, alpha: 1) })
    static let waiting = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0.76, blue: 0.27, alpha: 1)
        : UIColor(red: 0.54, green: 0.33, blue: 0.02, alpha: 1) })
    static let recordButton = Color(red: 0.07, green: 0.40, blue: 0.23)
    static var backdrop: some View { MotoBackdrop() }
    static func font(_ style: Font.TextStyle) -> Font {
        .system(style, design: .rounded)
    }

    static func numberFont(size: CGFloat) -> Font {
        .system(size: UIFontMetrics(forTextStyle: .largeTitle).scaledValue(for: size),
                weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// SwiftUI's environment font does not reach UIKit navigation/tab labels.
    /// Match the same family there, with accessible text-size scaling.
    static func uiFont(size: CGFloat, style: UIFont.TextStyle) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: style == .headline || style == .largeTitle ? .semibold : .regular)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    static func configureNavigationFonts() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithDefaultBackground()
        navigation.titleTextAttributes = [.font: uiFont(size: 17, style: .headline)]
        navigation.largeTitleTextAttributes = [.font: uiFont(size: 34, style: .largeTitle)]
        for buttons in [navigation.buttonAppearance, navigation.doneButtonAppearance, navigation.backButtonAppearance] {
            for state in [buttons.normal, buttons.highlighted, buttons.disabled, buttons.focused] {
                state.titleTextAttributes = [.font: uiFont(size: 17, style: .body)]
            }
        }
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().compactScrollEdgeAppearance = navigation
        let tabs = UITabBarAppearance()
        tabs.configureWithDefaultBackground()
        for item in [tabs.stackedLayoutAppearance, tabs.inlineLayoutAppearance, tabs.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: uiFont(size: 11, style: .caption1)]
            item.selected.titleTextAttributes = [.font: uiFont(size: 11, style: .caption1)]
        }
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: uiFont(size: 17, style: .body)], for: .normal)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: uiFont(size: 17, style: .body)], for: .disabled)
    }
}

/// A quiet arcade texture drawn in two batches. No timer, random state, image
/// decoding, animation or sensor access: only the layout and appearance matter.
/// The opaque cards stay clean, and accessibility contrast settings remove the
/// decoration altogether rather than making it compete with the content.
struct MotoBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            MotoTheme.background
            if contrast != .increased && !reduceTransparency {
                Canvas { context, size in
                    guard size.width.isFinite, size.height.isFinite,
                          size.width > 0, size.height > 0 else { return }
                    let dark = scheme == .dark
                    let grid: CGFloat = 48
                    // Fixed screen-space spacing prevents the pattern sliding
                    // around when Dynamic Type makes a card or form taller.
                    let columns = min(30, Int(ceil(size.width / grid)))
                    let rows = min(48, Int(ceil(size.height / grid)))
                    var pixels = Path()
                    for row in 0...rows {
                        for column in 0...columns {
                            pixels.addRect(CGRect(x: 24 + CGFloat(column) * grid,
                                                  y: 24 + CGFloat(row) * grid,
                                                  width: 2, height: 2))
                        }
                    }
                    context.fill(pixels, with: .color(Color.primary.opacity(dark ? 0.055 : 0.035)))

                    // Pixel steps and a small checker motif recall the bike's
                    // artwork without introducing another illustration or grid
                    // that could be mistaken for a graph or route.
                    var accents = Path()
                    let upperX = floor(size.width * 0.65 / 8) * 8
                    let lowerY = floor(size.height * 0.72 / 8) * 8
                    for index in 0..<5 {
                        let offset = CGFloat(index) * 24
                        accents.addRect(CGRect(x: upperX + offset, y: 48 + offset, width: 24, height: 2))
                        accents.addRect(CGRect(x: upperX + offset + 22, y: 48 + offset, width: 2, height: 24))
                        accents.addRect(CGRect(x: -16 + offset, y: lowerY - offset, width: 24, height: 2))
                        accents.addRect(CGRect(x: 6 + offset, y: lowerY - offset - 24, width: 2, height: 24))
                    }
                    for row in 0..<3 {
                        for column in 0..<5 where (row + column).isMultiple(of: 2) {
                            accents.addRect(CGRect(x: size.width - 58 + CGFloat(column) * 8,
                                                   y: 16 + CGFloat(row) * 8,
                                                   width: 8, height: 8))
                        }
                    }
                    context.fill(accents, with: .color(MotoTheme.accent.opacity(dark ? 0.09 : 0.06)))
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Decorative brush strokes follow a real gauge level. No separate timer,
/// flashing, or text overlay is needed for the full-screen instrument.
struct RacingGaugeAccent: View {
    let color: Color
    let strength: Double
    var body: some View {
        Canvas { context, size in
            let level = strength.isFinite ? min(1, max(0, strength)) : 0
            guard level > 0 else { return }
            for index in 0..<3 {
                var stroke = Path()
                let x = size.width * (0.04 + Double(index) * 0.024)
                stroke.move(to: CGPoint(x: x, y: size.height * 0.72))
                stroke.addQuadCurve(to: CGPoint(x: x + size.width * 0.08, y: size.height * 0.36),
                                    control: CGPoint(x: x + size.width * 0.07, y: size.height * 0.65))
                context.stroke(stroke, with: .color(color.opacity(0.035 + 0.075 * level)),
                               style: StrokeStyle(lineWidth: index == 0 ? 3 : 1.5, lineCap: .round))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Form/List section headers have their own font environment.
struct PixelSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        Section { content.font(MotoTheme.font(.body)) } header: {
            Text(title).font(MotoTheme.font(.caption)).textCase(nil)
        }
    }
}

// Keep the existing name so maps and form controls share the same silhouette.
struct PixelFrame: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 16, style: .continuous).path(in: rect)
    }
}

extension View {
    func pixelPanel(_ fill: Color = MotoTheme.panel, accent: Bool = false) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent ? MotoTheme.accent.opacity(0.45) : MotoTheme.border.opacity(0.6), lineWidth: 1))
    }
}

/// Shared portrait dimensions keep the bike stable between Garage and Ride.
/// The landscape panel shrinks to its available column; no new artwork is loaded.
struct BikeArtworkFrame<Content: View>: View {
    var compact = false
    let content: Content
    init(compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }
    var body: some View {
        GeometryReader { geometry in
            let width = min(280, max(0, min(geometry.size.width, geometry.size.height * 2)))
            content.frame(width: width, height: width / 2)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.frame(height: compact ? 110 : 156)
    }
}

struct BikeArtworkView: View {
    var body: some View {
        BikeArtworkFrame {
            Image("BikeSpriteDetail").resizable().interpolation(.none).scaledToFit()
        }.accessibilityHidden(true)
    }
}

struct PixelButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MotoTheme.font(.headline))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? Color.white : (tint ?? MotoTheme.accent))
            .background(prominent ? (tint ?? MotoTheme.button) : MotoTheme.panel,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MotoTheme.border.opacity(0.6), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
