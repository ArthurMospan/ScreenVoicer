import AppKit

/// Mirrors the Windows ClipboardService: the Markdown text plus the PNG (as a file and as image data).
enum Clipboard {
    static func formatMarkdown(imagePath: String, comment: String) -> String {
        let clean = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(imagePath)]\n**Comment:** \(clean.isEmpty ? "*(No voice comment recorded)*" : clean)"
    }

    /// Puts the text (and, if given, the image file + PNG data) on the clipboard. Returns false on failure.
    @discardableResult
    static func copy(_ text: String, imagePath: String? = nil) -> Bool {
        write(text, imagePath: imagePath)
    }

    /// Only the image (file + PNG data), no text: whatever the user pastes into, the picture arrives.
    @discardableResult
    static func copyImage(path: String) -> Bool {
        write(nil, imagePath: path)
    }

    private static func write(_ text: String?, imagePath: String?) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        if let text {
            item.setString(text, forType: .string)
        }
        if let imagePath, FileManager.default.fileExists(atPath: imagePath) {
            // Finder, Slack, Telegram, Mail attach the file; browsers and editors paste the PNG data.
            item.setString(URL(fileURLWithPath: imagePath).absoluteString, forType: .fileURL)
            if let png = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
                item.setData(png, forType: .png)
            } else {
                Log.warn("[Clipboard] Could not attach the image")
            }
        }

        let ok = pasteboard.writeObjects([item])
        if !ok {
            Log.warn("[Clipboard] Copy failed.")
        }
        return ok
    }
}
