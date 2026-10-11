import AppKit
import SwiftUI

/// `ScreenVoicer --snapshots <dir>`: renders every window to PNG with sample data, for visual review in CI
/// (materials are drawn as flat stand-ins: NSVisualEffectView can't render offscreen).
enum Snapshots {
    @MainActor
    static func render(to directory: URL) async -> Int32 {
        RenderMode.snapshot = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sv-snapshots-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        var failures = 0

        func save<V: View>(_ name: String, _ view: V, background: Color = Color(rgb: 0x3A4250)) {
            let renderer = ImageRenderer(content: view.padding(24).background(background))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("FAIL  snapshot \(name)")
                failures += 1
                return
            }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
            print("OK    snapshot \(name) (\(image.width)x\(image.height))")
        }

        // Overlay toolbar in its states
        let idle = OverlayModel()
        idle.hintVisible = false
        save("overlay-toolbar-idle", OverlayChrome(model: idle).frame(width: 900, height: 120))

        let recording = OverlayModel()
        recording.isRecording = true
        recording.level = 0.6
        recording.comment = "Кнопка «Зберегти» не реагує, коли форма"
        recording.commentReadOnly = true
        recording.commentIsPreview = true
        recording.status = OverlayStatus(text: "Говоріть… відпустіть Пробіл, коли закінчите", kind: .recording)
        recording.tool = .arrow
        recording.colorRGB = 0x3B82F6
        save("overlay-toolbar-recording", OverlayChrome(model: recording).frame(width: 900, height: 140))

        let flyouts = OverlayModel()
        flyouts.openFlyout = .tool
        flyouts.canUndo = true
        save("overlay-toolbar-tools", OverlayChrome(model: flyouts).frame(width: 900, height: 200))
        let colors = OverlayModel()
        colors.openFlyout = .color
        save("overlay-toolbar-colors", OverlayChrome(model: colors).frame(width: 900, height: 200))

        let busy = OverlayModel()
        busy.status = OverlayStatus(text: "Розпізнаю…", kind: .busy)
        busy.comment = "Тут має бути кнопка «Надіслати»"
        save("overlay-status-busy", OverlayChrome(model: busy).frame(width: 900, height: 140))

        save("overlay-hint", HintBadge())

        // The whole overlay: a fake screen, dim, selection, annotations and the chrome
        if let composite = overlayComposite(temp: temp) {
            try? composite.write(to: directory.appendingPathComponent("overlay-full.png"))
            print("OK    snapshot overlay-full")
        } else {
            failures += 1
        }

        // Menu-bar menu
        let host = SampleMenuHost()
        let menu = TrayMenuModel()
        menu.host = host
        menu.refresh()
        save("menu", TrayMenuView(model: menu))
        let menuOpen = TrayMenuModel()
        menuOpen.host = host
        menuOpen.refresh()
        menuOpen.modelOpen = true
        menuOpen.aboutOpen = true
        menuOpen.updateVersion = "1.11.0"
        save("menu-expanded", TrayMenuView(model: menuOpen))

        // Toasts
        let shot = temp.appendingPathComponent("toast.png")
        try? samplePNG(width: 1200, height: 800)?.write(to: shot)
        var saved = ToastOptions(title: "Скопійовано в буфер обміну", message: "«Кнопка «Зберегти» не реагує, коли форма порожня»",
                                 kind: .success, imagePath: shot.path, copyText: "x", onOpenGallery: {}, durationMs: 5000)
        saved.actionText = "Посилання"
        saved.onAction = {}
        save("toast-saved", ToastView(state: ToastState(options: saved), actions: noActions))
        save("toast-info", ToastView(state: ToastState(options: ToastOptions(
            title: "ScreenVoicer працює в рядку меню", message: "⌥⇧S — знімок екрана, затисніть Пробіл — голосовий коментар.")),
            actions: noActions))
        var failed = ToastOptions(title: "Розпізнавання голосу недоступне", message: "Не вдалося завантажити модель «base». Перевірте інтернет.",
                                  kind: .error)
        failed.actionText = "Повторити"
        failed.onAction = {}
        save("toast-error", ToastView(state: ToastState(options: failed), actions: noActions))

