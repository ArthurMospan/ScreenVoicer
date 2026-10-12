import AppKit
import ImageIO
import SwiftUI

enum ToastKind {
    case info, success, warning, error
}

/// The same options as ToastOptions in INotificationService.cs.
struct ToastOptions {
    var title = "ScreenVoicer"
    var message = ""
    var kind: ToastKind = .info
    /// Screenshot to show as a thumbnail; enables «Відкрити».
    var imagePath: String?
    /// Text «Копіювати» puts on the clipboard again (with the image, if any).
    var copyText: String?
    var onOpenGallery: (() -> Void)?
    /// Optional extra button (e.g. «Повторити»).
    var actionText: String?
    var onAction: (() -> Void)?
    /// Copy buttons before the action button (the saved-screenshot toast: «З підписом», «Текст»).
    var copyButtons: [ToastCopyButton] = []
    /// «Відкрити» next to the thumbnail; the thumbnail opens the image anyway.
    var showOpenButton = true
    var durationMs = 4500
}

/// A toast button that copies something and keeps the toast open, showing «✓» on itself.
struct ToastCopyButton {
    let text: String
    let copy: () -> Bool
}

/// Toasts in a bottom-right stack, newest at the bottom (NotificationService.cs).
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()
    private static let maxVisible = 3
    private static let gap: CGFloat = 4

    private var toasts: [ToastPanel] = []

    func showToast(_ title: String, _ message: String, _ kind: ToastKind = .info, _ durationMs: Int = 4500) {
        show(ToastOptions(title: title, message: message, kind: kind, durationMs: durationMs))
    }

    func show(_ options: ToastOptions) {
        for old in toasts.prefix(max(0, toasts.count - Self.maxVisible + 1)) {
            old.dismiss()
        }
        let toast = ToastPanel(options: options)
        toast.onClosed = { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.toasts.removeAll { $0 === toast }
            self.arrange(animate: true)
        }
        toasts.append(toast)
        arrange(animate: true)
    }

    /// Instantly closes all toasts (before a screenshot, so they don't end up in it). True if any was shown.
    @discardableResult
    func hideAll() -> Bool {
        let any = !toasts.isEmpty
        for toast in toasts { toast.closeImmediately() }
        toasts.removeAll()
        return any
    }

    private func arrange(animate: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        var bottom = area.minY + 8
        for toast in toasts.reversed() where !toast.isClosing {
            let size = toast.frame.size
            toast.move(to: CGPoint(x: area.maxX - size.width - 8, y: bottom), animate: animate)
            bottom += size.height + Self.gap
        }
    }
}

final class ToastState: ObservableObject {
    let options: ToastOptions
    let duration: TimeInterval
    @Published var copyLabel = "Копіювати"
    /// The copy button pressed last and whether it worked («✓ З підписом» / «Буфер зайнятий»).
    @Published var copiedButton: (index: Int, ok: Bool)?
    @Published var paused = false
    var deadline: Date
    var pausedRemaining: TimeInterval = 0

    init(options: ToastOptions) {
        self.options = options
        duration = max(1.5, Double(options.durationMs) / 1000)
        deadline = Date().addingTimeInterval(duration)
    }

    func remaining(at date: Date) -> TimeInterval {
        paused ? pausedRemaining : max(0, deadline.timeIntervalSince(date))
    }
}

@MainActor
final class ToastPanel: NSPanel {
    private let state: ToastState
    private var host: NSHostingView<ToastView>!
    private var timer: Timer?
    private var shown = false
    private(set) var isClosing = false
    var onClosed: (() -> Void)?

    init(options: ToastOptions) {
        state = ToastState(options: options)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 376, height: 80), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = 0

        let view = ToastView(state: state, actions: ToastActions(
            close: { [weak self] in self?.dismiss() },
            copy: { [weak self] in self?.copy() },
            copyButton: { [weak self] index in self?.runCopyButton(index) },
            openImage: { [weak self] in self?.openImage() },
            action: { [weak self] in
                self?.state.options.onAction?()
                self?.dismiss()
            },
            gallery: { [weak self] in
                self?.state.options.onOpenGallery?()
                self?.dismiss()
            },
            hover: { [weak self] inside in self?.setPaused(inside) }))
        host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        contentView = host
        setContentSize(size)
    }

    override var canBecomeKey: Bool { false }

    func move(to origin: CGPoint, animate: Bool) {
        if !shown {
            shown = true
            setFrameOrigin(CGPoint(x: origin.x, y: origin.y - 16))
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
                animator().setFrameOrigin(origin)
            }
            startTimer()
            return
        }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                animator().setFrameOrigin(origin)
            }
        } else {
            setFrameOrigin(origin)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.state.paused, !self.isClosing else { return }
                if self.state.remaining(at: Date()) <= 0 { self.dismiss() }
            }
        }
    }

    private func setPaused(_ paused: Bool) {
        if isClosing || paused == state.paused { return }
        if paused {
            state.pausedRemaining = state.remaining(at: Date())
        } else {
            state.deadline = Date().addingTimeInterval(state.pausedRemaining)
        }
        state.paused = paused
    }

    func dismiss() {
        if isClosing { return }
        isClosing = true
        timer?.invalidate()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in self?.finish() }
        })
    }

    func closeImmediately() {
        isClosing = true
        timer?.invalidate()
        orderOut(nil)
        close()
    }

    private func finish() {
        orderOut(nil)
        close()
        onClosed?()
    }

    private func copy() {
        guard let text = state.options.copyText else { return }
        state.copyLabel = Clipboard.copy(text, imagePath: state.options.imagePath) ? "✓ Скопійовано" : "Буфер зайнятий"
    }

    private func runCopyButton(_ index: Int) {
        guard state.options.copyButtons.indices.contains(index) else { return }
        state.copiedButton = (index, state.options.copyButtons[index].copy())
    }

    private func openImage() {
        if let path = state.options.imagePath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        dismiss()
    }
}

