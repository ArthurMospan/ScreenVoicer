import AVFoundation
import AppKit

/// «Запуск з macOS»: a per-user LaunchAgent that starts the app with --autostart (it then stays in the menu bar
/// quietly, like the Windows Run-key entry with the same argument).
enum LoginItem {
    static let autostartArgument = "--autostart"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(AppInfo.bundleIdentifier).plist")
    }

    static func isEnabled() -> Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try write()
            } else if isEnabled() {
                try FileManager.default.removeItem(at: plistURL)
            }
            return true
        } catch {
            Log.warn("[Autostart] Could not change the login item", error)
            return false
        }
    }

    /// The app may have moved (or been updated in place): keep the entry pointing at this copy.
    static func refreshIfEnabled() {
        guard isEnabled(), let executable = Bundle.main.executablePath else { return }
        let current = (NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String])?.first
        if current != executable {
            try? write()
        }
    }

    private static func write() throws {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": AppInfo.bundleIdentifier,
            "ProgramArguments": [executable, autostartArgument],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive"
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }
}

/// Screen Recording and Microphone permissions (macOS only: Windows needs neither).
enum Permissions {
    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var microphoneUndecided: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }
    static var screenGranted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }
}
