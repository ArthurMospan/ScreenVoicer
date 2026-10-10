import Foundation

/// Where things live. SV_DATA_DIR moves settings, history, models and logs elsewhere (self-tests).
enum Paths {
    private static let fm = FileManager.default

    private static var overrideRoot: URL? {
        guard let custom = ProcessInfo.processInfo.environment["SV_DATA_DIR"], !custom.isEmpty else { return nil }
        return URL(fileURLWithPath: custom, isDirectory: true)
    }

    /// settings.json, history.json (Windows: %APPDATA%\ScreenVoicer).
    static var appSupport: URL {
        if let root = overrideRoot { return root }
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenVoicer", isDirectory: true)
    }

    static var models: URL { appSupport.appendingPathComponent("models", isDirectory: true) }

    static var logs: URL {
        if let root = overrideRoot { return root.appendingPathComponent("logs", isDirectory: true) }
        return fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/ScreenVoicer", isDirectory: true)
    }

    static var updates: URL {
        if let root = overrideRoot { return root.appendingPathComponent("updates", isDirectory: true) }
        return fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ScreenVoicer/updates", isDirectory: true)
    }

    /// ~/AI_Screenshots, the twin of C:\AI_Screenshots (outside the folders macOS asks permission for).
    static var defaultScreenshots: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("AI_Screenshots", isDirectory: true)
    }

    /// The last voice take, for «Прослухати останній запис».
    static var lastRecording: URL { logs.appendingPathComponent("last-recording.wav") }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "/Users/me/AI_Screenshots" → "~/AI_Screenshots" for display.
    static func pretty(_ path: String) -> String {
        let home = fm.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
