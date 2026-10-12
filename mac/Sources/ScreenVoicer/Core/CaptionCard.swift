import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The screenshot with its comment written under it on a dark band: the link preview (ShareService) and the
/// «З підписом» copy from the saved-screenshot toast. Same layout as the Windows CaptionCard. At 1200 px wide the band
/// has 40/44 px padding, a 6 px orange bar at x 56 and the text at x 86 (40 px semibold, 52 px lines), plus an optional
/// muted footer line (28 px); every size scales with the card width.
enum CaptionCard {
    private static let baseWidth: CGFloat = 1200
    static let minWidth = 640

    /// - Parameters:
    ///   - width: card width in pixels; nil keeps the screenshot at its own size (the card is at least `minWidth` wide).
    ///   - maxPictureHeight: the screenshot is scaled down (never up) to fit width × this.
    static func render(path: String, caption: String, width: Int? = nil, maxPictureHeight: Int = .max,
                       maxLines: Int = 12, footer: String? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = props[kCGImagePropertyPixelWidth] as? Int, let pixelHeight = props[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let w = width ?? max(minWidth, pixelWidth)
        let scale = min(1, CGFloat(w) / CGFloat(pixelWidth), CGFloat(maxPictureHeight) / CGFloat(pixelHeight))
        let pw = (CGFloat(pixelWidth) * scale).rounded(), ph = (CGFloat(pixelHeight) * scale).rounded()
        let picture: CGImage?
        if scale < 1 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(pw, ph)),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            picture = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let picture else { return nil }
        let k = min(2.4, max(0.55, CGFloat(w) / baseWidth))

        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let textWidth = CGFloat(w) - (86 + 56) * k
        let lineHeight = 52 * k
        var text: NSAttributedString?, more: NSAttributedString?
        var textHeight: CGFloat = 0, band: CGFloat = 0
        if !caption.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            paragraph.lineBreakMode = .byWordWrapping
            let attributed = NSAttributedString(string: caption, attributes: [
                .font: NSFont.systemFont(ofSize: 40 * k, weight: .semibold),
                .foregroundColor: NSColor(rgb: 0xF4F4F7),
                .paragraphStyle: paragraph
            ])
            let full = attributed.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin]).height
            textHeight = CGFloat(max(1, min(maxLines, Int((full / lineHeight - 0.05).rounded(.up))))) * lineHeight
            text = attributed
            band = (40 + 44) * k + textHeight
            if let footer, !footer.isEmpty {
                more = NSAttributedString(string: footer, attributes: [
                    .font: NSFont.systemFont(ofSize: 28 * k, weight: .regular),
                    .foregroundColor: NSColor(rgb: 0xAAAAB6)
                ])
                band += (14 + 36) * k
            }
        }

        let canvasHeight = Int((ph + band).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // top-left origin, like the Windows drawing code
        ctx.translateBy(x: 0, y: CGFloat(canvasHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(NSColor(rgb: 0x0F0F13).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(canvasHeight)))
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.translateBy(x: 0, y: ph) // CGContext.draw expects y up: flip back for the picture
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(picture, in: CGRect(x: (CGFloat(w) - pw) / 2, y: 0, width: pw, height: ph))
        ctx.restoreGState()
        if let text {
            let top = ph + 40 * k
            ctx.setFillColor(NSColor(rgb: 0xFF8A4C).cgColor)
            ctx.fill(CGRect(x: 56 * k, y: top + 6 * k, width: 6 * k, height: max(20 * k, textHeight - 12 * k)))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            text.draw(with: CGRect(x: 86 * k, y: top, width: textWidth, height: textHeight + 4),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            more?.draw(at: CGPoint(x: 86 * k, y: top + textHeight + 14 * k))
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()
    }

    /// «З підписом»: the card at the screenshot's own size as a PNG in the temp folder, for the clipboard.
    /// The screenshot itself stays clean. Returns nil if it could not be made.
    static func saveForClipboard(path: String, caption: String) -> String? {
        guard let card = render(path: path, caption: caption) else {
            Log.warn("[Caption] Could not make the captioned copy")
            return nil
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenVoicer", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + "-caption.png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, card, nil)
        guard CGImageDestinationFinalize(destination) else {
            Log.warn("[Caption] Could not write the captioned copy")
            return nil
        }
        return file.path
    }
}
