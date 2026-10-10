import Foundation

/// Plain-text log in ~/Library/Logs/ScreenVoicer (Windows: %LOCALAPPDATA%\ScreenVoicer\logs).
enum Log {
    private static let queue = DispatchQueue(label: "ScreenVoicer.Log")
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Command-line modes (--selftest, --check-update) also print to stdout.
    static var echoToConsole = false

    static var directory: URL { Paths.logs }
    static var fileURL: URL { Paths.logs.appendingPathComponent("screenvoicer.log") }

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String, _ error: Error? = nil) { write("WARN", message, error) }
    static func error(_ message: String, _ error: Error? = nil) { write("ERROR", message, error) }

    private static func write(_ level: String, _ message: String, _ error: Error? = nil) {
        var line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        if let error {
            line += " — \(error.localizedDescription)"
        }
        if echoToConsole {
            print(line)
        }
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = fileURL
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64, size > maxBytes {
                    let old = directory.appendingPathComponent("screenvoicer.old.log")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: url, to: old)
                }
                let data = Data((line + "\n").utf8)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {
                // logging must never take the app down
            }
        }
    }
}
