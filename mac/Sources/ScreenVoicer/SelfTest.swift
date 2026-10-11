import AppKit
import Foundation

/// `ScreenVoicer --selftest [--model base] [--wav file.wav] [--expect word] [--lang en]`
/// Headless checks for CI (no screen or microphone needed). Prints PASS/FAIL lines, exit code = failures.
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !ok { failures += 1 }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sv-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        testText()
        testAudioAnalysis()
        testHotkeys()
        testUpdateParsing()
        testIcons()
        testSettings(temp)
        await testHistory(temp)
        testClipboard(temp)
        await testCompositor(temp)
        await testWhisper(args)

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return Int32(failures)
    }

    private static func testText() {
        check("cleaner removes tags", TranscriptCleaner.clean("[BLANK_AUDIO] Тут баг (музика)") == "Тут баг")
        check("cleaner drops standalone hallucination", TranscriptCleaner.clean("Дякую за перегляд!") == "")
        check("cleaner keeps real subtitles talk",
              TranscriptCleaner.clean("субтитри у плеєрі не показуються") == "субтитри у плеєрі не показуються")
        check("cleaner drops subtitle credits", TranscriptCleaner.clean("Кнопка не працює. Субтитри створено Amara.org") == "Кнопка не працює.")
        check("cleaner collapses loops", TranscriptCleaner.clean("тест тест тест тест кнопка") == "тест тест кнопка")
        check("append joins", TranscriptCleaner.append("Перше ", " друге") == "Перше друге")
        check("markdown with comment",
              Clipboard.formatMarkdown(imagePath: "/a/b.png", comment: " Тут баг ") == "[/a/b.png]\n**Comment:** Тут баг")
        check("markdown without comment",
              Clipboard.formatMarkdown(imagePath: "/a/b.png", comment: "") == "[/a/b.png]\n**Comment:** *(No voice comment recorded)*")
        check("plural", Formats.plural(1, "знімок", "знімки", "знімків") == "1 знімок"
              && Formats.plural(3, "знімок", "знімки", "знімків") == "3 знімки"
              && Formats.plural(12, "знімок", "знімки", "знімків") == "12 знімків"
              && Formats.plural(21, "знімок", "знімки", "знімків") == "21 знімок")
    }

    private static func testAudioAnalysis() {
        let silence = [Float](repeating: 0, count: 16000)
        check("silence has no speech", !AudioAnalysis.hasSpeech(silence))
        check("digital silence detected", AudioAnalysis.isDigitalSilence(silence))
        var voice = [Float](repeating: 0, count: 32000)
        for i in 0..<voice.count {
            let envelope: Float = (i / 4000) % 2 == 0 ? 0.3 : 0.001
            voice[i] = envelope * sin(Float(i) * 2 * .pi * 220 / 16000)
        }
        check("modulated tone counts as speech", AudioAnalysis.hasSpeech(voice))
        let quiet = voice.map { $0 * 0.05 }
        let normalized = AudioAnalysis.normalizeLevel(quiet)
        check("normalize raises a quiet take", (normalized.map { abs($0) }.max() ?? 0) > (quiet.map { abs($0) }.max() ?? 0) * 4)
        check("pad for whisper", AudioAnalysis.padForWhisper([Float](repeating: 0.1, count: 100)).count == 20000)
    }

    private static func testHotkeys() {
        let g = HotkeyGesture.parse(Settings.defaultHotkey)
        check("default hotkey parses", g != nil && g!.displayText == "⌥⇧S" && g!.storageText == "Alt+Shift+S")
        check("hotkey needs a modifier", HotkeyGesture.parse("S") == nil && HotkeyGesture.parse("F9") != nil)
        check("reserved hotkey", HotkeyGesture.parse("Shift+Cmd+4")?.isReserved == true)
        check("Insert works alone (PC keyboards)", HotkeyGesture.parse("Insert")?.displayText == "Insert")
    }

    private static func testUpdateParsing() {
        let json = """
        {"tag_name":"v1.11.0","draft":false,"prerelease":false,"body":"## 1.11.0\\n- Mac version","html_url":"https://x",
         "assets":[{"name":"ScreenVoicer-Setup.exe","browser_download_url":"https://e","size":5},
                   {"name":"ScreenVoicer-macOS.zip","browser_download_url":"https://m","size":7,"digest":"sha256:ABCD"}]}
        """
        let info = UpdateService.parseLatestRelease(Data(json.utf8), current: SemVer("1.10.0")!)
        check("update found", info?.assetUrl == "https://m" && info?.sha256 == "abcd" && info?.size == 7)
        check("no update when current", UpdateService.parseLatestRelease(Data(json.utf8), current: SemVer("1.11.0")!) == nil)
        check("semver order", SemVer("1.10.0")! > SemVer("1.9.9")! && SemVer("1.10")! == SemVer("1.10.0")!)
        check("release summary", UpdateService.summary("## 1.11.0\n- Mac version\n- Faster") == "1.11.0 · Mac version · Faster")
    }

    private static func testIcons() {
        var empty: [String] = []
        for icon in Icon.allCases where icon.path.isEmpty {
            empty.append(icon.rawValue)
        }
        check("all icons parse", empty.isEmpty, empty.joined(separator: ", "))
        let box = Brand.markPath.boundingBoxOfPath
        check("logo spans its grid", box.minX >= 5 && box.maxX <= 59 && box.width > 50, "\(box)")
        check("arc icon is round", abs(Icon.number.path.boundingBoxOfPath.width - 17) < 0.6, "\(Icon.number.path.boundingBoxOfPath)")
    }

    private static func testSettings(_ dir: URL) {
        let a = Settings(directory: dir)
        a.language = "en"
        a.model = "small"
        a.hotkey = "Ctrl+Alt+P"
        a.defaultCaptureMode = .fullScreen
        a.save()
        let b = Settings(directory: dir)
        check("settings round-trip", b.language == "en" && b.model == "small" && b.hotkey == "Ctrl+Alt+P" && b.defaultCaptureMode == .fullScreen)
    }

    private static func testHistory(_ dir: URL) async {
        let settings = Settings(directory: dir)
        settings.outputDirectory = dir.appendingPathComponent("shots").path
        try? FileManager.default.createDirectory(atPath: settings.outputDirectory, withIntermediateDirectories: true)
        let png = (settings.outputDirectory as NSString).appendingPathComponent("screenshot_20260101_120000_000.png")
        try? Brand.pngData(pixels: 32)?.write(to: URL(fileURLWithPath: png))
        let orphan = (settings.outputDirectory as NSString).appendingPathComponent("screenshot_20250101_120000_000.png")
        try? Brand.pngData(pixels: 16)?.write(to: URL(fileURLWithPath: orphan))

        let history = HistoryService(settings: settings, directory: dir)
        var item = ScreenshotHistoryItem()
        item.imagePath = png
        item.transcribedText = "Тут баг"
        await history.add(item)
        let reloaded = await HistoryService(settings: settings, directory: dir).all()
        check("history round-trip", reloaded.contains { $0.id == item.id && $0.transcribedText == "Тут баг" })
        check("history imports unindexed files", reloaded.contains { $0.imagePath == orphan })
        let deleted = (try? await history.delete(id: item.id)) ?? false
        check("history delete removes the file", deleted && !FileManager.default.fileExists(atPath: png))
    }

    private static func testClipboard(_ dir: URL) {
        let png = dir.appendingPathComponent("clip.png")
        try? Brand.pngData(pixels: 64)?.write(to: png)
        let text = Clipboard.formatMarkdown(imagePath: png.path, comment: "Перевірка")
        let ok = Clipboard.copy(text, imagePath: png.path)
        let pb = NSPasteboard.general
        let back = pb.string(forType: .string)
        let file = pb.string(forType: .fileURL)
        let image = pb.data(forType: .png)
        check("clipboard holds the text", ok && back == text)
        check("clipboard holds the file and PNG", file == png.absoluteString && (image?.count ?? 0) > 100)
    }

    @MainActor
    private static func testCompositor(_ dir: URL) async {
        let result = CompositorSelfTest.run(outputDirectory: dir.appendingPathComponent("out"))
        check("compositor", result.ok, result.detail)
        let blur = CompositorSelfTest.runBlur()
        check("«Приховати» pixelates", blur.ok, blur.detail)
    }

    private static func testWhisper(_ args: [String]) async {
        guard let wavPath = value(after: "--wav", in: args) else {
            print("SKIP  whisper (no --wav)")
            return
        }
        guard let samples = readWav(URL(fileURLWithPath: wavPath)) else {
            check("read wav", false, wavPath)
            return
        }
        check("read wav", samples.count > 16000, "\(samples.count) samples")
        let service = WhisperService(language: value(after: "--lang", in: args) ?? "en",
                                     modelId: value(after: "--model", in: args) ?? "base",
                                     useGpu: true)
        let started = Date()
        let loaded = await service.ensureModelLoaded()
        check("model loads", loaded, service.lastError ?? "\(service.activeModel?.id ?? "?") on \(service.isRunningOnGpu ? "GPU \(service.gpuName ?? "")" : "CPU") in \(Int(Date().timeIntervalSince(started)))s")
        guard loaded else { return }
        let t0 = Date()
        let text = await service.transcribe(samples)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let expect = (value(after: "--expect", in: args) ?? "").lowercased()
        check("transcription", !text.isEmpty && (expect.isEmpty || text.lowercased().contains(expect)), "\(ms) ms: \"\(text)\"")
        let preview = await service.tryTranscribePreview(samples)
        check("preview transcription", preview != nil, "\"\(preview ?? "nil")\"")
    }

    /// 16-bit PCM WAV, any channel count / rate is not resampled: expects 16 kHz mono (afconvert LEI16@16000).
    static func readWav(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        var offset = 12
        var channels = 1
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            let body = offset + 8
            if id == "fmt " {
                channels = Int(data[body + 2]) | Int(data[body + 3]) << 8
            } else if id == "data" {
                let end = min(body + size, data.count)
                var samples: [Float] = []
                samples.reserveCapacity((end - body) / 2 / channels)
                var i = body
                while i + 1 < end {
                    let v = Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)
                    samples.append(Float(v) / 32768)
                    i += 2 * channels
                }
                return samples
            }
            offset = body + size + (size % 2)
        }
        return nil
    }
}
