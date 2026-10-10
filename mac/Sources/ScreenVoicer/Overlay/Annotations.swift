import AppKit
import UniformTypeIdentifiers

enum Tool: String, CaseIterable {
    case pen, highlighter, arrow, rectangle, text, marker, eraser

    var icon: Icon {
        switch self {
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .text: return .text
        case .marker: return .number
        case .eraser: return .eraser
        }
    }

    var tooltip: String {
        switch self {
        case .pen: return "Олівець (P)"
        case .highlighter: return "Маркер (H)"
        case .arrow: return "Стрілка (A), Shift — під кутом 45°"
        case .rectangle: return "Рамка (R), Shift — квадрат"
        case .text: return "Текст (T): клацніть, напишіть, Enter. Подвійний клік — редагувати, перетягування — перемістити"
        case .marker: return "Нумерована мітка (N): 1, 2, 3…"
        case .eraser: return "Гумка (E)"
        }
    }
}

/// Sizes per thickness step (тонка / середня / товста), as in OverlayWindow.xaml.cs.
enum Thickness {
    static let pen: [CGFloat] = [2.5, 4, 7]
    static let highlighter: [CGFloat] = [14, 22, 34]
    static let labelFont: [CGFloat] = [15, 20, 28]
    static let marker: [CGFloat] = [24, 30, 40]
    static let dot: [CGFloat] = [5, 8, 12]
    static let names = ["тонка", "середня", "товста"]
}

/// Everything drawn on top of the screenshot. Coordinates are points, y-down, relative to the overlay.
class AnnotationItem {
    func draw(in ctx: CGContext) {}
    func hitTest(_ p: CGPoint) -> Bool { false }
    var bounds: CGRect { .zero }
    /// Labels and markers can be moved; strokes can't.
    var isMovable: Bool { false }
    var origin: CGPoint {
        get { .zero }
        set {}
    }
}

enum Ink {
    static func contrast(for color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.6 ? NSColor(rgb: 0x18181B) : .white
    }

    static func darker(_ color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        return NSColor(srgbRed: c.redComponent * 0.78, green: c.greenComponent * 0.78, blue: c.blueComponent * 0.78, alpha: 1)
    }

    static func isDark(_ color: NSColor) -> Bool {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (c.redComponent + c.greenComponent + c.blueComponent) * 255 < 150
    }
}

final class StrokeAnnotation: AnnotationItem {
    enum Style {
        case pen          // smoothed freehand
        case highlighter  // translucent chisel tip
        case shape        // straight segments (arrow, rectangle)
    }

    var points: [CGPoint]
    let color: NSColor
    let width: CGFloat
    let style: Style

    init(points: [CGPoint], color: NSColor, width: CGFloat, style: Style) {
        self.points = points
        self.color = color
        self.width = width
        self.style = style
    }

    override var bounds: CGRect {
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for p in points { rect = rect.union(CGRect(origin: p, size: .zero)) }
        return rect.insetBy(dx: -width, dy: -width)
    }

