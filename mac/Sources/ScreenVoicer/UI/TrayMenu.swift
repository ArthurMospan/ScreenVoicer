import AppKit
import SwiftUI

enum TrayStatusKind {
    case ready, busy, error
}

/// What the menu reads and does (ITrayMenuHost on Windows); implemented by AppDelegate.
@MainActor
protocol MenuHost: AnyObject {
    var captureHotkey: String { get }
    var appVersion: String { get }
    var voiceStatus: (text: String, kind: TrayStatusKind) { get }
    var screenshotCount: Int { get }
    func microphones() -> [MicrophoneInfo]
    var selectedMicrophone: String { get }
    var canPlayLastRecording: Bool { get }
    var voiceLanguage: String { get }
    var selectedModel: WhisperModelInfo { get }
    var useGpu: Bool { get }
    var gpuAvailable: Bool { get }
    var gpuName: String? { get }
    var autostartEnabled: Bool { get }
    var aboutText: String { get }
    /// Newer version on GitHub, or nil.
    var updateVersion: String? { get }
    /// 0…1 while the update downloads, otherwise nil.
    var updateProgress: Double? { get }

    func capture()
    func captureDelayed(_ seconds: Int)
    func openGallery()
    func openScreenshotsFolder()
    func selectMicrophone(_ microphone: MicrophoneInfo)
    func playLastRecording()
    func setVoiceLanguage(_ code: String)
    func selectModel(_ model: WhisperModelInfo)
    func setUseGpu(_ on: Bool)
    func openHotkeySettings()
    func setAutostart(_ on: Bool)
    func openLog()
    func openModelsFolder()
    func quit()
    func installUpdate()
    func checkForUpdates()
}

@MainActor
final class TrayMenuModel: ObservableObject {
    weak var host: MenuHost?
    var close: () -> Void = {}

    @Published var version = ""
    @Published var status = ""
    @Published var statusKind: TrayStatusKind = .ready
    @Published var hotkey = ""
    @Published var count = 0
    @Published var microphones: [MicrophoneInfo] = []
    @Published var selectedMicrophone = ""
    @Published var canPlayLast = false
    @Published var language = "uk"
    @Published var model = WhisperModels.base
    @Published var useGpu = true
    @Published var gpuAvailable = false
    @Published var gpuName: String?
    @Published var autostart = false
    @Published var about = ""
    @Published var updateVersion: String?
    @Published var updateProgress: Double?

    @Published var micOpen = false
    @Published var modelOpen = false
    @Published var aboutOpen = false

    func refresh() {
        guard let host else { return }
        version = host.appVersion
        (status, statusKind) = host.voiceStatus
        hotkey = host.captureHotkey
        count = host.screenshotCount
        microphones = host.microphones()
        selectedMicrophone = host.selectedMicrophone
        canPlayLast = host.canPlayLastRecording
        language = host.voiceLanguage
        model = host.selectedModel
        useGpu = host.useGpu
        gpuAvailable = host.gpuAvailable
        gpuName = host.gpuName
        autostart = host.autostartEnabled
        about = host.aboutText
        updateVersion = host.updateVersion
        updateProgress = host.updateProgress
    }

    var microphoneSummary: String {
        guard let mic = microphones.first(where: { $0.uid == selectedMicrophone }), !mic.isSystemDefault else { return "Системний" }
        return mic.displayName
    }

    /// Runs an action that leaves the menu (it closes first, like Do() on Windows).
    func run(_ action: @escaping (MenuHost) -> Void) {
        close()
        if let host { action(host) }
    }
}

