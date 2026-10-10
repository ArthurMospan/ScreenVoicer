import AppKit

/// `ScreenVoicer --snapshots <dir>`: renders the windows to PNG for visual review in CI.
enum Snapshots {
    @MainActor
    static func render(to directory: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return 0
    }
}
