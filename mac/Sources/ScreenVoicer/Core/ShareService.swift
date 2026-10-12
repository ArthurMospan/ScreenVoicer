import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ShareResult {
    let id: String
    let url: String
    let deleteToken: String
    let expiresAt: Date
}

/// Public links through the ScreenVoicer Cloudflare Worker (share-worker/), same API as the Windows ShareService:
/// one or several screenshots with their comments behind one link that expires by itself after 30 days.
enum ShareService {
    private static let defaultEndpoint = "https://screenvoicer.masspain.workers.dev"
    static let maxImages = 10
    private static let maxImageBytes: Int64 = 8 * 1024 * 1024
    private static let previewWidth = 1200
    private static let previewPictureHeight = 800
    private static let cardPad = 56
    private static let cardTextX = 86
    private static let previewQuality = 0.82
    private static let maxPreviewBytes = 1024 * 1024

    static var endpoint: String {
        let custom = ProcessInfo.processInfo.environment["SV_SHARE_ENDPOINT"] ?? ""
        let value = custom.isEmpty ? defaultEndpoint : custom
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    struct ShareError: LocalizedError {
        let message: String
        let isNetwork: Bool
        var errorDescription: String? { message }
    }

    static func create(_ items: [ScreenshotHistoryItem]) async throws -> ShareResult {
        guard !items.isEmpty else { throw ShareError(message: "Nothing to share.", isNetwork: false) }
        guard items.count <= maxImages else {
            throw ShareError(message: "За одним посиланням можна поділитися щонайбільше \(maxImages) знімками.", isNetwork: false)
        }

        let boundary = "ScreenVoicer-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        // the link preview: the first screenshot with its comment written under it (see makePreview)
        let caption = items[0].transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = makePreview(path: items[0].imagePath, caption: caption, moreShots: items.count - 1)

        let meta: [String: Any] = [
            "app": "ScreenVoicer \(AppInfo.version)",
            "previewCaption": preview != nil && !caption.isEmpty,
            "items": items.map { item in
                [
                    "comment": item.transcribedText,
                    "width": item.width,
                    "height": item.height,
                    "createdAt": ISO8601DateFormatter().string(from: item.createdAt)
                ] as [String: Any]
            }
        ]
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"meta\"\r\nContent-Type: application/json; charset=utf-8\r\n\r\n")
        body.append(try JSONSerialization.data(withJSONObject: meta))
        append("\r\n")

        for item in items {
            let url = URL(fileURLWithPath: item.imagePath)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: item.imagePath),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else {
                throw ShareError(message: "Файл знімка не знайдено — можливо, його видалили.", isNetwork: false)
            }
            if size > maxImageBytes {
                let mb = String(format: "%.1f", Double(size) / 1_048_576).replacingOccurrences(of: ".", with: ",")
                throw ShareError(message: "Знімок «\(item.fileName)» завеликий для посилання (\(mb) МБ, максимум 8 МБ).", isNetwork: false)
            }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(item.fileName)\"\r\nContent-Type: image/png\r\n\r\n")
            body.append(try Data(contentsOf: url))
            append("\r\n")
        }
        if let preview {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"preview\"; filename=\"preview.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            body.append(preview)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "\(endpoint)/api/shares")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("ScreenVoicer/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch {
            throw ShareError(message: "Немає зв'язку із сервером посилань. Перевірте інтернет. (\(error.localizedDescription))", isNetwork: true)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            throw ShareError(message: "Сервер посилань відповів \(status): \(describe(text))", isNetwork: false)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, let link = json["url"] as? String,
              let token = json["deleteToken"] as? String, let expires = json["expiresAt"] as? String else {
            throw ShareError(message: "Сервер посилань повернув незрозумілу відповідь.", isNetwork: false)
        }
        let result = ShareResult(id: id, url: link, deleteToken: token, expiresAt: parseDate(expires) ?? Date().addingTimeInterval(30 * 86400))
        Log.info("[Share] \(items.count) screenshot(s) → \(result.url).")
        return result
    }

    static func delete(id: String, deleteToken: String) async throws {
        var request = URLRequest(url: URL(string: "\(endpoint)/api/shares/\(id)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(deleteToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ScreenVoicer/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ShareError(message: "Не вдалося видалити посилання (\(status): \(describe(String(decoding: data, as: UTF8.self)))).", isNetwork: false)
        }
        Log.info("[Share] \(id) deleted.")
    }

    /// The picture messengers show for a link (a small JPEG: WhatsApp and others skip big images). Messengers always
    /// put their text above the picture, so the comment is written into the picture itself, under the screenshot:
    /// screenshot first, comment below, nothing repeated. Card layout, the same as the Windows app: 1200 px wide; the
    /// screenshot fitted into 1200 × 800 on #0F0F13; under it, when there is a comment, a band with 40/44 px padding,
    /// a 6 px orange bar at x 56 and the text at x 86 (40 px semibold, 52 px lines, at most three, then «…»), plus
    /// «Ще N знімки за посиланням» (28 px) when the link holds more screenshots.
    static func makePreview(path: String, caption: String = "", moreShots: Int = 0) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let scale = min(1, CGFloat(previewWidth) / CGFloat(width), CGFloat(previewPictureHeight) / CGFloat(height))
        let pw = (CGFloat(width) * scale).rounded(), ph = (CGFloat(height) * scale).rounded()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(pw, ph)),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let textWidth = CGFloat(previewWidth - cardTextX - cardPad)
        var text: NSAttributedString?, more: NSAttributedString?
        var textHeight: CGFloat = 0, band: CGFloat = 0
        if !caption.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 52
            paragraph.maximumLineHeight = 52
            paragraph.lineBreakMode = .byWordWrapping
            let attributed = NSAttributedString(string: caption, attributes: [
                .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
                .foregroundColor: NSColor(rgb: 0xF4F4F7),
                .paragraphStyle: paragraph
            ])
            let full = attributed.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin]).height
            textHeight = CGFloat(max(1, min(3, Int((full / 52 - 0.05).rounded(.up))))) * 52
            text = attributed
            band = 40 + textHeight + 44
            if moreShots > 0 {
                more = NSAttributedString(string: "Ще \(Formats.plural(moreShots, "знімок", "знімки", "знімків")) за посиланням", attributes: [
                    .font: NSFont.systemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: NSColor(rgb: 0xAAAAB6)
                ])
                band += 14 + 36
            }
        }

        let canvasHeight = Int((ph + band).rounded(.up))
        guard let ctx = CGContext(data: nil, width: previewWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // top-left origin, like the Windows drawing code
        ctx.translateBy(x: 0, y: CGFloat(canvasHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(NSColor(rgb: 0x0F0F13).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(previewWidth), height: CGFloat(canvasHeight)))
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.translateBy(x: 0, y: ph) // CGContext.draw expects y up: flip back for the picture
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(picture, in: CGRect(x: (CGFloat(previewWidth) - pw) / 2, y: 0, width: pw, height: ph))
        ctx.restoreGState()
        if let text {
            let top = ph + 40
            ctx.setFillColor(NSColor(rgb: 0xFF8A4C).cgColor)
            ctx.fill(CGRect(x: CGFloat(cardPad), y: top + 6, width: 6, height: max(20, textHeight - 12)))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            text.draw(with: CGRect(x: CGFloat(cardTextX), y: top, width: textWidth, height: textHeight + 4),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            more?.draw(at: CGPoint(x: CGFloat(cardTextX), y: top + textHeight + 14))
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let card = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, card, [kCGImageDestinationLossyCompressionQuality: previewQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= maxPreviewBytes else { return nil }
        return data as Data
    }

    private static func describe(_ body: String) -> String {
        if body.contains("image_too_large") { return "знімок завеликий" }
        if body.contains("image_count") { return "забагато знімків" }
        if body.contains("not_an_image") { return "файл не схожий на зображення" }
        return body.count > 120 ? String(body.prefix(120)) : body
    }

    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
