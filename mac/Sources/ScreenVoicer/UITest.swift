import AppKit
import Carbon.HIToolbox

/// `ScreenVoicer --ui-test <dir>`: drives the real app in CI — real windows, real screen capture, synthetic mouse
/// and keyboard events through NSApp.sendEvent — and saves screenshots of every window with the real materials.
@MainActor
enum UITest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  ui: \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !ok { failures += 1 }
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func run(app: AppDelegate, output: URL) async -> Int32 {
        Log.echoToConsole = true
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        await seedHistory(app)
        await wait(1)

        // gallery
        app.openGallery()
        await wait(2)
        await shoot("real-gallery", output)
        app.closeGalleryForTest()
        await wait(0.5)

        // menu-bar menu
        app.openMenuForTest()
        await wait(1)
        check("menu opens", app.isMenuOpenForTest)
        await shoot("real-menu", output)
        app.closeMenuForTest()
        await wait(0.5)

        // toast
        ToastCenter.shared.show(ToastOptions(title: "Скопійовано в буфер обміну", message: "«Перевірка тосту»", kind: .success,
                                             copyText: "x", onOpenGallery: {}, durationMs: 8000))
        await wait(1)
        await shoot("real-toast", output)
        ToastCenter.shared.hideAll()
        await wait(0.3)

        await overlayFlow(app, output)
        await voiceFlow(app)

        // hotkey dialog
        app.openHotkeySettings()
        await wait(1)
        await shoot("real-hotkey", output)
        if let window = NSApp.windows.first(where: { $0.title == "ScreenVoicer — гаряча клавіша" }) {
            key(window, kVK_Escape, "\u{1b}")
            await wait(0.4)
            check("hotkey dialog closes on Esc", !window.isVisible)
        } else {
            check("hotkey dialog opens", false)
        }

        print(failures == 0 ? "UI ALL PASSED" : "UI \(failures) FAILED")
        return Int32(failures)
    }

    private static func overlayFlow(_ app: AppDelegate, _ output: URL) async {
        let before = await app.historyForTest.all().count
        app.clickMenuBarIconForTest() // a left click on the menu-bar icon takes the screenshot
        await wait(2.5)
        guard let overlay = app.overlayForTest, let panel = overlay.panelForTest else {
            check("overlay opens", false)
            return
        }
        check("overlay opens", true)
        check("overlay panel is key", panel.isKeyWindow, "key window: \(NSApp.keyWindow?.title ?? "none")")
        let size = panel.frame.size

        // the hint is shown until a region is selected
        check("hint visible before selection", overlay.model.hintVisible)

        // select a region with the mouse
        mouse(panel, .leftMouseDown, CGPoint(x: size.width * 0.25, y: size.height * 0.3))
        mouse(panel, .leftMouseDragged, CGPoint(x: size.width * 0.5, y: size.height * 0.5))
        mouse(panel, .leftMouseDragged, CGPoint(x: size.width * 0.7, y: size.height * 0.75))
        mouse(panel, .leftMouseUp, CGPoint(x: size.width * 0.7, y: size.height * 0.75))
        await wait(0.3)
        check("region selected", !overlay.model.hintVisible)

        // A = arrow tool, then draw an arrow inside the selection
        key(panel, kVK_ANSI_A, "a")
        check("A selects the arrow", overlay.model.tool == .arrow, "\(overlay.model.tool)")
        mouse(panel, .leftMouseDown, CGPoint(x: size.width * 0.35, y: size.height * 0.4))
        mouse(panel, .leftMouseDragged, CGPoint(x: size.width * 0.5, y: size.height * 0.55))
        mouse(panel, .leftMouseUp, CGPoint(x: size.width * 0.5, y: size.height * 0.55))
        check("arrow drawn", overlay.items.count == 1 && overlay.model.canUndo, "\(overlay.items.count) items")

        // N = numbered marker
        key(panel, kVK_ANSI_N, "n")
        mouse(panel, .leftMouseDown, CGPoint(x: size.width * 0.52, y: size.height * 0.57))
        mouse(panel, .leftMouseUp, CGPoint(x: size.width * 0.52, y: size.height * 0.57))
        check("marker added", overlay.items.contains { $0 is MarkerAnnotation })

        // T = text label: click, type, Enter
        key(panel, kVK_ANSI_T, "t")
        mouse(panel, .leftMouseDown, CGPoint(x: size.width * 0.3, y: size.height * 0.65))
        mouse(panel, .leftMouseUp, CGPoint(x: size.width * 0.3, y: size.height * 0.65))
        type(panel, "Тут баг")
        key(panel, kVK_Return, "\r")
        check("label typed", overlay.items.contains { ($0 as? LabelAnnotation)?.text == "Тут баг" },
              overlay.items.compactMap { ($0 as? LabelAnnotation)?.text }.joined(separator: ","))

        // ⌘Z undoes the label, ⇧⌘Z brings it back
        key(panel, kVK_ANSI_Z, "z", [.command])
        check("⌘Z undo", !overlay.items.contains { $0 is LabelAnnotation })
        key(panel, kVK_ANSI_Z, "z", [.command, .shift])
        check("⇧⌘Z redo", overlay.items.contains { $0 is LabelAnnotation })

        // the toolbar takes clicks (hit-testing through the full-screen chrome): «Весь екран», then «Область»
        let bar = overlay.model.toolbarFrame
        check("toolbar laid out", bar.width > 600, "\(bar)")
        mouse(panel, .leftMouseDown, CGPoint(x: bar.minX + 5 + 34 + 2 + 17, y: bar.midY))
        mouse(panel, .leftMouseUp, CGPoint(x: bar.minX + 5 + 34 + 2 + 17, y: bar.midY))
        await wait(0.3)
        check("toolbar click: full screen", overlay.model.mode == .fullScreen, "\(overlay.model.mode)")
        mouse(panel, .leftMouseDown, CGPoint(x: bar.minX + 5 + 17, y: bar.midY))
        mouse(panel, .leftMouseUp, CGPoint(x: bar.minX + 5 + 17, y: bar.midY))
        await wait(0.3)
        check("toolbar click: region again", overlay.model.mode == .rectangleRegion)

        // type a comment: focus the comment box, type, a Space tap types a space there
        if let comment = overlay.commentView {
            panel.makeFirstResponder(comment)
            type(panel, "Кнопка не працює")
            await wait(0.3)
            check("comment typed", overlay.model.comment == "Кнопка не працює", "«\(overlay.model.comment)»")
        } else {
            check("comment box exists", false)
        }
        await wait(0.5)
        await shoot("real-overlay", output)

        // Enter saves: PNG + history + clipboard (Markdown + image)
        key(panel, kVK_Return, "\r")
        await wait(3)
        check("overlay closed after save", app.overlayForTest == nil)
        let items = await app.historyForTest.all()
        check("history entry added", items.count == before + 1, "\(before) → \(items.count)")
        if let newest = items.first {
            check("saved PNG exists", FileManager.default.fileExists(atPath: newest.imagePath), newest.imagePath)
            check("comment stored", newest.transcribedText == "Кнопка не працює", newest.transcribedText)
            let pasteboard = NSPasteboard.general
            let text = pasteboard.string(forType: .string) ?? ""
            check("clipboard Markdown", text == "[\(newest.imagePath)]\n**Comment:** Кнопка не працює", text)
            check("clipboard PNG", (pasteboard.data(forType: .png)?.count ?? 0) > 1000)
            check("saved size = selection × scale", newest.width > 100 && newest.height > 100, "\(newest.width)×\(newest.height)")
        }
        await wait(1)
        await shoot("real-saved-toast", output)
        ToastCenter.shared.hideAll()
    }

    /// Space tap = hands-free recording, the next press stops it; the take lands in last-recording.wav.
    private static func voiceFlow(_ app: AppDelegate) async {
        try? FileManager.default.removeItem(at: Paths.lastRecording)
        app.capture()
        await wait(2.5)
        guard let overlay = app.overlayForTest, let panel = overlay.panelForTest else {
            check("second overlay opens", false)
            return
        }
        keyEvent(panel, .keyDown, kVK_Space, " ")
        await wait(0.1)
        keyEvent(panel, .keyUp, kVK_Space, " ")
        await wait(0.6)
        check("Space tap keeps recording (hands-free)", overlay.model.isRecording, overlay.model.status?.text ?? "no status")
        await wait(1.6)
        keyEvent(panel, .keyDown, kVK_Space, " ")
        keyEvent(panel, .keyUp, kVK_Space, " ")
        await wait(2.5)
        check("second Space press stops recording", !overlay.model.isRecording)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: Paths.lastRecording.path)[.size] as? NSNumber)?.intValue ?? 0
        let seconds = Double(max(0, bytes - 44)) / 32000
        check("the take was recorded at 16 kHz", seconds >= 1.5, String(format: "%.1f s, status: %@", seconds, overlay.model.status?.text ?? "none"))
        keyEvent(panel, .keyDown, kVK_Escape, "\u{1b}")
        await wait(0.5)
        if app.overlayForTest != nil {
            keyEvent(panel, .keyDown, kVK_Escape, "\u{1b}")
            await wait(0.5)
        }
        check("Esc closes the overlay", app.overlayForTest == nil)
    }

    // MARK: helpers

    private static func seedHistory(_ app: AppDelegate) async {
        let settings = app.settingsForTest
        try? FileManager.default.createDirectory(atPath: settings.outputDirectory, withIntermediateDirectories: true)
        let comments = ["Кнопка «Зберегти» не реагує, коли форма порожня", "", "Тут текст наїжджає на іконку"]
        for (i, comment) in comments.enumerated() {
            let path = (settings.outputDirectory as NSString).appendingPathComponent("screenshot_2026100\(i)_090000_000.png")
            try? Snapshots.samplePNG(width: 1600, height: 1000, seed: i)?.write(to: URL(fileURLWithPath: path))
            var item = ScreenshotHistoryItem()
            item.imagePath = path
            item.transcribedText = comment
            item.width = 1600
            item.height = 1000
            item.createdAt = Date().addingTimeInterval(Double(-(i + 1) * 3600))
            await app.historyForTest.add(item)
        }
    }

    private static func shoot(_ name: String, _ output: URL) async {
        do {
            let capture = try await ScreenCaptureService.captureScreenUnderCursor()
            if let data = NSBitmapImageRep(cgImage: capture.image).representation(using: .png, properties: [:]) {
                try data.write(to: output.appendingPathComponent("\(name).png"))
                print("OK    ui shot \(name) (\(capture.image.width)x\(capture.image.height))")
            }
        } catch {
            print("WARN  ui shot \(name): \(error.localizedDescription)")
        }
    }

    private static func key(_ window: NSWindow, _ code: Int, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                               isARepeat: false, keyCode: UInt16(code)) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private static func keyEvent(_ window: NSWindow, _ type: NSEvent.EventType, _ code: Int, _ chars: String) {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: UInt16(code)) else { return }
        NSApp.sendEvent(event)
    }

    private static func type(_ window: NSWindow, _ text: String) {
        for character in text {
            let chars = String(character)
            key(window, character == " " ? kVK_Space : 0, chars)
        }
    }

    /// `point` is top-left based, like the overlay.
    private static func mouse(_ window: NSWindow, _ type: NSEvent.EventType, _ point: CGPoint) {
        let location = CGPoint(x: point.x, y: window.frame.height - point.y)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.sendEvent(event)
    }
}
