import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Created here so iOS can relaunch the app in the background and restore Bluetooth.
        Recorder.shared.didLaunch(background: application.applicationState == .background)
        UNUserNotificationCenter.current().delegate = self
        NotifyEngine.shared.requestPermissionIfNeeded()
        return true
    }

    /// Show Zdravlje's notifications even while it's open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct HeartLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { RootView().preferredColorScheme(.dark) }
    }
}