/// The glass menu under the menu-bar icon. Expanded lists grow inside the panel instead of side menus.
struct TrayMenuView: View {
    @ObservedObject var model: TrayMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let update = model.updateVersion { updateBanner(update) }
            captureButton
            delayRow
            separator
            row(.gallery, "Галерея", value: model.count > 0 ? Formats.plural(model.count, "знімок", "знімки", "знімків") : nil) {
                model.run { $0.openGallery() }
            }
            row(.folder, "Папка зі скриншотами") { model.run { $0.openScreenshotsFolder() } }
            separator
            expandingRow(.mic, "Мікрофон", value: model.microphoneSummary, open: model.micOpen) {
                model.modelOpen = false
                model.micOpen.toggle()
            }
            if model.micOpen { microphoneWell }
            languageRow
            expandingRow(.chip, "Розпізнавання", value: model.model.title, open: model.modelOpen) {
                model.micOpen = false
                model.modelOpen.toggle()
            }
            if model.modelOpen { modelWell }
            row(.keyboard, "Гаряча клавіша", value: model.hotkey) { model.run { $0.openHotkeySettings() } }
            Button {
                model.host?.setAutostart(!model.autostart)
                model.refresh()
            } label: {
                HStack(spacing: 0) {
                    rowIcon(.power)
                    Text("Запуск з macOS")
                    Spacer(minLength: 8)
                    toggle(model.autostart)
                }
            }
            .buttonStyle(MenuRowStyle())
            separator
            footer
            if model.aboutOpen { aboutWell }
        }
        .padding(10)
        .frame(width: 344)
        .background(GlassBackground(cornerRadius: 18, blending: .behindWindow, tint: Color(argb: 0x8C1C1C23)))
    }

    // MARK: parts

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            BrandMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Wordmark(size: 15)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(model.status)
                        .font(Theme.font(12))
                        .foregroundColor(Theme.menuMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(model.status)
                }
            }
            Spacer(minLength: 4)
            Text(model.version)
                .font(Theme.font(11))
                .foregroundColor(Theme.menuFaint)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 3)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var statusColor: Color {
        switch model.statusKind {
        case .error: return Theme.red
        case .busy: return Theme.amber
        case .ready: return Theme.green
        }
    }

    private func updateBanner(_ version: String) -> some View {
        Button { model.host?.installUpdate() } label: {
            HStack(spacing: 0) {
                rowIcon(.spark, color: Theme.accentLight)
                Text(model.updateProgress.map { "Завантажую версію \(version)… \(Formats.percent($0))" } ?? "Доступна версія \(version)")
                    .font(Theme.font(13))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if model.updateProgress == nil {
                    Text("Оновити").font(Theme.font(12.5, .semibold)).foregroundColor(Theme.accentLight)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
        .disabled(model.updateProgress != nil)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(argb: 0x24FF8A4C)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color(argb: 0x66FFC68A), lineWidth: 1))
        .padding(.bottom, 8)
    }

    private var captureButton: some View {
        Button { model.run { $0.capture() } } label: {
            HStack(spacing: 10) {
                GlyphIcon(icon: .camera, size: 19, weight: 2.2).foregroundColor(Theme.accent)
                Text("Зробити знімок").font(Theme.font(14, .semibold))
                Spacer(minLength: 6)
                Text(model.hotkey)
                    .font(Theme.font(11.5, .semibold))
                    .foregroundColor(Color(rgb: 0x4A4A52))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(argb: 0x12000000)))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle(height: 46, horizontalPadding: 14, fontSize: 14))
    }

    private var delayRow: some View {
        HStack(spacing: 0) {
            GlyphIcon(icon: .timer, size: 15).foregroundColor(Theme.menuMuted).padding(.trailing, 7)
            Text("Із затримкою").font(Theme.font(12.5)).foregroundColor(Theme.menuMuted).padding(.trailing, 10)
            ForEach([3, 5, 10], id: \.self) { seconds in
                Button("\(seconds) с") { model.run { $0.captureDelayed(seconds) } }
                    .buttonStyle(MenuChipStyle())
                    .padding(.trailing, 6)
            }
        }
        .padding(.leading, 6)
        .padding(.top, 9)
        .padding(.bottom, 2)
    }

    private var separator: some View {
        Rectangle().fill(Color(argb: 0x17FFFFFF)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func rowIcon(_ icon: Icon, color: Color = Color(rgb: 0xD8D8DF)) -> some View {
        GlyphIcon(icon: icon, size: 18).foregroundColor(color).padding(.trailing, 11)
    }

    private func row(_ icon: Icon, _ title: String, value: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                rowIcon(icon)
                Text(title)
                Spacer(minLength: 8)
                if let value {
                    Text(value).font(Theme.font(12.5)).foregroundColor(Theme.menuMuted).lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    private func expandingRow(_ icon: Icon, _ title: String, value: String, open: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                rowIcon(icon)
                Text(title)
                Spacer(minLength: 8)
                Text(value).font(Theme.font(12.5)).foregroundColor(Theme.menuMuted).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .trailing)
                GlyphIcon(icon: .chevron, size: 12, weight: 2.6)
                    .foregroundColor(Theme.menuMuted)
                    .opacity(0.7)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .padding(.leading, 5)
                    .padding(.top, 1)
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    private func well<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(argb: 0x24000000)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color(argb: 0x0FFFFFFF), lineWidth: 1))
            .padding(.leading, 38)
            .padding(.trailing, 4)
            .padding(.bottom, 4)
    }

    private var microphoneWell: some View {
        well {
            ForEach(model.microphones) { mic in
                optionRow(mic.displayName, checked: mic.uid == model.selectedMicrophone) {
                    model.host?.selectMicrophone(mic)
                    model.refresh()
                }
            }
            optionRow("Прослухати останній запис", checked: false, icon: .play) {
                model.host?.playLastRecording()
            }
            .disabled(!model.canPlayLast)
            .help("Так звучить ваш голос для розпізнавання. Якщо глухо чи тихо — справа в мікрофоні або його підключенні.")
        }
    }

    private var modelWell: some View {
        well {
            ForEach(WhisperModels.all) { info in
                optionRow(info.title,
                          detail: "\(info.id) · \(info.sizeMb) МБ" + (info.needsGpu && !model.gpuAvailable ? " · повільно без відеокарти" : ""),
                          checked: info == model.model) {
                    model.host?.selectModel(info)
                    model.refresh()
                }
                .help(info.hint)
            }
            Rectangle().fill(Color(argb: 0x17FFFFFF)).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
            optionRow(model.gpuName.map { "Відеокарта · \($0)" } ?? "Використовувати відеокарту",
                      checked: model.useGpu, icon: .gpu, showCheck: true) {
                model.host?.setUseGpu(!model.useGpu)
                model.refresh()
            }
            .disabled(!(model.gpuAvailable || model.useGpu))
        }
    }

    private func optionRow(_ title: String, detail: String? = nil, checked: Bool, icon: Icon? = nil, showCheck: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: detail == nil ? .center : .top, spacing: 9) {
                Group {
                    if checked && (icon == nil || showCheck) {
                        GlyphIcon(icon: .check, size: 15, weight: 2.2).foregroundColor(Theme.accent)
                    } else if let icon {
                        GlyphIcon(icon: icon, size: 15, weight: 1.9).foregroundColor(Theme.menuMuted)
                    } else {
                        Color.clear.frame(width: 15, height: 15)
                    }
                }
                .padding(.top, detail == nil ? 0 : 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.font(12.5, checked ? .semibold : .regular))
                        .foregroundColor(checked ? .white : Theme.ink)
                        .lineLimit(1)
                    if let detail {
                        Text(detail).font(Theme.font(11.5)).foregroundColor(Theme.menuMuted).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    private var languageRow: some View {
        HStack(spacing: 0) {
            rowIcon(.globe)
            Text("Мова голосу").font(Theme.font(13.5)).foregroundColor(Theme.glassText)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                ForEach(Self.languages.indices, id: \.self) { index in
                    let (code, label, tip) = Self.languages[index]
                    Button(label) {
                        model.host?.setVoiceLanguage(code)
                        model.refresh()
                    }
                    .buttonStyle(MenuChipStyle(on: model.language == code))
                    .help(tip)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(argb: 0x0FFFFFFF)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(argb: 0x14FFFFFF), lineWidth: 1))
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
    }

    private static let languages = [("uk", "УКР", "Українська"), ("en", "ENG", "English"), ("auto", "Авто", "Автовизначення (повільніше)")]

    private func toggle(_ on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 10.5, style: .continuous).fill(on ? Theme.accent : Color(argb: 0x29FFFFFF))
            Circle().fill(.white).frame(width: 15, height: 15).padding(.horizontal, 3)
        }
        .frame(width: 36, height: 21)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button { model.aboutOpen.toggle() } label: {
                HStack(spacing: 8) {
                    GlyphIcon(icon: .info, size: 18).foregroundColor(Theme.menuMuted)
                    Text("Про програму").font(Theme.font(13)).foregroundColor(Theme.menuMuted)
                }
            }
            .buttonStyle(MenuRowStyle())
            .fixedSize()
            Spacer(minLength: 0)
            Button { model.run { $0.quit() } } label: {
                HStack(spacing: 8) {
                    GlyphIcon(icon: .exit, size: 18).foregroundColor(Theme.menuMuted)
                    Text("Вийти").font(Theme.font(13)).foregroundColor(Theme.menuMuted)
                }
            }
            .buttonStyle(MenuRowStyle())
            .fixedSize()
        }
    }

    private var aboutWell: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.about)
                .font(Theme.font(12))
                .foregroundColor(Color(rgb: 0xD2D2DA))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Button("Перевірити оновлення") { model.host?.checkForUpdates() }.buttonStyle(MenuChipStyle())
                Button("Журнал") { model.run { $0.openLog() } }.buttonStyle(MenuChipStyle())
                Button("Моделі") { model.run { $0.openModelsFolder() } }.buttonStyle(MenuChipStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(argb: 0x24000000)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color(argb: 0x0FFFFFFF), lineWidth: 1))
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

