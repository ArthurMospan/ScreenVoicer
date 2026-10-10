import Foundation

/// One saved screenshot (same JSON keys as the Windows ScreenshotHistoryItem).
struct ScreenshotHistoryItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var imagePath: String = ""
    var transcribedText: String = ""
    var createdAt: Date = Date()
    var width: Int = 0
    var height: Int = 0
    var fileSizeBytes: Int64 = 0

    /// Public link to this screenshot (shared alone or together with others), if any.
    var shareId: String?
    var shareUrl: String?
    var shareDeleteToken: String?
    var shareExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id = "Id", imagePath = "ImagePath", transcribedText = "TranscribedText", createdAt = "CreatedAt"
        case width = "Width", height = "Height", fileSizeBytes = "FileSizeBytes"
        case shareId = "ShareId", shareUrl = "ShareUrl", shareDeleteToken = "ShareDeleteToken", shareExpiresAt = "ShareExpiresAt"
    }

    var hasActiveShare: Bool { shareUrl != nil && (shareExpiresAt ?? .distantPast) > Date() }
    var hasVoiceComment: Bool { !transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var displayDate: String { Formats.displayDate.string(from: createdAt) }
    var fileName: String { (imagePath as NSString).lastPathComponent }
}

enum Formats {
    /// "09.10.2026 14:05", as the Windows gallery shows dates (and searches them).
    static let displayDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    /// "9 листопада" for «діє до …».
    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "d MMMM"
        return f
    }()

    /// "9 лист." for the share badge on a card.
    static let dayMonthShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "d MMM"
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return f
    }()

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded(.down)))%" }

    /// Ukrainian plural: 1 знімок, 2 знімки, 5 знімків.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word = mod10 == 1 && mod100 != 11 ? one
            : (2...4).contains(mod10) && !(12...14).contains(mod100) ? few
            : many
        return "\(n) \(word)"
    }
}

/// history.json next to settings.json; newest first. All access goes through one serial queue.
final class HistoryService {
    private let fileURL: URL
    private let settings: Settings
    private let queue = DispatchQueue(label: "ScreenVoicer.History")
    private let countLock = NSLock()
    private var loadedCount: Int?
    private var items: [ScreenshotHistoryItem]? {
        didSet {
            countLock.lock()
            loadedCount = items?.count
            countLock.unlock()
        }
    }

    /// Called on the main thread after an entry was added, removed or changed.
    var onChange: (() -> Void)?

    init(settings: Settings, directory: URL = Paths.appSupport) {
        self.settings = settings
        Paths.ensure(directory)
        fileURL = directory.appendingPathComponent("history.json")
    }

    /// Number of entries if already loaded (never blocks).
    var cachedCount: Int? {
        countLock.lock()
        defer { countLock.unlock() }
        return loadedCount
    }

    func all() async -> [ScreenshotHistoryItem] {
        await run { [self] in
            var list = ensureLoaded()
            let before = list.count
            list.removeAll { !FileManager.default.fileExists(atPath: $0.imagePath) }
            if list.count != before {
                items = list
                save(list)
            }
            return list
        }
    }

    func add(_ item: ScreenshotHistoryItem) async {
        await run { [self] in
            var list = ensureLoaded()
            list.removeAll { $0.imagePath == item.imagePath }
            let index = list.firstIndex { $0.createdAt <= item.createdAt } ?? list.count
            list.insert(item, at: index)
            items = list
            save(list)
        }
        notify()
    }

    /// Removes the entry and deletes its file. Throws when the file can't be removed.
    @discardableResult
    func delete(id: String) async throws -> Bool {
        let removed: Bool = try await runThrowing { [self] in
            var list = ensureLoaded()
            guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
            let path = list[index].imagePath
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            list.remove(at: index)
            items = list
            save(list)
            return true
        }
        if removed { notify() }
        return removed
    }

    /// Stores (or with nil clears) the public link on these entries.
    func setShare(ids: Set<String>, share: ShareResult?) async {
        await run { [self] in
            var list = ensureLoaded()
            for i in list.indices where ids.contains(list[i].id) {
                list[i].shareId = share?.id
                list[i].shareUrl = share?.url
                list[i].shareDeleteToken = share?.deleteToken
                list[i].shareExpiresAt = share?.expiresAt
            }
            items = list
            save(list)
        }
        notify()
    }

    // MARK: - storage (queue only)

    private func ensureLoaded() -> [ScreenshotHistoryItem] {
        if let items { return items }
        var list: [ScreenshotHistoryItem] = []
        if let data = try? Data(contentsOf: fileURL) {
            do {
                list = try Self.decoder.decode([ScreenshotHistoryItem].self, from: data)
            } catch {
                // keep the damaged file for manual recovery instead of overwriting the comments
                let backup = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("history.corrupt-\(Formats.fileStamp.string(from: Date())).json")
                Log.error("[History] history.json is unreadable, moved to '\(backup.path)'", error)
                try? FileManager.default.moveItem(at: fileURL, to: backup)
            }
        }
        let imported = importUnindexed(&list)
        list.removeAll { $0.imagePath.isEmpty || !FileManager.default.fileExists(atPath: $0.imagePath) }
        list.sort { $0.createdAt > $1.createdAt }
        items = list
        if imported { save(list) }
        return list
    }

    /// Screenshots in the output folder that history.json doesn't know about.
    private func importUnindexed(_ list: inout [ScreenshotHistoryItem]) -> Bool {
        let dir = settings.outputDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        let known = Set(list.map(\.imagePath))
        var changed = false
        for name in names where name.hasPrefix("screenshot_") && name.lowercased().hasSuffix(".png") {
            let path = (dir as NSString).appendingPathComponent(name)
            if known.contains(path) { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            var item = ScreenshotHistoryItem()
            item.imagePath = path
            item.createdAt = (attrs?[.creationDate] as? Date) ?? Date()
            item.fileSizeBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            list.append(item)
            changed = true
        }
        return changed
    }

    private func save(_ list: [ScreenshotHistoryItem]) {
        do {
            try Self.encoder.encode(list).write(to: fileURL, options: .atomic)
        } catch {
            Log.error("[History] Could not save history.json", error)
        }
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    private func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func runThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // ISO 8601 with fractional seconds and the time zone, like .NET's round-trip format.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = isoFormatter.date(from: text) ?? isoPlain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(text)")
        }
        return d
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()
}
