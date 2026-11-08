import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Created here so iOS can relaunch the app in the background and restore Bluetooth.
        Recorder.shared.didLaunch(background: application.applicationState == .background)
        return true
    }
}

@main
struct HeartLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}