/// The panel that holds the menu; anchored under the status item, it grows downwards.
@MainActor
final class TrayMenuPanel: NSPanel {
    private let model: TrayMenuModel
    private var host: NSHostingView<AnyView>!
    private var anchorTop: CGFloat = 0
    private var anchorX: CGFloat = 0
    private var mouseMonitor: Any?
    private(set) var isClosing = false
    var onClosed: (() -> Void)?

    init(model: TrayMenuModel) {
        self.model = model
        super.init(contentRect: CGRect(x: 0, y: 0, width: 344, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false

        let root = TrayMenuView(model: model)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { [weak self] geo in
                Color.clear
                    .onAppear { self?.resize(to: geo.size) }
                    .onChange(of: geo.size) { self?.resize(to: $0) }
            })
        host = NSHostingView(rootView: AnyView(root))
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closeMenu() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { closeMenu() }

    override func resignKey() {
        super.resignKey()
        closeMenu()
    }

    /// Places the menu under the status item and fades it in.
    func show(under itemFrame: CGRect, on screen: NSScreen) {
        model.refresh()
        let size = host.fittingSize
        let area = screen.visibleFrame
        anchorTop = itemFrame.minY - 6
        anchorX = min(max(itemFrame.midX - size.width / 2, area.minX + 6), area.maxX - size.width - 6)
        setFrame(CGRect(x: anchorX, y: anchorTop - size.height + 10, width: size.width, height: size.height), display: true)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(CGRect(x: anchorX, y: anchorTop - size.height, width: size.width, height: size.height), display: true)
        }
        // A click in any other app closes the menu (global mouse monitors need no permission).
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closeMenu() }
        }
    }

    private func resize(to size: CGSize) {
        guard isVisible, !isClosing, size.height > 0 else { return }
        setFrame(CGRect(x: anchorX, y: anchorTop - size.height, width: size.width, height: size.height), display: true)
    }

    func closeMenu() {
        if isClosing { return }
        isClosing = true
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        orderOut(nil) // gone at once (a capture may follow)
        DispatchQueue.main.async { [weak self] in
            self?.close()
            self?.onClosed?()
        }
    }
}
