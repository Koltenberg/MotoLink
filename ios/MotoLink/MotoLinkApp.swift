import SwiftUI

@main
struct MotoLinkApp: App {
    @UIApplicationDelegateAdaptor(MotoLinkAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(bluetooth: delegate.controller.bluetooth, rides: delegate.controller.rides)
                .preferredColorScheme(.dark)
                .tint(MotoTheme.accent)
        }
    }
}

enum AppBuild {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    static let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
}


/// Pixel accents use geometry, not a tiny bitmap font. Body text keeps Dynamic Type.
enum MotoTheme {
    static let background = Color(red: 0.045, green: 0.047, blue: 0.055)
    static let panel = Color(red: 0.095, green: 0.098, blue: 0.11)
    static let accent = Color(red: 0.98, green: 0.29, blue: 0.33)
    static let button = Color(red: 0.76, green: 0.10, blue: 0.16)
}

struct PixelFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(4.0, min(rect.width, rect.height) / 6)
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
            .overlay(PixelFrame().stroke(accent ? MotoTheme.accent.opacity(0.32) : Color.white.opacity(0.10), lineWidth: 1))
    }
}

struct PixelButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .foregroundStyle(prominent ? Color.white : MotoTheme.accent)
            .background(prominent ? MotoTheme.button : MotoTheme.panel, in: PixelFrame())
            .overlay(PixelFrame().stroke(Color.white.opacity(configuration.isPressed ? 0.3 : 0.12), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}
