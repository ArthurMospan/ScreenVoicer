import AppKit
import SwiftUI

/// A borderless panel over the whole display. Non-activating: it takes the keyboard without pulling the app to
/// the front, so the app the user was in stays active and gets focus back (and ⌘V) the moment we close.
final class OverlayPanel: NSPanel {
    weak var controller: OverlayController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // ⌘-shortcuts (⌘Z, ⇧⌘Z) arrive here before sendEvent sees them
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let controller, controller.handleKeyDown(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if let controller {
            if event.type == .keyDown, controller.handleKeyDown(event) { return }
            if event.type == .keyUp, controller.handleKeyUp(event) { return }
        }
        super.sendEvent(event)
    }

    /// Esc that nobody handled (e.g. inside a menu) must not beep.
    override func cancelOperation(_ sender: Any?) {}
}

/// The frozen screenshot, pixel for pixel.
final class ScreenshotView: NSView {
    init(image: CGImage, scale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.contentsScale = scale
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { nil }
}

/// Dims everything except the selected region.
final class DimView: NSView {
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = NSColor(white: 0, alpha: 0x8C / 255.0).cgColor
        shape.fillRule = .evenOdd
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(hole: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole, hole.width >= 1, hole.height >= 1 {
            path.addRect(hole)
        }
        shape.path = path
        CATransaction.commit()
    }
}

/// The selection frame (white line over a soft dark line) and the "W × H" badge.
final class FrameView: NSView {
    var selection: CGRect? { didSet { needsDisplay = true } }
    var sizeText = ""

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = selection, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0x66 / 255.0).cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(rect.insetBy(dx: -1, dy: -1))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.25)
        ctx.stroke(rect)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = sizeText as NSString
        let size = text.size(withAttributes: attributes)
        let badge = CGRect(x: rect.minX, y: rect.minY >= 30 ? rect.minY - 28 : rect.minY + 6,
                           width: size.width + 14, height: size.height + 6)
        let path = NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7)
        NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x1A / 255.0, alpha: 0xD9 / 255.0).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0x2E / 255.0).setStroke()
        path.lineWidth = 1
        path.stroke()
        text.draw(at: CGPoint(x: badge.minX + 7, y: badge.minY + 3), withAttributes: attributes)
    }
}

/// The annotation layer. All mouse input on the picture lands here and goes to the controller.
final class CanvasView: NSView {
    weak var controller: OverlayController?
    var clip: CGRect?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .cursorUpdate, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { cursor(for: event).set() }
    override func mouseMoved(with event: NSEvent) { cursor(for: event).set() }

    private func cursor(for event: NSEvent) -> NSCursor {
        controller?.cursor(at: convert(event.locationInWindow, from: nil)) ?? .crosshair
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        if let clip { ctx.clip(to: clip) }
        AnnotationRenderer.draw(controller.items, in: ctx)
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(to: convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.mouseUp(at: convert(event.locationInWindow, from: nil))
    }
}

/// Hosts the SwiftUI chrome over the whole display; only the toolbar and an open flyout take clicks.
final class ChromeHostingView: NSHostingView<OverlayChrome> {
    weak var model: OverlayModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model, !model.panelsFaded else { return nil }
        let local = convert(point, from: superview)
        let p = isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
        guard model.hitRects.contains(where: { $0.contains(p) }) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A text label being typed: transparent field over the tag the canvas draws.
final class LabelField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = textColor ?? .white
            editor.drawsBackground = false
        }
        return ok
    }
}