    override func hitTest(_ p: CGPoint) -> Bool {
        let tolerance = width / 2 + 4
        if points.count == 1 { return hypot(points[0].x - p.x, points[0].y - p.y) <= tolerance }
        for i in 1..<points.count where Self.distance(p, points[i - 1], points[i]) <= tolerance {
            return true
        }
        return false
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    override func draw(in ctx: CGContext) {
        guard !points.isEmpty else { return }
        switch style {
        case .highlighter:
            drawChisel(in: ctx)
        case .pen, .shape:
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(style == .pen ? Self.smoothPath(points) : Self.polyline(points))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// WPF's highlighter: a 0.4 × 1 rectangle tip, half transparent, overlaps within a stroke don't darken.
    private func drawChisel(in ctx: CGContext) {
        let hw = width * 0.2, hh = width * 0.5
        let path = CGMutablePath()
        func rect(_ p: CGPoint) -> [CGPoint] {
            [CGPoint(x: p.x - hw, y: p.y - hh), CGPoint(x: p.x + hw, y: p.y - hh),
             CGPoint(x: p.x + hw, y: p.y + hh), CGPoint(x: p.x - hw, y: p.y + hh)]
        }
        if points.count == 1 {
            path.addLines(between: rect(points[0]))
            path.closeSubpath()
        }
        for i in 1..<max(points.count, 1) {
            let hull = Self.convexHull(rect(points[i - 1]) + rect(points[i]))
            path.addLines(between: hull)
            path.closeSubpath()
        }
        ctx.saveGState()
        ctx.setAlpha(0.5)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path)
        ctx.fillPath(using: .winding)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func polyline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        if points.count == 1 { path.addLine(to: points[0]) }
        return path
    }

    /// FitToCurve: quadratic curves through the midpoints of the raw samples.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            for p in points.dropFirst() { path.addLine(to: p) }
            if points.count == 1 { path.addLine(to: first) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func convexHull(_ input: [CGPoint]) -> [CGPoint] {
        let pts = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

/// A coloured rounded tag with contrasting text: readable on any screenshot.
final class LabelAnnotation: AnnotationItem {
    var position: CGPoint
    var text: String
    var color: NSColor
    var fontSize: CGFloat
    /// While typing, the canvas draws the tag behind the text field (and no text of its own).
    var isEditing = false
    /// Width of the text being typed, set by the canvas while editing.
    var editingTextSize: CGSize?

    init(position: CGPoint, text: String, color: NSColor, fontSize: CGFloat) {
        self.position = position
        self.text = text
        self.color = color
        self.fontSize = fontSize
    }

    var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: .semibold) }
    var padding: NSEdgeInsets { NSEdgeInsets(top: fontSize * 0.15, left: fontSize * 0.45, bottom: fontSize * 0.2, right: fontSize * 0.45) }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: Ink.contrast(for: color)]
    }

    var textSize: CGSize {
        if let editingTextSize { return editingTextSize }
        let measured = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin], attributes: attributes).size
        return CGSize(width: max(ceil(measured.width), fontSize * 1.2), height: ceil(measured.height))
    }

    override var bounds: CGRect {
        let size = textSize
        let pad = padding
        return CGRect(x: position.x, y: position.y, width: size.width + pad.left + pad.right, height: size.height + pad.top + pad.bottom)
    }

    override var isMovable: Bool { true }
    override var origin: CGPoint {
        get { position }
        set { position = newValue }
    }

    override func hitTest(_ p: CGPoint) -> Bool { bounds.insetBy(dx: -2, dy: -2).contains(p) }

    override func draw(in ctx: CGContext) {
        let rect = bounds
        let radius = fontSize * 0.35
        let shape = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.setStrokeColor(Ink.darker(color).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(shape)
        ctx.strokePath()
        ctx.restoreGState()

        if !isEditing {
            let pad = padding
            (text as NSString).draw(with: CGRect(x: rect.minX + pad.left, y: rect.minY + pad.top,
                                                 width: rect.width - pad.left - pad.right + 2, height: rect.height),
                                    options: [.usesLineFragmentOrigin], attributes: attributes)
        }
    }
}

/// A numbered disc: 1, 2, 3…
final class MarkerAnnotation: AnnotationItem {
    var position: CGPoint // top-left
    let number: Int
    let color: NSColor
    let size: CGFloat

    init(center: CGPoint, number: Int, color: NSColor, size: CGFloat) {
        self.position = CGPoint(x: center.x - size / 2, y: center.y - size / 2)
        self.number = number
        self.color = color
        self.size = size
    }

    override var bounds: CGRect { CGRect(x: position.x, y: position.y, width: size, height: size) }
    override var isMovable: Bool { true }
    override var origin: CGPoint {
        get { position }
        set { position = newValue }
    }

    override func hitTest(_ p: CGPoint) -> Bool {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        return hypot(p.x - c.x, p.y - c.y) <= size / 2 + 2
    }

    override func draw(in ctx: CGContext) {
        let stroke = max(2, size / 13)
        let disc = bounds.insetBy(dx: stroke / 2, dy: stroke / 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 6, color: NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(stroke)
        ctx.strokeEllipse(in: disc)
        ctx.restoreGState()

        let font = NSFont.systemFont(ofSize: size * (number > 9 ? 0.42 : 0.52), weight: .bold)
        let label = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Ink.contrast(for: color)]
        let textSize = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2 - size * 0.02),
                   withAttributes: attributes)
    }
}

/// Draws a list of annotations in z-order: highlighters under ink (as WPF's InkCanvas does), tags and markers on top.
enum AnnotationRenderer {
    static func draw(_ items: [AnnotationItem], in ctx: CGContext) {
        for item in items {
            if let stroke = item as? StrokeAnnotation, stroke.style == .highlighter { stroke.draw(in: ctx) }
        }
        for item in items {
            if let stroke = item as? StrokeAnnotation, stroke.style != .highlighter { stroke.draw(in: ctx) }
        }
        for item in items where !(item is StrokeAnnotation) {
            item.draw(in: ctx)
        }
    }
}

