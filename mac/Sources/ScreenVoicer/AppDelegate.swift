import AppKit

/// Wiring of the app (App.xaml.cs on Windows). Filled in step by step.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("ScreenVoicer \(AppInfo.version) starting.")
    }
}