        // Gallery with sample screenshots
        let settings = Settings(directory: temp)
        settings.outputDirectory = temp.appendingPathComponent("shots").path
        let history = HistoryService(settings: settings, directory: temp)
        let comments = ["Кнопка «Зберегти» не реагує, коли форма порожня", "", "Тут текст наїжджає на іконку в меню, треба відступ 8 px",
                        "The dropdown closes before I can pick an item"]
        for (i, comment) in comments.enumerated() {
            let path = (settings.outputDirectory as NSString).appendingPathComponent("screenshot_2026101\(i)_120000_000.png")
            try? FileManager.default.createDirectory(atPath: settings.outputDirectory, withIntermediateDirectories: true)
            try? samplePNG(width: 1600, height: 1000, seed: i)?.write(to: URL(fileURLWithPath: path))
            var item = ScreenshotHistoryItem()
            item.imagePath = path
            item.transcribedText = comment
            item.width = 1600
            item.height = 1000
            item.createdAt = Date().addingTimeInterval(Double(-i * 3600))
            if i == 0 {
                item.shareUrl = "https://screenvoicer.masspain.workers.dev/s/abc"
                item.shareExpiresAt = Date().addingTimeInterval(30 * 86400)
            }
            await history.add(item)
        }
        let gallery = GalleryModel(history: history)
        gallery.hotkeyText = { "⌥⇧S" }
        gallery.startDelayedCapture = { _ in }
        await gallery.load()
        try? await Task.sleep(nanoseconds: 800_000_000) // thumbnails decode in the background
        gallery.selected = [gallery.all[1].id, gallery.all[2].id]
        save("gallery", GalleryView(model: gallery).frame(width: 1080, height: 760), background: Theme.window)
        let empty = GalleryModel(history: HistoryService(settings: Settings(directory: temp.appendingPathComponent("empty")),
                                                         directory: temp.appendingPathComponent("empty")))
        empty.hotkeyText = { "⌥⇧S" }
        await empty.load()
        save("gallery-empty", GalleryView(model: empty).frame(width: 900, height: 560), background: Theme.window)

        // Dialogs
        let hotkey = HotkeyModel(current: HotkeyGesture.parse("Alt+Shift+S")!)
        save("hotkey", HotkeyView(model: hotkey))
        let countdown = CountdownModel()
        countdown.seconds = 5
        save("countdown", CountdownView(model: countdown, cancel: {}))
        save("permissions", PermissionsView(model: PermissionsModel()))

        // Logo and menu-bar icon
        save("brand", HStack(spacing: 24) {
            BrandMark(size: 128)
            Image(nsImage: Brand.menuBarImage()).renderingMode(.template).foregroundColor(.white).scaleEffect(2)
            Image(nsImage: Brand.menuBarImage()).renderingMode(.template).foregroundColor(.black).scaleEffect(2)
                .padding(8).background(Color.white)
        })

