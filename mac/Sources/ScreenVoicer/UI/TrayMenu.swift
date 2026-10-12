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

    /// The open dropdown list, drawn over the menu (TrayMenuWindow's popups on Windows).
    @Published var dropdown: TrayDropdown?
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

enum TrayDropdown: Hashable {
    case mic
}

/// Where each dropdown row sits, so its list can open right under it.
struct DropdownAnchorKey: PreferenceKey {
    static var defaultValue: [TrayDropdown: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TrayDropdown: Anchor<CGRect>], nextValue: () -> [TrayDropdown: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// An open dropdown: the list over the menu under its row (above the row when the menu ends too soon);
/// a click anywhere else in the menu closes it.
private struct DropdownLayer<Content: View>: View {
    let row: CGRect
    let menuHeight: CGFloat
    let close: () -> Void
    let content: Content
    @State private var listHeight: CGFloat = 0

    init(row: CGRect, menuHeight: CGFloat, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.row = row
        self.menuHeight = menuHeight
        self.close = close
        self.content = content()
    }

    var body: some View {
        let below = row.maxY + 2
        let y = below + listHeight <= menuHeight - 6 ? below : max(6, row.minY - 2 - listHeight)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(4)
                .frame(width: row.width)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(argb: 0xFF222229)))
                .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 6)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { listHeight = geo.size.height }
                        .onChange(of: geo.size.height) { listHeight = $0 }
                })
                .opacity(listHeight > 0 ? 1 : 0)
                .offset(x: row.minX, y: y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The glass menu under the menu-bar icon. The microphone list opens as a dropdown over it.
struct TrayMenuView: View {
    @ObservedObject var model: TrayMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let update = model.updateVersion { updateBanner(update) }
            captureButton
            separator
            row(.gallery, "Галерея", value: model.count > 0 ? Formats.plural(model.count, "знімок", "знімки", "знімків") : nil) {
                model.run { $0.openGallery() }
            }
            row(.folder, "Папка зі скриншотами") { model.run { $0.openScreenshotsFolder() } }
            separator
            dropdownRow(.mic, .mic, "Мікрофон", value: model.microphoneSummary)
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
        .background(GlassBackground(cornerRadius: 18, blending: .behindWindow, tint: Color(argb: 0x8C1C1C23), edge: false))
        .overlayPreferenceValue(DropdownAnchorKey.self) { anchors in
            GeometryReader { geo in
                if let open = model.dropdown, let anchor = anchors[open] {
                    DropdownLayer(row: geo[anchor], menuHeight: geo.size.height, close: { model.dropdown = nil }) {
                        dropdownContent(open)
                    }
                }
            }
        }
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
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(argb: 0x2EFF8A4C)))
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

    /// A row that opens a dropdown list over the menu (the menu itself never grows).
    private func dropdownRow(_ kind: TrayDropdown, _ icon: Icon, _ title: String, value: String) -> some View {
        Button { model.dropdown = model.dropdown == kind ? nil : kind } label: {
            HStack(spacing: 0) {
                rowIcon(icon)
                Text(title)
                Spacer(minLength: 8)
                Text(value).font(Theme.font(12.5)).foregroundColor(Theme.menuMuted).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .trailing)
                GlyphIcon(icon: .chevron, size: 12, weight: 2.6)
                    .foregroundColor(Theme.menuMuted)
                    .opacity(0.7)
                    .rotationEffect(.degrees(model.dropdown == kind ? 180 : 0))
                    .padding(.leading, 5)
                    .padding(.top, 1)
            }
        }
        .buttonStyle(MenuRowStyle())
        .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { [kind: $0] }
    }

    @ViewBuilder
    private func dropdownContent(_ kind: TrayDropdown) -> some View {
        switch kind {
        case .mic:
            ForEach(model.microphones) { mic in
                optionRow(mic.displayName, checked: mic.uid == model.selectedMicrophone) {
                    model.host?.selectMicrophone(mic)
                    model.dropdown = nil
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
                    Text("Закрити").font(Theme.font(13)).foregroundColor(Theme.menuMuted)
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(argb: 0x24000000)))
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
