import AppKit
import ScreenCaptureKit

/// A frozen screenshot of one display: native pixels plus where that display is (in points).
final class ScreenCapture {
    let image: CGImage
    let screen: NSScreen
    /// The display's frame in AppKit global coordinates (points).
    let frame: CGRect
    /// Pixels per point.
    let scale: CGFloat

    init(image: CGImage, screen: NSScreen) {
        self.image = image
        self.screen = screen
        self.frame = screen.frame
        self.scale = CGFloat(image.width) / max(screen.frame.width, 1)
    }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

enum ScreenCaptureService {
    struct CaptureError: LocalizedError {
        let message: String
        let needsPermission: Bool
        var errorDescription: String? { message }
    }

    /// The display under the mouse cursor (like Screen.FromPoint(Cursor.Position) on Windows).
    static func screenUnderCursor() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once; afterwards macOS only offers System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func captureScreenUnderCursor() async throws -> ScreenCapture {
        let screen = screenUnderCursor()
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError(message: "Не вдалося визначити екран.", needsPermission: false)
        }
        let displayID = CGDirectDisplayID(number.uint32Value)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.warn("[Capture] No access to the screen", error)
            throw CaptureError(message: "macOS не дозволяє ScreenVoicer бачити екран. Дозвольте запис екрана в Системних параметрах.",
                               needsPermission: true)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError(message: "Не вдалося знайти екран для знімка.", needsPermission: false)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int((screen.frame.width * scale).rounded())
        config.height = Int((screen.frame.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return ScreenCapture(image: image, screen: screen)
    }
}
