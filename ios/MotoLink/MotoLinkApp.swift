import SwiftUI

@main
struct MotoLinkApp: App {
    @UIApplicationDelegateAdaptor(MotoLinkAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(bluetooth: delegate.controller.bluetooth, rides: delegate.controller.rides)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.56, green: 0.93, blue: 0.37))
        }
    }
}
