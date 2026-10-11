import AppKit
import SwiftUI

/// The 24-unit line icons of App.xaml (Icon.*), path data copied verbatim. Drawn with round caps and joins.
enum Icon: String, CaseIterable {
    case region, screen, pen, highlighter, arrow, rectangle, text, number, blur, eraser, undo, redo, mic, chevron, check
    case close, play, copy, folder, trash, search, camera, open, alert, spark, keyboard, timer, gallery, globe
    case chip, power, info, exit, chevronRight, gpu, link

    var data: String {
        switch self {
        case .region: return "M4 9V6.5A2.5 2.5 0 0 1 6.5 4H9M15 4H17.5A2.5 2.5 0 0 1 20 6.5V9M20 15V17.5A2.5 2.5 0 0 1 17.5 20H15M9 20H6.5A2.5 2.5 0 0 1 4 17.5V15"
        case .screen: return "M4.5 5H19.5A1.5 1.5 0 0 1 21 6.5V15.5A1.5 1.5 0 0 1 19.5 17H4.5A1.5 1.5 0 0 1 3 15.5V6.5A1.5 1.5 0 0 1 4.5 5ZM9 20.5H15M12 17V20.5"
        case .pen: return "M15 5.5L18.5 9L9 18.5L4.5 19.5L5.5 15ZM13 7.5L16.5 11"
        case .highlighter: return "M14.5 4.5L19.5 9.5L12.5 16.5L7.5 11.5ZM7.5 11.5L5.5 17L7 18.5L12.5 16.5M4 20.5H11"
        case .arrow: return "M5.5 18.5L18.5 5.5M10 5.5H18.5V14"
        case .rectangle: return "M6.5 5H17.5A2.5 2.5 0 0 1 20 7.5V16.5A2.5 2.5 0 0 1 17.5 19H6.5A2.5 2.5 0 0 1 4 16.5V7.5A2.5 2.5 0 0 1 6.5 5Z"
        case .text: return "M5 7.5V5H19V7.5M12 5V19M9 19H15"
        case .number: return "M12 3.5A8.5 8.5 0 1 1 11.99 3.5ZM10.5 9.5L12.5 8V16.5"
        case .blur: return "M6.5 4.5H17.5A2 2 0 0 1 19.5 6.5V17.5A2 2 0 0 1 17.5 19.5H6.5A2 2 0 0 1 4.5 17.5V6.5A2 2 0 0 1 6.5 4.5ZM4.5 9.5H19.5M4.5 14.5H19.5M9.5 4.5V19.5M14.5 4.5V19.5"
        case .eraser: return "M9 20H20M5.7 14.3L14.3 5.7A2 2 0 0 1 17.1 5.7L19.3 7.9A2 2 0 0 1 19.3 10.7L11 19H8.4ZM9.5 10.5L14.5 15.5"
        case .undo: return "M9 14L4.5 9.5L9 5M4.5 9.5H14A5.5 5.5 0 0 1 14 20.5H11"
        case .redo: return "M15 14L19.5 9.5L15 5M19.5 9.5H10A5.5 5.5 0 0 0 10 20.5H13"
        case .mic: return "M12 3.5A3 3 0 0 1 15 6.5V12A3 3 0 0 1 9 12V6.5A3 3 0 0 1 12 3.5ZM5.5 11.5A6.5 6.5 0 0 0 18.5 11.5M12 18V20.5"
        case .chevron: return "M6.5 9.5L12 15L17.5 9.5"
        case .check: return "M5 12.5L9.5 17L19 7.5"
        case .close: return "M6.5 6.5L17.5 17.5M17.5 6.5L6.5 17.5"
        case .play: return "M8 5.5V18.5L18.5 12Z"
        case .copy: return "M10 8.5H18A1.5 1.5 0 0 1 19.5 10V18A1.5 1.5 0 0 1 18 19.5H10A1.5 1.5 0 0 1 8.5 18V10A1.5 1.5 0 0 1 10 8.5ZM15.5 8.5V6A1.5 1.5 0 0 0 14 4.5H6A1.5 1.5 0 0 0 4.5 6V14A1.5 1.5 0 0 0 6 15.5H8.5"
        case .folder: return "M3.5 7A1.5 1.5 0 0 1 5 5.5H9L11 7.5H19A1.5 1.5 0 0 1 20.5 9V17.5A1.5 1.5 0 0 1 19 19H5A1.5 1.5 0 0 1 3.5 17.5Z"
        case .trash: return "M4.5 7H19.5M9.5 7V4.5H14.5V7M6.5 7L7.5 19.5H16.5L17.5 7M10 11V16M14 11V16"
        case .search: return "M11 4.5A6.5 6.5 0 1 1 10.99 4.5ZM16 16L20 20"
        case .camera: return "M5 7.5H7.5L9 5H15L16.5 7.5H19A1.5 1.5 0 0 1 20.5 9V17.5A1.5 1.5 0 0 1 19 19H5A1.5 1.5 0 0 1 3.5 17.5V9A1.5 1.5 0 0 1 5 7.5ZM12 9.5A3.5 3.5 0 1 1 11.99 9.5Z"
        case .open: return "M14 4.5H19.5V10M19.5 4.5L11 13M18 14V18A1.5 1.5 0 0 1 16.5 19.5H6.5A1.5 1.5 0 0 1 5 18V8A1.5 1.5 0 0 1 6.5 6.5H10.5"
        case .alert: return "M12 4L21 19.5H3ZM12 10V14M12 17V17.01"
        case .spark: return "M12 4V7M12 17V20M4 12H7M17 12H20M6.3 6.3L8.4 8.4M15.6 15.6L17.7 17.7M6.3 17.7L8.4 15.6M15.6 8.4L17.7 6.3"
        case .keyboard: return "M4.5 6.5H19.5A1.5 1.5 0 0 1 21 8V16A1.5 1.5 0 0 1 19.5 17.5H4.5A1.5 1.5 0 0 1 3 16V8A1.5 1.5 0 0 1 4.5 6.5ZM7 10H7.01M10.5 10H10.51M14 10H14.01M17 10H17.01M8 14H16"
        case .timer: return "M12 21A7.5 7.5 0 1 0 11.99 21ZM12 10V13.5L14.5 15M9.5 2.5H14.5M19 6.5L20.5 5"
        case .gallery: return "M5 4.5H10.5V10H5ZM13.5 4.5H19V10H13.5ZM5 13.5H10.5V19H5ZM13.5 13.5H19V19H13.5Z"
        case .globe: return "M12 3.5A8.5 8.5 0 1 1 11.99 3.5ZM3.5 12H20.5M12 3.5C14.5 6 15.5 9 15.5 12S14.5 18 12 20.5C9.5 18 8.5 15 8.5 12S9.5 6 12 3.5Z"
        case .chip: return "M8 6.5H16A1.5 1.5 0 0 1 17.5 8V16A1.5 1.5 0 0 1 16 17.5H8A1.5 1.5 0 0 1 6.5 16V8A1.5 1.5 0 0 1 8 6.5ZM10 3.5V6.5M14 3.5V6.5M10 17.5V20.5M14 17.5V20.5M3.5 10H6.5M3.5 14H6.5M17.5 10H20.5M17.5 14H20.5"
        case .power: return "M12 3.5V11.5M7 6.5A7 7 0 1 0 17 6.5"
        case .info: return "M12 3.5A8.5 8.5 0 1 1 11.99 3.5ZM12 11V16M12 8V8.01"
        case .exit: return "M14.5 4.5H18A1.5 1.5 0 0 1 19.5 6V18A1.5 1.5 0 0 1 18 19.5H14.5M10 8L6 12L10 16M6 12H15"
        case .chevronRight: return "M9.5 6.5L15 12L9.5 17.5"
        case .gpu: return "M3.5 7.5H20.5V16.5H3.5ZM7 16.5V19M17 16.5V19M8 12A2 2 0 1 0 7.99 12ZM13.5 10.5H17.5M13.5 13.5H17.5"
        case .link: return "M10 14A4 4 0 0 0 15.66 14L18.66 11A4 4 0 0 0 13 5.34L11.5 6.84M14 10A4 4 0 0 0 8.34 10L5.34 13A4 4 0 0 0 11 18.66L12.5 17.16"
        }
    }

