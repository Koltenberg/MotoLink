import SwiftUI
import UIKit

@main
struct MotoLinkApp: App {
    @UIApplicationDelegateAdaptor(MotoLinkAppDelegate.self) private var delegate
    @AppStorage("MotoLink.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            appContent
                .preferredColorScheme(selectedScheme)
                .tint(MotoTheme.accent)
                .font(.system(.body))
                .onAppear {
                    #if targetEnvironment(simulator)
                    if ProcessInfo.processInfo.arguments.contains("--review-landscape") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                        }
                    }
                    #endif
                }
        }
    }
    private var selectedScheme: ColorScheme? {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--review-light") { return .light }
        if ProcessInfo.processInfo.arguments.contains("--review-ride") { return .dark }
        #endif
        return appearance == "light" ? .light : appearance == "dark" ? .dark : nil
    }
    @ViewBuilder private var appContent: some View {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--companion-visual-check") {
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