struct ToastActions {
    let close: () -> Void
    let copy: () -> Void
    var copyButton: (Int) -> Void = { _ in }
    let openImage: () -> Void
    let action: () -> Void
    let gallery: () -> Void
    let hover: (Bool) -> Void
}

struct ToastView: View {
    @ObservedObject var state: ToastState
    let actions: ToastActions
    @State private var thumbnail: NSImage?

    init(state: ToastState, actions: ToastActions) {
        self.state = state
        self.actions = actions
        _thumbnail = State(initialValue: state.options.imagePath.flatMap { Thumbnails.load(path: $0, maxPixels: 120) })
    }

    private var options: ToastOptions { state.options }
    private var hasImage: Bool { options.imagePath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    private var hasActions: Bool {
        hasImage || !options.copyButtons.isEmpty || options.copyText != nil || options.onOpenGallery != nil || (options.onAction != nil && options.actionText != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                badge.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(options.title)
                        .font(Theme.font(13.5, .semibold))
                        .foregroundColor(Color(rgb: 0xF3F3F6))
                        .lineLimit(1)
                    if !options.message.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(options.message)
                            .font(Theme.font(12.5))
                            .foregroundColor(Color(rgb: 0xA9A9B6))
                            .lineLimit(3)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                Button(action: actions.close) { GlyphIcon(icon: .close, size: 13, weight: 2.4) }
                    .buttonStyle(GlassIconButtonStyle(width: 24, height: 24, cornerRadius: 8))
                    .foregroundColor(Color(rgb: 0x8C8C99))
                    .help("Закрити")
                    .padding(.top, -4)
            }
            .padding(.leading, 14)
            .padding(.top, 13)
            .padding(.trailing, 10)
            .padding(.bottom, 11)

            if hasActions {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if hasImage && options.showOpenButton {
                        Button("Відкрити", action: actions.openImage).buttonStyle(ChipButtonStyle())
                    }
                    ForEach(Array(options.copyButtons.enumerated()), id: \.offset) { index, button in
                        Button(copyLabel(index, button), action: { actions.copyButton(index) }).buttonStyle(ChipButtonStyle())
                    }
                    if options.copyText != nil {
                        Button(state.copyLabel, action: actions.copy).buttonStyle(ChipButtonStyle())
                    }
                    if let text = options.actionText, options.onAction != nil {
                        Button(text, action: actions.action).buttonStyle(ChipButtonStyle())
                    }
                    if options.onOpenGallery != nil {
                        Button("Галерея", action: actions.gallery)
                            .buttonStyle(PrimaryButtonStyle(height: 28, horizontalPadding: 12, fontSize: 11.5))
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }

            TimelineView(.animation(minimumInterval: 1 / 30, paused: state.paused)) { context in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Theme.accent)
                        .opacity(0.55)
                        .frame(width: geo.size.width * CGFloat(state.remaining(at: context.date) / state.duration), height: 2)
                }
                .frame(height: 2)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 1)
        }
        .frame(width: 376)
        .darkCard(cornerRadius: 16)
        .onHover(perform: actions.hover)
    }

    private func copyLabel(_ index: Int, _ button: ToastCopyButton) -> String {
        guard let last = state.copiedButton, last.index == index else { return button.text }
        return last.ok ? "✓ " + button.text : "Буфер зайнятий"
    }

    @ViewBuilder
    private var badge: some View {
        if hasImage, let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture(perform: actions.openImage)
                .onDrag { // drag the thumbnail into Telegram, Jira, a mail: the PNG file goes there
                    options.imagePath.flatMap { NSItemProvider(contentsOf: URL(fileURLWithPath: $0)) } ?? NSItemProvider()
                }
                .help("Клік — відкрити знімок, перетягніть — щоб покласти файл у чат чи задачу")
        } else if let status = kindIcon {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(rgb: status.1).opacity(0x2E / 255.0))
                GlyphIcon(icon: status.0, size: 20, weight: 2.2).foregroundColor(Color(rgb: status.1))
            }
        } else {
            BrandMark(size: 44)
        }
    }

    /// Status toasts get a tinted badge with a line icon; plain info carries the logo.
    private var kindIcon: (Icon, UInt32)? {
        switch options.kind {
        case .success: return (.check, 0x4ADE80)
        case .warning: return (.alert, 0xFBBF24)
        case .error: return (.close, 0xF87171)
        case .info: return nil
        }
    }
}

enum Thumbnails {
    /// A small decoded copy (the file is not kept open).
    static func load(path: String, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
