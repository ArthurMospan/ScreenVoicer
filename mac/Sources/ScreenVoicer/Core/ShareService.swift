import Foundation

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

        let meta: [String: Any] = [
            "app": "ScreenVoicer \(AppInfo.version)",
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
