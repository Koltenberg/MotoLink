import SwiftUI

@main
struct MotoLinkApp: App {
    @UIApplicationDelegateAdaptor(MotoLinkAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(bluetooth: delegate.controller.bluetooth, rides: delegate.controller.rides)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.94, green: 0.20, blue: 0.25))
        }
    }
}

enum AppBuild {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    static let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
}
