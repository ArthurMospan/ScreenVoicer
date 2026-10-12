import AppKit

/// Wiring of the app — the twin of App.xaml.cs: menu-bar item, hotkey, capture, speech model, updates, share links.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuHost {
    /// Current capture shortcut as macOS writes it ("⌥⇧S"), for hints across the UI.
    static private(set) var hotkeyText = "⌥⇧S"

    private static let showGalleryNotification = Notification.Name("ua.com.mospan.screenvoicer.showGallery")
    private static let languages = [("uk", "Українська"), ("en", "English"), ("auto", "Автовизначення (повільніше)")]

    private enum CaptureTrigger { case hotkey, trayClick, menu, delayed, gallery }

    private var settings: Settings!
    private var history: HistoryService!
    private var audio: AudioRecorder!
    private var whisper: WhisperService!
    private let hotkey = HotkeyService()

    private var statusItem: NSStatusItem!
    private var trayMenu: TrayMenuPanel?
    private let trayMenuModel = TrayMenuModel()
    private var trayMenuClosedAt = Date.distantPast

    private var overlay: OverlayController?
    private var gallery: GalleryWindowController?
    private var hotkeyWindow: HotkeyWindowController?
    private var permissionsWindow: PermissionsWindowController?
    private var captureStarting = false
    private var modelWasDownloading = false
    private var lastReportedState: ModelState = .notLoaded
    private var cleanedUp = false

    private var update: UpdateInfo?
    private var updateProgressValue: Double?
    private var updateTimer: Timer?

    // MARK: - Startup

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !acquireSingleInstance() {
            NSApp.terminate(nil)
            return
        }
        let autostart = CommandLine.arguments.contains(LoginItem.autostartArgument)
        Log.info("ScreenVoicer \(AppInfo.version) starting (autostart=\(autostart), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.activeProcessorCount) CPUs).")

        setupMainMenu()
        initializeServices()
        history.onChange = { [weak self] in
            self?.menuStateChanged()
            if let gallery = self?.gallery { Task { await gallery.model.load() } }
        }
        Task { _ = await history.all(); menuStateChanged() } // so the menu can show the count right away
        registerHotkey()
        initializeStatusItem()
        LoginItem.refreshIfEnabled()
        startModelLoading()
        if let output = Self.uiTestOutput {
            Task { exit(await UITest.run(app: self, output: output)) }
            return
        }
        startUpdateChecks()

        if !autostart {
            ApplicationsMover.offerIfNeeded()
            if !settings.autostartInitialized && Bundle.main.bundleURL.pathExtension == "app" {
                LoginItem.setEnabled(true) // like the Windows installer's ticked «Запускати разом з Windows»
                settings.autostartInitialized = true
                settings.save()
            }
            openGallery()
            if !settings.permissionsGuideShown || !Permissions.screenGranted || Permissions.microphoneUndecided {
                showPermissions()
            }
        }
        if WhisperService.isModelDownloaded(whisper.selectedModel.id) {
            ToastCenter.shared.showToast("ScreenVoicer працює в рядку меню",
                                         "\(Self.hotkeyText) — знімок екрана, затисніть Пробіл — голосовий коментар.", .info, 4000)
        }
    }

    /// Another copy is running: ask it to show its gallery instead.
    private func acquireSingleInstance() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleIdentifier)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(Self.showGalleryNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            return false
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showGalleryNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openGallery() }
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openGallery()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { cleanup() }

    private func initializeServices() {
        settings = Settings()
        history = HistoryService(settings: settings)
        audio = AudioRecorder()
        audio.preferredMicrophone = settings.selectedMicrophone
        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.overlay?.levelChanged(level) }
        }
        if settings.model == nil {
            settings.model = WhisperModels.base.id // fresh install: small download first, a better model is offered once a GPU shows up
        }
        whisper = WhisperService(language: settings.language, modelId: settings.model, useGpu: settings.useGpu)
    }

    private func registerHotkey() {
        hotkey.onPressed = { [weak self] in self?.triggerCapture(.hotkey) }
        var parsed = HotkeyGesture.parse(settings.hotkey)
        if parsed == nil {
            // also the lone Insert of 1.11 (the owner went back to ⌥⇧S in 1.12)
            Log.info("[Hotkey] '\(settings.hotkey)' is not a valid shortcut any more, back to \(Settings.defaultHotkey).")
            parsed = HotkeyGesture.parse(Settings.defaultHotkey)
            settings.hotkey = Settings.defaultHotkey
            settings.save()
        }
        let gesture = parsed!
        Self.hotkeyText = gesture.displayText
        if !hotkey.register(gesture) {
            var options = ToastOptions(title: "Гаряча клавіша зайнята",
                                       message: "\(Self.hotkeyText) вже використовує інша програма. Оберіть іншу комбінацію.",
                                       kind: .warning, durationMs: 9000)
            options.actionText = "Змінити"
            options.onAction = { [weak self] in self?.openHotkeySettings() }
            ToastCenter.shared.show(options)
        }
    }

    private func startModelLoading() {
        whisper.onChange = { [weak self] in self?.modelStateChanged() }
        let model = whisper.selectedModel
        if !WhisperService.isModelDownloaded(model.id) {
            ToastCenter.shared.showToast("Готую розпізнавання голосу",
                                         "Одноразово завантажую розпізнавання «\(model.title)» (\(model.sizeMb) МБ). Скриншоти можна робити вже зараз.",
                                         .info, 8000)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.whisper.ensureModelLoaded() }
        }
    }

    private func modelStateChanged() {
        updateStatusItem()
        overlay?.modelStateChanged()
        offerAccurateModelOnce()

        let state = whisper.state
        if state == lastReportedState { return }
        lastReportedState = state
        switch state {
        case .downloading:
            modelWasDownloading = true
        case .ready where modelWasDownloading:
            modelWasDownloading = false
            ToastCenter.shared.showToast("Розпізнавання голосу готове", "Затисніть Пробіл у вікні знімка, щоб надиктувати коментар.", .success, 5000)
        case .failed:
            var options = ToastOptions(title: "Розпізнавання голосу недоступне", message: whisper.lastError ?? "Невідома помилка.",
                                       kind: .error, durationMs: 9000)
            options.actionText = "Повторити"
            options.onAction = { [weak self] in
                self?.lastReportedState = .notLoaded
                Task { await self?.whisper.ensureModelLoaded() }
            }
            ToastCenter.shared.show(options)
        default:
            break
        }
    }

    /// With a GPU the accurate model is as fast as the small one on a CPU: suggest it once.
    private func offerAccurateModelOnce() {
        guard whisper.isRunningOnGpu, !settings.modelHintShown, whisper.activeModel == WhisperModels.base else { return }
        settings.modelHintShown = true
        settings.save()
        var options = ToastOptions(
            title: "Знайдено відеокарту \(whisper.gpuName ?? "")",
            message: "Можна увімкнути розпізнавання «\(WhisperModels.small.title)» (\(WhisperModels.small.sizeMb) МБ): з відеокартою воно так само швидке, а розуміє краще.",
            kind: .info, durationMs: 12000)
        options.actionText = "Увімкнути"
        options.onAction = { [weak self] in self?.switchModel(WhisperModels.small) }
        ToastCenter.shared.show(options)
    }

    private func switchModel(_ model: WhisperModelInfo) {
        guard whisper.selectedModel != model else { return }
        settings.model = model.id
        settings.save()
        let needsDownload = !WhisperService.isModelDownloaded(model.id)
        ToastCenter.shared.showToast("Розпізнавання «\(model.title)»",
                                     needsDownload ? "Завантажую \(model.sizeMb) МБ… Поки що працює попереднє розпізнавання." : "Перемикаю розпізнавання…",
                                     .info, 4000)
        Task {
            if await whisper.switchModel(model.id) {
                let place = whisper.isRunningOnGpu ? "на відеокарті" : "на процесорі"
                ToastCenter.shared.showToast("Розпізнавання «\(model.title)» готове", "\(model.hint.prefix(1).uppercased() + model.hint.dropFirst()). Працює \(place).", .success, 5000)
            } else {
                settings.model = whisper.selectedModel.id // the service kept the previous model
                settings.save()
                ToastCenter.shared.showToast("Не вдалося змінити розпізнавання", whisper.lastError ?? "Невідома помилка.", .error, 8000)
            }
            updateStatusItem()
        }
    }

    // MARK: - Main menu (Edit shortcuts in text fields need it; shown while the gallery is open)

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ScreenVoicer")
        appMenu.addItem(withTitle: "Про ScreenVoicer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Сховати ScreenVoicer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Закрити ScreenVoicer", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Редагування")
        edit.addItem(withTitle: "Скасувати", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторити", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вирізати", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставити", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Вибрати все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Вікно")
        window.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Закрити", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func quitFromMenu() { quit() }

    // MARK: - Menu bar item

    private func initializeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Brand.menuBarImage()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        trayMenuModel.host = self
        trayMenuModel.close = { [weak self] in self?.trayMenu?.closeMenu() }
        updateStatusItem()
    }

    /// A click on the icon is the quickest way to a screenshot; the menu lives on the right button (or ⌃-click).
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true
        statusItemClick(menu: wantsMenu)
    }

    private func statusItemClick(menu wantsMenu: Bool) {
        if wantsMenu {
            toggleTrayMenu()
            return
        }
        if let menu = trayMenu, !menu.isClosing {
            menu.closeMenu()
            return
        }
        // the click that closed the menu (by moving focus) is not a capture request
        if Date().timeIntervalSince(trayMenuClosedAt) < 0.25 { return }
        triggerCapture(.trayClick)
    }

    /// The glass menu (TrayMenu.swift); a second click on the icon closes it.
    private func toggleTrayMenu() {
        if let menu = trayMenu, !menu.isClosing {
            menu.closeMenu()
            return
        }
        // clicking the icon while the menu is open first closes it (focus moves): don't reopen on that click
        if Date().timeIntervalSince(trayMenuClosedAt) < 0.25 { return }
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let itemFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let menu = TrayMenuPanel(model: trayMenuModel)
        trayMenuModel.dropdown = nil
        trayMenuModel.aboutOpen = false
        menu.onClosed = { [weak self, weak menu] in
            guard let self else { return }
            self.trayMenuClosedAt = Date()
            if self.trayMenu === menu { self.trayMenu = nil }
        }
        trayMenu = menu
        menu.show(under: itemFrame, on: buttonWindow.screen ?? NSScreen.screens[0])
    }

    private func menuStateChanged() {
        if trayMenu != nil { trayMenuModel.refresh() }
    }

    private func updateStatusItem() {
        guard let statusItem, let whisper else { return }
        let tip: String
        switch whisper.state {
        case .downloading: tip = "ScreenVoicer — готую розпізнавання \(Formats.percent(whisper.downloadProgress))"
        case .failed: tip = "ScreenVoicer — голос недоступний"
        default: tip = "ScreenVoicer\nКлік або \(Self.hotkeyText) — знімок, правий клік — меню"
        }
        statusItem.button?.toolTip = tip
        menuStateChanged()
    }

    // MARK: - MenuHost

    var captureHotkey: String { Self.hotkeyText }
    var appVersion: String { AppInfo.version }
    var screenshotCount: Int { history?.cachedCount ?? 0 }
    func microphones() -> [MicrophoneInfo] { audio?.microphones() ?? [] }
    var selectedMicrophone: String { settings?.selectedMicrophone ?? "" }
    var canPlayLastRecording: Bool { (audio?.hasLastRecording ?? false) && !(audio?.isRecording ?? false) }
    var voiceLanguage: String { settings?.language ?? "uk" }
    var selectedModel: WhisperModelInfo { whisper?.selectedModel ?? WhisperModels.base }
    var useGpu: Bool { settings?.useGpu ?? true }
    var gpuAvailable: Bool { whisper?.isGpuRuntimeAvailable ?? false }
    var gpuName: String? { whisper?.gpuName }
    var autostartEnabled: Bool { LoginItem.isEnabled() }
    var updateVersion: String? { update?.version.description }
    var updateProgress: Double? { updateProgressValue }

    var voiceStatus: (text: String, kind: TrayStatusKind) {
        guard let t = whisper else { return ("Запускаюсь…", .busy) }
        let place = t.isRunningOnGpu ? (t.gpuName ?? "відеокарта") : "процесор"
        switch t.state {
        case .ready:
            if let next = t.downloadingModel {
                return ("Завантажую «\(next.title)»: \(Formats.percent(t.downloadProgress))", .busy)
            }
            return ("Голос готовий · \(t.activeModel?.title ?? "") · \(place)", .ready)
        case .downloading:
            return ("Завантажую розпізнавання «\(t.downloadingModel?.title ?? "")»: \(Formats.percent(t.downloadProgress))", .busy)
        case .failed:
            return ("Голос недоступний — відкрийте «Розпізнавання»", .error)
        default:
            return ("Розпізнавання запускається…", .busy)
        }
    }

    var aboutText: String {
        let model = whisper?.activeModel?.title ?? "—"
        let place = whisper?.isRunningOnGpu == true ? (whisper?.gpuName ?? "відеокарті") : "процесорі"
        return "ScreenVoicer \(AppInfo.version) — скриншоти з голосовими коментарями для баг-репортів і AI-асистентів.\n"
            + "Розпізнавання: «\(model)», офлайн, на \(place).\n"
            + "Скриншоти: \(Paths.pretty(settings?.outputDirectory ?? ""))"
    }

    func capture() { triggerCapture(.menu) }

    func selectMicrophone(_ microphone: MicrophoneInfo) {
        settings.selectedMicrophone = microphone.uid
        settings.save()
        audio.preferredMicrophone = microphone.uid
        ToastCenter.shared.showToast("Мікрофон змінено", microphone.displayName, .success, 2500)
    }

    func playLastRecording() { audio.playLast() }

    func setVoiceLanguage(_ code: String) {
        guard let language = Self.languages.first(where: { $0.0 == code }), settings.language != code else { return }
        settings.language = code
        settings.save()
        whisper.language = code
        ToastCenter.shared.showToast("Мова голосових коментарів", language.1, .success, 2500)
        menuStateChanged()
    }

    func selectModel(_ model: WhisperModelInfo) { switchModel(model) }

    func setUseGpu(_ on: Bool) {
        settings.useGpu = on
        settings.save()
        Task { await whisper.setUseGpu(on) }
        ToastCenter.shared.showToast("Розпізнавання голосу", on ? "Переношу на відеокарту…" : "Тепер працює на процесорі.", .success, 3000)
    }

    func setAutostart(_ on: Bool) {
        if LoginItem.setEnabled(on) {
            ToastCenter.shared.showToast("ScreenVoicer", on ? "Автозапуск увімкнено." : "Автозапуск вимкнено.", .success, 2500)
        } else {
            ToastCenter.shared.showToast("Автозапуск", "Не вдалося змінити налаштування автозапуску.", .error)
        }
    }

    func openLog() { openFolder(Log.directory) }
    func openModelsFolder() { openFolder(Paths.models) }

    func openScreenshotsFolder() {
        openFolder(URL(fileURLWithPath: settings?.outputDirectory ?? Paths.defaultScreenshots.path, isDirectory: true))
    }

    private func openFolder(_ url: URL) {
        Paths.ensure(url)
        if !NSWorkspace.shared.open(url) {
            ToastCenter.shared.showToast("Не вдалося відкрити папку", url.path, .error)
        }
    }

    func quit() {
        cleanup()
        NSApp.terminate(nil)
    }

    // MARK: - Hotkey dialog

    func openHotkeySettings() {
        if let hotkeyWindow {
            hotkeyWindow.activate()
            return
        }
        guard let current = HotkeyGesture.parse(settings.hotkey) ?? HotkeyGesture.parse(Settings.defaultHotkey) else { return }
        // while the dialog is open the current shortcut must not fire, so it can be pressed and re-assigned
        hotkey.unregister()
        let window = HotkeyWindowController(current: current) { [weak self] gesture in
            guard let self, self.hotkey.register(gesture) else { return false }
            Self.hotkeyText = gesture.displayText
            self.settings.hotkey = gesture.storageText
            self.settings.save()
            self.updateStatusItem()
            ToastCenter.shared.showToast("Гаряча клавіша змінена", "Тепер знімок — \(Self.hotkeyText).", .success, 3500)
            return true
        }
        window.onClosed = { [weak self] in
            guard let self else { return }
            self.hotkeyWindow = nil
            if !self.hotkey.isRegistered, let previous = HotkeyGesture.parse(self.settings.hotkey) {
                _ = self.hotkey.register(previous) // cancelled: restore the old shortcut
            }
        }
        hotkeyWindow = window
        window.show()
    }

    // MARK: - Permissions (macOS only)

    private func showPermissions() {
        if let permissionsWindow {
            permissionsWindow.show()
            return
        }
        let window = PermissionsWindowController()
        window.model.restart = { [weak self] in self?.restart() }
        window.onClosed = { [weak self] in
            guard let self else { return }
            self.permissionsWindow = nil
            self.settings.permissionsGuideShown = true
            self.settings.save()
        }
        permissionsWindow = window
        window.show()
    }

    /// Starts a fresh copy once this one has quit (macOS applies new screen access only after a restart).
    private func restart() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? process.run()
        quit()
    }

    // MARK: - Capture

    private func triggerCapture(_ trigger: CaptureTrigger) {
        if let overlay {
            overlay.bringToFront()
            return
        }
        if captureStarting { return }
        guard Permissions.screenGranted else {
            ScreenCaptureService.requestPermission()
            showPermissions()
            return
        }
        captureStarting = true

        Task {
            defer { captureStarting = false }
            var hidGallery = false
            if trigger == .gallery, let gallery, gallery.isVisible {
                gallery.hide()
                hidGallery = true
            }
            trayMenu?.closeMenu()

            // toasts and the menu must be gone from the screen first, or they end up in the screenshot
            let hadToasts = ToastCenter.shared.hideAll()
            let settleMs: UInt64
            switch trigger {
            case .hotkey: settleMs = hadToasts ? 120 : 0
            case .trayClick: settleMs = hadToasts ? 150 : 120 // the icon's highlight has to go first
            case .delayed: settleMs = hadToasts ? 150 : 60
            default: settleMs = 280
            }
            if settleMs > 0 { try? await Task.sleep(nanoseconds: settleMs * 1_000_000) }

            let started = Date()
            do {
                let capture = try await ScreenCaptureService.captureScreenUnderCursor()
                let captureMs = Int(Date().timeIntervalSince(started) * 1000)
                let overlay = OverlayController(
                    capture: capture, audio: audio, whisper: whisper, settings: settings, history: history,
                    openGallery: { [weak self] in self?.openGallery() },
                    startDelayedCapture: { [weak self] seconds in self?.triggerDelayedCapture(seconds) },
                    shareItem: { [weak self] item in self?.shareFromToast(item) })
                overlay.onClosed = { [weak self] in
                    self?.overlay = nil
                    if hidGallery { self?.gallery?.show() }
                }
                self.overlay = overlay
                overlay.show()
                Log.info("[Capture] \(trigger): \(capture.image.width)x\(capture.image.height) captured in \(captureMs) ms, overlay in \(Int(Date().timeIntervalSince(started) * 1000) - captureMs) ms.")
            } catch let error as ScreenCaptureService.CaptureError where error.needsPermission {
                if hidGallery { gallery?.show() }
                showPermissions()
            } catch {
                Log.error("[App] Screen capture failed", error)
                ToastCenter.shared.showToast("Не вдалося зробити знімок", error.localizedDescription, .error)
                if hidGallery { gallery?.show() }
            }
        }
    }

    private func triggerDelayedCapture(_ seconds: Int) {
        if let overlay {
            overlay.bringToFront()
            return
        }
        Task {
            if await CountdownController().run(seconds: seconds) {
                triggerCapture(.delayed)
            }
        }
    }

    // MARK: - Gallery

    func openGallery() {
        guard let history, let settings else { return }
        if gallery == nil {
            let model = GalleryModel(history: history)
            model.hotkeyText = { Self.hotkeyText }
            model.startCapture = { [weak self] in self?.triggerCapture(.gallery) }
            model.share = { [weak self] items in await self?.createShare(items) }
            model.unshare = { [weak self] item in await self?.deleteShare(item) ?? false }
            model.openFolder = { [weak self] in self?.openFolder(URL(fileURLWithPath: settings.outputDirectory, isDirectory: true)) }
            let controller = GalleryWindowController(model: model)
            controller.onClosed = { [weak self] in self?.gallery = nil }
            gallery = controller
        }
        gallery?.bringToFront()
    }

    // MARK: - Share links

    /// Uploads the screenshots (oldest first) behind one link, remembers it and copies it.
    private func createShare(_ items: [ScreenshotHistoryItem]) async -> ShareResult? {
        guard !items.isEmpty else { return nil }
        do {
            let ordered = items.sorted { $0.createdAt < $1.createdAt }
            let share = try await ShareService.create(ordered)
            await history.setShare(ids: Set(ordered.map(\.id)), share: share)
            Clipboard.copy(share.url)
            return share
        } catch {
            Log.warn("[Share] Could not create a link", error)
            ToastCenter.shared.showToast("Не вдалося створити посилання", error.localizedDescription, .error, 7000)
            return nil
        }
    }

    /// Deletes the link (for every screenshot that shares it) from the server and the history.
    private func deleteShare(_ item: ScreenshotHistoryItem) async -> Bool {
        guard let id = item.shareId, let token = item.shareDeleteToken else { return false }
        do {
            try await ShareService.delete(id: id, deleteToken: token)
            let all = await history.all()
            await history.setShare(ids: Set(all.filter { $0.shareId == id }.map(\.id)), share: nil)
            return true
        } catch {
            Log.warn("[Share] Could not delete a link", error)
            ToastCenter.shared.showToast("Не вдалося видалити посилання", error.localizedDescription, .error, 6000)
            return false
        }
    }

    /// «Посилання» on the toast after a screenshot.
    private func shareFromToast(_ item: ScreenshotHistoryItem) {
        Task {
            guard let share = await createShare([item]) else { return }
            ToastCenter.shared.show(ToastOptions(
                title: "Посилання скопійовано",
                message: "\(share.url) · діє до \(Formats.dayMonth.string(from: share.expiresAt))",
                kind: .success, imagePath: item.imagePath, copyText: share.url, durationMs: 6000))
        }
    }

    // MARK: - Updates

    /// First check shortly after start (not competing with the model load), then every three hours.
    private func startUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            Task { await self?.checkForUpdates(manual: false) }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdates(manual: false) }
        }
    }

    func checkForUpdates() { Task { await checkForUpdates(manual: true) } }

    private func checkForUpdates(manual: Bool) async {
        if updateProgressValue != nil || cleanedUp { return }
        do {
            update = try await UpdateService.check()
            menuStateChanged()
            guard let update else {
                if manual { ToastCenter.shared.showToast("Оновлень немає", "У вас найновіша версія \(AppInfo.version).", .success, 3500) }
                return
            }
            Log.info("[Update] \(update.version) is available (\(update.pageUrl)).")
            let version = update.version.description
            if manual || settings.updateNotifiedVersion != version {
                settings.updateNotifiedVersion = version
                settings.save()
                let summary = UpdateService.summary(update.notes)
                var options = ToastOptions(title: "Доступна версія \(version)",
                                           message: summary.isEmpty ? "Нова версія ScreenVoicer готова до встановлення." : summary,
                                           kind: .info, durationMs: 15000)
                options.actionText = "Оновити"
                options.onAction = { [weak self] in self?.installUpdate() }
                ToastCenter.shared.show(options)
            }
        } catch {
            Log.warn("[Update] Check failed", error)
            if manual { ToastCenter.shared.showToast("Не вдалося перевірити оновлення", error.localizedDescription, .warning, 6000) }
        }
    }

    /// Downloads the new version, then quits so the swap script can replace the app; it starts the new one.
    func installUpdate() {
        guard let update, updateProgressValue == nil else { return }
        updateProgressValue = 0
        menuStateChanged()
        ToastCenter.shared.showToast("Оновлення до \(update.version)",
                                     "Завантажую \(Int((Double(update.size) / 1_048_576).rounded())) МБ… Програма перезапуститься сама.", .info, 5000)
        Task {
            do {
                let zip = try await UpdateService.download(update) { [weak self] fraction in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if Int(fraction * 100) != Int((self.updateProgressValue ?? 0) * 100) {
                            self.updateProgressValue = fraction
                            self.menuStateChanged()
                        }
                    }
                }
                try UpdateService.installAfterExit(zip: zip)
                Log.info("[Update] Installing \(update.version), restarting.")
                quit()
            } catch {
                Log.error("[Update] Update failed", error)
                updateProgressValue = nil
                menuStateChanged()
                ToastCenter.shared.showToast("Не вдалося оновитися", error.localizedDescription, .error, 8000)
            }
        }
    }

    // MARK: - UI test hooks (--ui-test)

    nonisolated(unsafe) static var uiTestOutput: URL?
    var overlayForTest: OverlayController? { overlay }
    var historyForTest: HistoryService { history }
    var settingsForTest: Settings { settings }
    var isMenuOpenForTest: Bool { trayMenu.map { !$0.isClosing } ?? false }
    func openMenuForTest() { statusItemClick(menu: true) }
    func clickMenuBarIconForTest() { statusItemClick(menu: false) }
    func closeMenuForTest() { trayMenu?.closeMenu() }
    func closeGalleryForTest() { gallery?.window.close() }

    // MARK: - Exit

    private func cleanup() {
        if cleanedUp { return }
        cleanedUp = true
        Log.info("ScreenVoicer exiting.")
        overlay?.close()
        ToastCenter.shared.hideAll()
        hotkey.unregister()
        audio?.cancel()
    }
}

/// Offers to move the app into /Applications when it runs from Downloads or a translocated copy (self-update
/// and Gatekeeper both work best from there).
enum ApplicationsMover {
    @MainActor
    static func offerIfNeeded() {
        let bundle = Bundle.main.bundleURL
        let path = bundle.path
        guard bundle.pathExtension == "app" else { return }
        let inApplications = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        if inApplications { return }

        let alert = NSAlert()
        alert.messageText = "Перемістити ScreenVoicer у «Програми»?"
        alert.informativeText = "Звідти програма запускається разом із macOS і оновлюється сама."
        alert.addButton(withTitle: "Перемістити")
        alert.addButton(withTitle: "Не зараз")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let destination = URL(fileURLWithPath: "/Applications/ScreenVoicer.app")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: bundle, to: destination)
            _ = try? UpdateService.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
            if !path.contains("/AppTranslocation/") {
                try? FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 1; open \"$0\"", destination.path]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            Log.warn("[Move] Could not move the app to /Applications", error)
            let failed = NSAlert()
            failed.messageText = "Не вдалося перемістити"
            failed.informativeText = "Перетягніть ScreenVoicer у папку «Програми» у Finder вручну. (\(error.localizedDescription))"
            failed.runModal()
        }
    }
}