        try? FileManager.default.removeItem(at: temp)
        return Int32(failures)
    }

    private static let noActions = ToastActions(close: {}, copy: {}, openImage: {}, action: {}, gallery: {}, hover: { _ in })

    /// A screenshot-like picture: a window with a sidebar and some text bars.
    static func samplePNG(width: Int, height: Int, seed: Int = 0) -> Data? {
        guard let image = sampleImage(width: width, height: height, seed: seed) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func sampleImage(width: Int, height: Int, seed: Int = 0) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let tints: [UInt32] = [0x2E6BD6, 0x2E9E6B, 0xA0522D, 0x7B4BC4]
        ctx.setFillColor(NSColor(rgb: 0xE9ECF1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor(rgb: tints[seed % tints.count]).cgColor)
        ctx.fill(CGRect(x: 0, y: h - h * 0.08, width: w, height: h * 0.08))
        ctx.setFillColor(NSColor(rgb: 0xD5DAE2).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w * 0.2, height: h * 0.92))
        ctx.setFillColor(NSColor(rgb: 0xFFFFFF).cgColor)
        ctx.fill(CGRect(x: w * 0.25, y: h * 0.12, width: w * 0.7, height: h * 0.72))
        ctx.setFillColor(NSColor(rgb: 0xB8C0CC).cgColor)
        for row in 0..<8 {
            let y = h * 0.78 - CGFloat(row) * h * 0.07
            ctx.fill(CGRect(x: w * 0.29, y: y, width: w * (0.3 + 0.05 * CGFloat((row + seed) % 5)), height: h * 0.025))
        }
        ctx.setFillColor(NSColor(rgb: tints[(seed + 1) % tints.count]).cgColor)
        ctx.fill(CGRect(x: w * 0.75, y: h * 0.16, width: w * 0.15, height: h * 0.06))
        return ctx.makeImage()
    }

    @MainActor
    private static func overlayComposite(temp: URL) -> Data? {
        let size = CGSize(width: 1440, height: 900)
        guard let screen = sampleImage(width: 2880, height: 1800, seed: 0) else { return nil }
        let selection = CGRect(x: 360, y: 260, width: 760, height: 470)
        var items: [AnnotationItem] = []
        if let blur = BlurAnnotation.make(capture: screen, scale: 2, rect: CGRect(x: 780, y: 300, width: 300, height: 90),
                                          block: Thickness.blurBlock[1]) {
            items.append(blur)
        }
        items += [
            StrokeAnnotation(points: [CGPoint(x: 420, y: 330), CGPoint(x: 600, y: 330)], color: NSColor(rgb: 0xFACC15), width: 22, style: .highlighter),
            StrokeAnnotation(points: [CGPoint(x: 700, y: 520), CGPoint(x: 1040, y: 640), CGPoint(x: 1010, y: 610), CGPoint(x: 1040, y: 640), CGPoint(x: 1000, y: 650)],
                             color: NSColor(rgb: 0xEF4444), width: 4, style: .shape),
            LabelAnnotation(position: CGPoint(x: 720, y: 470), text: "Не працює", color: NSColor(rgb: 0xEF4444), fontSize: 20),
            MarkerAnnotation(center: CGPoint(x: 1065, y: 655), number: 1, color: NSColor(rgb: 0xEF4444), size: 30)
        ]
        let model = OverlayModel()
        model.comment = "Кнопка «Надіслати» не реагує"
        model.status = OverlayStatus(text: "Готово! Enter — зберегти і скопіювати, Пробіл — додати ще.", kind: .success)

        let view = ZStack(alignment: .topLeading) {
            Image(decorative: screen, scale: 2)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(selection)
            }
            .fill(Color.black.opacity(0x8C / 255.0), style: FillStyle(eoFill: true))
            Canvas { context, _ in
                context.withCGContext { cg in
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                    cg.clip(to: selection)
                    AnnotationRenderer.draw(items, in: cg)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            Rectangle().stroke(Color.white, lineWidth: 1.25).frame(width: selection.width, height: selection.height)
                .offset(x: selection.minX, y: selection.minY)
            ForEach(0..<8, id: \.self) { i in
                let p = FrameView.handlePoint(selection, i)
                RoundedRectangle(cornerRadius: 2).fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0x8C / 255.0), lineWidth: 1))
                    .frame(width: 8, height: 8)
                    .offset(x: p.x - 4, y: p.y - 4)
            }
            OverlayChrome(model: model)
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Sample data for the menu snapshot.
@MainActor
private final class SampleMenuHost: MenuHost {
    var captureHotkey = "⌥⇧S"
    var appVersion = "1.11.0"
    var voiceStatus: (text: String, kind: TrayStatusKind) = ("Голос готовий · Точна · Apple M2", .ready)
    var screenshotCount = 23
    func microphones() -> [MicrophoneInfo] {
        [MicrophoneInfo(uid: "", displayName: "Системний за замовчуванням (MacBook Air Microphone)"),
         MicrophoneInfo(uid: "mbp", displayName: "MacBook Air Microphone"),
         MicrophoneInfo(uid: "airpods", displayName: "AirPods Pro")]
    }
    var selectedMicrophone = ""
    var canPlayLastRecording = true
    var voiceLanguage = "uk"
    var selectedModel = WhisperModels.small
    var useGpu = true
    var gpuAvailable = true
    var gpuName: String? = "Apple M2"
    var autostartEnabled = true
    var aboutText = "ScreenVoicer 1.11.0 — скриншоти з голосовими коментарями для баг-репортів і AI-асистентів.\nРозпізнавання: «Точна», офлайн, на Apple M2.\nСкриншоти: ~/AI_Screenshots"
    var updateVersion: String?
    var updateProgress: Double?
    func capture() {}
    func captureDelayed(_ seconds: Int) {}
    func openGallery() {}
    func openScreenshotsFolder() {}
    func selectMicrophone(_ microphone: MicrophoneInfo) {}
    func playLastRecording() {}
    func setVoiceLanguage(_ code: String) {}
    func selectModel(_ model: WhisperModelInfo) {}
    func setUseGpu(_ on: Bool) {}
    func openHotkeySettings() {}
    func setAutostart(_ on: Bool) {}
    func openLog() {}
    func openModelsFolder() {}
    func quit() {}
    func installUpdate() {}
    func checkForUpdates() {}
}
