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
        if ProcessInfo.processInfo.arguments.contains("--review-ride")
            || ProcessInfo.processInfo.arguments.contains("--review-graphs")
            || ProcessInfo.processInfo.arguments.contains("--review-graphs-fullscreen") { return .dark }
        #endif
        return appearance == "light" ? .light : appearance == "dark" ? .dark : nil
    }
    @ViewBuilder private var appContent: some View {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--review-graphs")
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


/// Bundled Cyrillic pixel type, with Dynamic Type and no network font dependency.
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
    static func font(_ style: Font.TextStyle) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 30
        case .title2: size = 26
        case .title3: size = 23
        case .headline: size = 20
        case .subheadline: size = 18
        case .caption, .caption2, .footnote: size = 15
        default: size = 18
        }
        return .custom("MotoLinkPixel-Regular", size: size, relativeTo: style)
    }

    static func numberFont(size: CGFloat) -> Font {
        .custom("MotoLinkPixel-Regular", size: size, relativeTo: .largeTitle)
    }

    /// SwiftUI's environment font does not reach UIKit navigation/tab labels.
    /// Keep the bundled family there too, with accessible text-size scaling.
    static func uiFont(size: CGFloat, style: UIFont.TextStyle) -> UIFont {
        guard let font = UIFont(name: "MotoLinkPixel-Regular", size: size) else {
            preconditionFailure("Bundled Moto Link Pixel font is missing")
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    static func configureNavigationFonts() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithDefaultBackground()
        navigation.titleTextAttributes = [.font: uiFont(size: 20, style: .headline)]
        navigation.largeTitleTextAttributes = [.font: uiFont(size: 34, style: .largeTitle)]
        for buttons in [navigation.buttonAppearance, navigation.doneButtonAppearance, navigation.backButtonAppearance] {
            for state in [buttons.normal, buttons.highlighted, buttons.disabled, buttons.focused] {
                state.titleTextAttributes = [.font: uiFont(size: 18, style: .body)]
            }
        }
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().compactScrollEdgeAppearance = navigation
        let tabs = UITabBarAppearance()
        tabs.configureWithDefaultBackground()
        for item in [tabs.stackedLayoutAppearance, tabs.inlineLayoutAppearance, tabs.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: uiFont(size: 14, style: .caption1)]
            item.selected.titleTextAttributes = [.font: uiFont(size: 14, style: .caption1)]
        }
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: uiFont(size: 18, style: .body)], for: .normal)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: uiFont(size: 18, style: .body)], for: .disabled)
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

struct PixelFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(5.0, min(rect.width, rect.height) / 6)
        let l = rect.minX, r = rect.maxX, t = rect.minY, b = rect.maxY
        let points: [CGPoint] = [
            .init(x: l + 2*s, y: t), .init(x: r - 2*s, y: t),
            .init(x: r - 2*s, y: t + s), .init(x: r - s, y: t + s),
            .init(x: r - s, y: t + 2*s), .init(x: r, y: t + 2*s),
            .init(x: r, y: b - 2*s), .init(x: r - s, y: b - 2*s),
            .init(x: r - s, y: b - s), .init(x: r - 2*s, y: b - s),
            .init(x: r - 2*s, y: b), .init(x: l + 2*s, y: b),
            .init(x: l + 2*s, y: b - s), .init(x: l + s, y: b - s),
            .init(x: l + s, y: b - 2*s), .init(x: l, y: b - 2*s),
            .init(x: l, y: t + 2*s), .init(x: l + s, y: t + 2*s),
            .init(x: l + s, y: t + s), .init(x: l + 2*s, y: t + s)
        ]
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

extension View {
    func pixelPanel(_ fill: Color = MotoTheme.panel, accent: Bool = false) -> some View {
        background(fill, in: PixelFrame())
            .overlay(PixelFrame().stroke(accent ? MotoTheme.accent.opacity(0.5) : MotoTheme.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    Rectangle().fill(MotoTheme.accent).frame(width: 12, height: 3)
                    Rectangle().fill(MotoTheme.accent.opacity(0.4)).frame(width: 4, height: 3)
                }.padding(.leading, 14).allowsHitTesting(false).accessibilityHidden(true)
            }
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
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MotoTheme.font(.headline))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? Color.white : MotoTheme.accent)
            .background(prominent ? MotoTheme.button : MotoTheme.panel, in: PixelFrame())
            .overlay(PixelFrame().stroke(MotoTheme.border, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}
