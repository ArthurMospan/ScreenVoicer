import CryptoKit
import Foundation
import Security

enum AppInfo {
    /// The running version; SV_VERSION_OVERRIDE pretends to be older (for testing the update path).
    static var version: String {
        if let fake = ProcessInfo.processInfo.environment["SV_VERSION_OVERRIDE"], SemVer(fake) != nil {
            return fake
        }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "ua.com.mospan.screenvoicer" }
}

/// "1.10.0" — compared numerically like System.Version.
struct SemVer: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let numbers = trimmed.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.map { $0! }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: SemVer, b: SemVer) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

struct UpdateInfo {
    let version: SemVer
    let notes: String
    let assetUrl: String
    let size: Int64
    let sha256: String?
    let pageUrl: String
}

/// Updates from GitHub Releases, like UpdateService.cs: the latest release's «ScreenVoicer-macOS.zip» is downloaded,
/// its SHA-256 checked, its signature checked against this app's own designated requirement (same certificate),
/// and it replaces this app once it has quit; then the new version starts.
enum UpdateService {
    static let repository = "ArthurMospan/ScreenVoicer"
    static let assetName = "ScreenVoicer-macOS.zip"
    private static let latestReleaseApi = "https://api.github.com/repos/\(repository)/releases/latest"
    static var releasesPage: String { "https://github.com/\(repository)/releases" }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func check() async throws -> UpdateInfo? {
        var request = URLRequest(url: URL(string: latestReleaseApi)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ScreenVoicer/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil } // no release yet
        guard (200..<300).contains(status) else { throw UpdateError(message: "Сервер оновлень відповів \(status)") }
        return parseLatestRelease(data, current: SemVer(AppInfo.version) ?? SemVer("0.0.0")!)
    }

    /// Reads GitHub's «latest release» JSON; nil unless it is newer and has the Mac asset.
    static func parseLatestRelease(_ data: Data, current: SemVer) -> UpdateInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true { return nil }
        guard let tag = root["tag_name"] as? String, let version = SemVer(tag), version > current else { return nil }
        let assets = root["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(assetName) == .orderedSame }),
              let url = asset["browser_download_url"] as? String else { return nil }
        var sha: String?
        if let digest = asset["digest"] as? String, digest.lowercased().hasPrefix("sha256:") {
            sha = String(digest.dropFirst(7)).lowercased()
        }
        return UpdateInfo(version: version,
                          notes: root["body"] as? String ?? "",
                          assetUrl: url,
                          size: (asset["size"] as? NSNumber)?.int64Value ?? 0,
                          sha256: sha,
                          pageUrl: root["html_url"] as? String ?? releasesPage)
    }

    /// Downloads the zip and verifies its size and checksum; returns the local path.
    static func download(_ update: UpdateInfo, progress: @escaping (Double) -> Void) async throws -> URL {
        let dir = Paths.ensure(Paths.updates)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        let path = dir.appendingPathComponent("ScreenVoicer-macOS-\(update.version).zip")
        let bytes = try await FileDownloader.download(URL(string: update.assetUrl)!, to: path) { fraction, _ in progress(fraction) }

        let hash = try sha256(of: path)
        if (update.size > 0 && bytes != update.size) || (update.sha256 != nil && hash != update.sha256) {
            try? FileManager.default.removeItem(at: path)
            throw UpdateError(message: "Оновлення завантажилося пошкодженим. Спробуйте ще раз.")
        }
        Log.info("[Update] \(update.version) downloaded (\(bytes / 1_048_576) MB, sha256 \(hash.prefix(12))…).")
        return path
    }

    /// Unpacks the new app next to the download, checks it was signed with this app's certificate and schedules
    /// the swap: a tiny shell script waits for this process to exit, replaces the bundle and starts it again.
    static func installAfterExit(zip: URL) throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard current.pathExtension == "app" else { throw UpdateError(message: "Програма запущена не з пакета .app.") }
        if current.path.contains("/AppTranslocation/") {
            throw UpdateError(message: "Спершу перемістіть ScreenVoicer у папку «Програми», потім оновіть.")
        }
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError(message: "Немає прав замінити програму в «\(parent.path)». Перемістіть ScreenVoicer у «Програми».")
        }

        let staging = zip.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        let newApp = staging.appendingPathComponent("ScreenVoicer.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw UpdateError(message: "В архіві оновлення немає ScreenVoicer.app.")
        }
        try verifySignature(of: newApp)

        // Place the new copy next to the old one first, so the swap is a fast rename on the same volume.
        let incoming = parent.appendingPathComponent(".ScreenVoicer-update.app")
        try? FileManager.default.removeItem(at: incoming)
        try FileManager.default.moveItem(at: newApp, to: incoming)

        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.old"
        if mv "$3" "$3.old" && mv "$2" "$3"; then rm -rf "$3.old"; else mv "$3.old" "$3"; fi
        xattr -dr com.apple.quarantine "$3" 2>/dev/null
        open "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), incoming.path, current.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SV_VERSION_OVERRIDE") // a test override must not follow into the new app
        process.environment = environment
        try process.run()
        Log.info("[Update] Swap scheduled: \(incoming.path) → \(current.path)")
    }

    /// The update must satisfy this app's own designated requirement (identifier + signing certificate).
    static func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let ownStatic = staticCode,
              SecCodeCopyDesignatedRequirement(ownStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError(message: "Не вдалося перевірити підпис цієї програми.")
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError(message: "Не вдалося прочитати підпис оновлення.")
        }
        let status = SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)), requirement)
        guard status == errSecSuccess else {
            Log.warn("[Update] Signature check failed (\(status)).")
            throw UpdateError(message: "Підпис оновлення не збігається з підписом ScreenVoicer. Завантажте його вручну з сайту.")
        }
    }

    /// First lines of the release notes without Markdown markers, for a toast.
    static func summary(_ notes: String, maxLength: Int = 160) -> String {
        let lines = notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#-* ")).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
        let text = lines.joined(separator: " · ")
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(message: "\((tool as NSString).lastPathComponent) завершився з помилкою: \(output.prefix(200))")
        }
        return output
    }
}