struct SavedScreenshot {
    let path: String
    let width: Int
    let height: Int
    let fileSizeBytes: Int64
}

/// ImageCompositorService.cs: burns the annotations into the screenshot at native resolution, crops, saves a PNG.
enum ImageCompositor {
    /// - Parameters:
    ///   - cropPx: region to keep in pixels (top-left origin), nil for the whole display.
    ///   - scale: pixels per point of the overlay.
    static func render(capture: CGImage, cropPx: CGRect?, scale: CGFloat, items: [AnnotationItem]) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: capture.width, height: capture.height)
        var crop = (cropPx ?? full).integral.intersection(full)
        if crop.width < 2 || crop.height < 2 { crop = full }
        let width = Int(crop.width), height = Int(crop.height)

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        if let part = capture.cropping(to: crop) {
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if !items.isEmpty {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -crop.minX / scale, y: -crop.minY / scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            AnnotationRenderer.draw(items, in: ctx)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Encodes and writes the PNG (call off the main thread). Falls back to ~/Pictures/AI_Screenshots.
    static func save(_ image: CGImage, settings: Settings) throws -> SavedScreenshot {
        let directory = outputDirectory(settings)
        let url = directory.appendingPathComponent("screenshot_\(Formats.fileStamp.string(from: Date())).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        Log.info("[Compositor] Saved \(image.width)x\(image.height) (\(size / 1024) KB) to \(url.path)")
        return SavedScreenshot(path: url.path, width: image.width, height: image.height, fileSizeBytes: size)
    }

    private static func outputDirectory(_ settings: Settings) -> URL {
        let configured = URL(fileURLWithPath: settings.outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
            if FileManager.default.isWritableFile(atPath: configured.path) { return configured }
        } catch {
            Log.warn("[Compositor] Cannot use '\(configured.path)'", error)
        }
        let fallback = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI_Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        settings.outputDirectory = fallback.path
        settings.save()
        return fallback
    }
}

/// Used by --selftest: renders a synthetic capture with every kind of annotation and checks the pixels.
enum CompositorSelfTest {
    static func run(outputDirectory: URL) -> (ok: Bool, detail: String) {
        let scale: CGFloat = 2
        guard let bg = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return (false, "no context") }
        bg.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
        bg.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        guard let capture = bg.makeImage() else { return (false, "no capture") }

        let red = NSColor(rgb: 0xEF4444)
        let items: [AnnotationItem] = [
            StrokeAnnotation(points: [CGPoint(x: 20, y: 40), CGPoint(x: 60, y: 40), CGPoint(x: 100, y: 40)], color: red, width: 7, style: .pen),
            StrokeAnnotation(points: [CGPoint(x: 30, y: 60), CGPoint(x: 90, y: 60)], color: NSColor(rgb: 0xFACC15), width: 22, style: .highlighter),
            LabelAnnotation(position: CGPoint(x: 110, y: 30), text: "Тест", color: NSColor(rgb: 0x3B82F6), fontSize: 15),
            MarkerAnnotation(center: CGPoint(x: 150, y: 90), number: 1, color: red, size: 30)
        ]
        let crop = CGRect(x: 20, y: 20, width: 300, height: 200) // pixels
        guard let image = ImageCompositor.render(capture: capture, cropPx: crop, scale: scale, items: items) else {
            return (false, "render failed")
        }
        guard image.width == 300, image.height == 200 else { return (false, "size \(image.width)x\(image.height)") }

        // pixel of the pen stroke: point (60, 40) → pixel (120, 80) → in crop (100, 60)
        guard let rgba = pixel(image, x: 100, y: 60) else { return (false, "no pixel") }
        guard rgba.r > 200 && rgba.g < 120 else { return (false, "stroke pixel \(rgba)") }
        guard let grey = pixel(image, x: 280, y: 190), abs(Int(grey.r) - 128) < 6 else { return (false, "background pixel") }

        do {
            let settings = Settings(directory: outputDirectory)
            settings.outputDirectory = outputDirectory.path
            let saved = try ImageCompositor.save(image, settings: settings)
            guard saved.width == 300, FileManager.default.fileExists(atPath: saved.path), saved.fileSizeBytes > 0 else {
                return (false, "saved \(saved)")
            }
            return (true, "\(saved.width)x\(saved.height), \(saved.fileSizeBytes) bytes")
        } catch {
            return (false, "save: \(error)")
        }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var data = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // draw so that image pixel (x, y) (top-left origin) lands on the single context pixel
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        return drawn ? (data[0], data[1], data[2]) : nil
    }
}
