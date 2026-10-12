import Foundation

enum CaptureMode: Int, Codable {
    case rectangleRegion = 0
    case fullScreen = 1
}

/// settings.json with the same keys as the Windows SettingsService.
final class Settings {
    static let defaultHotkey = "Alt+Shift+S" // ⌥⇧S, the same keys as Alt+Shift+S on Windows

    /// CoreAudio UID of the preferred microphone; empty = the system default device.
    var selectedMicrophone = ""
    var outputDirectory = Paths.defaultScreenshots.path
    var defaultCaptureMode: CaptureMode = .rectangleRegion
    /// Whisper language code ("uk", "en") or "auto".
    var language = "uk"
    /// Speech model id (see WhisperModels); nil = not chosen yet.
    var model: String?
    var useGpu = true
    var hotkey = Settings.defaultHotkey
    var modelHintShown = false
    var updateNotifiedVersion: String?
    /// The first-run permissions guide was completed (macOS only).
    var permissionsGuideShown = false
    /// Launch at login was switched on once at first start (the Windows installer ticks it by default).
    var autostartInitialized = false
    /// The version that ran last time: a newer one now means an update just finished.
    var lastRunVersion: String?

    private let url: URL
    private let lock = NSLock()

    init(directory: URL = Paths.appSupport) {
        Paths.ensure(directory)
        url = directory.appendingPathComponent("settings.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let s = try JSONDecoder().decode(SettingsData.self, from: data)
            selectedMicrophone = s.SelectedMicrophoneName ?? ""
            if let dir = s.OutputDirectory, !dir.trimmingCharacters(in: .whitespaces).isEmpty {
                outputDirectory = dir
            }
            if let mode = s.DefaultCaptureMode.flatMap(CaptureMode.init(rawValue:)) {
                defaultCaptureMode = mode
            }
            if let lang = s.Language, ["uk", "en", "auto"].contains(lang) {
                language = lang
            }
            model = (s.Model?.isEmpty ?? true) ? "base" : s.Model
            useGpu = s.UseGpu ?? true
            modelHintShown = s.ModelHintShown ?? false
            updateNotifiedVersion = s.UpdateNotifiedVersion
            permissionsGuideShown = s.PermissionsGuideShown ?? false
            autostartInitialized = s.AutostartInitialized ?? false
            lastRunVersion = s.LastRunVersion
            if let hk = s.Hotkey, HotkeyGesture.parse(hk) != nil {
                hotkey = hk
            }
        } catch {
            Log.warn("[Settings] Could not read settings, using defaults", error)
        }
    }

    func save() {
        lock.lock()
        defer { lock.unlock() }
        let data = SettingsData(
            SelectedMicrophoneName: selectedMicrophone,
            OutputDirectory: outputDirectory,
            DefaultCaptureMode: defaultCaptureMode.rawValue,
            Language: language,
            Model: model,
            UseGpu: useGpu,
            Hotkey: hotkey,
            ModelHintShown: modelHintShown,
            UpdateNotifiedVersion: updateNotifiedVersion,
            PermissionsGuideShown: permissionsGuideShown,
            AutostartInitialized: autostartInitialized,
            LastRunVersion: lastRunVersion)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // write-then-rename: a crash mid-write never leaves a truncated file
            try encoder.encode(data).write(to: url, options: .atomic)
        } catch {
            Log.warn("[Settings] Could not save settings", error)
        }
    }

    private struct SettingsData: Codable {
        var SelectedMicrophoneName: String?
        var OutputDirectory: String?
        var DefaultCaptureMode: Int?
        var Language: String?
        var Model: String?
        var UseGpu: Bool?
        var Hotkey: String?
        var ModelHintShown: Bool?
        var UpdateNotifiedVersion: String?
        var PermissionsGuideShown: Bool?
        var AutostartInitialized: Bool?
        var LastRunVersion: String?
    }
}