    private static var cache: [Icon: CGPath] = [:]

    var path: CGPath {
        if let cached = Icon.cache[self] { return cached }
        let parsed = SVGPath.parse(data)
        Icon.cache[self] = parsed
        return parsed
    }
}

/// A shape defined on an n×n grid (24 for icons, 64 for the logo), scaled into the frame.
struct GridShape: Shape {
    let cgPath: CGPath
    var grid: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / grid
        var transform = CGAffineTransform(translationX: rect.minX + (rect.width - side) / 2, y: rect.minY + (rect.height - side) / 2)
            .scaledBy(x: scale, y: scale)
        return Path(cgPath.copy(using: &transform) ?? cgPath)
    }
}

/// GlyphIcon.cs: an icon stroked in the current foreground; `weight` is in grid units (1.9 ≈ 1.4 px at 18 px).
struct GlyphIcon: View {
    let icon: Icon
    var size: CGFloat = 18
    var weight: CGFloat = 1.9

    var body: some View {
        GridShape(cgPath: icon.path)
            .stroke(style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// Logo «F»: orange viewfinder corners around three voice bars, no tile, one solid colour (64-unit grid).
enum Brand {
    static let corners = "M6 22v-8a8 8 0 0 1 8-8h8M42 6h8a8 8 0 0 1 8 8v8M58 42v8a8 8 0 0 1-8 8h-8M22 58h-8a8 8 0 0 1-8-8v-8"
    static let bars = "M22 28v8M32 20v24M42 28v8"
    /// BrandMarkSmall: the same mark hinted for 16–24 px (menu bar): 8-unit strokes on the pixel grid.
    static let smallCorners = "M8,22V16A8,8 0 0 1 16,8H22M42,8H48A8,8 0 0 1 56,16V22M56,42V48A8,8 0 0 1 48,56H42M22,56H16A8,8 0 0 1 8,48V42"
    static let smallBars = "M20,28V36M32,18V46M44,28V36"
    static let accentRGB: UInt32 = 0xFF8A4C

    static let markPath: CGPath = {
        let path = CGMutablePath()
        path.addPath(SVGPath.parse(corners))
        path.addPath(SVGPath.parse(bars))
        return path
    }()

    static let smallMarkPath: CGPath = {
        let path = CGMutablePath()
        path.addPath(SVGPath.parse(smallCorners))
        path.addPath(SVGPath.parse(smallBars))
        return path
    }()

    /// Draws the mark into a y-up CGContext filling `rect`.
    static func draw(in ctx: CGContext, rect: CGRect, color: CGColor, small: Bool = false) {
        let side = min(rect.width, rect.height)
        let scale = side / 64
        ctx.saveGState()
        ctx.translateBy(x: rect.minX + (rect.width - side) / 2, y: rect.minY + (rect.height + side) / 2)
        ctx.scaleBy(x: scale, y: -scale) // SVG is y-down
        ctx.addPath(small ? smallMarkPath : markPath)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(small ? 8 : 7)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The menu bar icon: a template image, so macOS tints it for light and dark menu bars.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: rect.insetBy(dx: 0.5, dy: 0.5), color: NSColor.black.cgColor, small: true)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full-colour PNG of the mark at `pixels` × `pixels` (the app icon; padded like macOS icons).
    static func pngData(pixels: Int, padding: CGFloat = 0.1) -> Data? {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let inset = CGFloat(pixels) * padding
        draw(in: ctx, rect: CGRect(x: 0, y: 0, width: pixels, height: pixels).insetBy(dx: inset, dy: inset),
             color: NSColor(rgb: accentRGB).cgColor, small: pixels <= 32)
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// The logo as a SwiftUI view.
struct BrandMark: View {
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            GridShape(cgPath: Brand.markPath, grid: 64)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 7 * size / 64, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

enum IconRenderer {
    /// --render-icons <dir>: the .iconset that build.sh turns into AppIcon.icns.
    static func renderIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let data = Brand.pngData(pixels: points * scale) else { continue }
                try data.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
