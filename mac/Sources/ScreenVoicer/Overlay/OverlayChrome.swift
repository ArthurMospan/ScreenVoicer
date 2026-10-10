import AppKit
import SwiftUI

enum StatusKind: Equatable {
    case idle, recording, busy, success, warning, error
}

struct OverlayStatus: Equatable {
    var text: String
    var kind: StatusKind
}

enum Flyout: Hashable {
    case tool, color, timer
}

/// What the overlay's SwiftUI chrome shows; the controller (OverlayController) owns the logic.
final class OverlayModel: ObservableObject {
    @Published var mode: CaptureMode = .rectangleRegion
    @Published var tool: Tool = .pen
    @Published var colorRGB: UInt32 = Theme.swatches[0].rgb
    @Published var thickness = 1
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var isRecording = false
    @Published var level: CGFloat = 0
    @Published var comment = ""
    @Published var commentReadOnly = false
    @Published var commentIsPreview = false
    @Published var placeholder = "Говоріть або напишіть коментар"
    @Published var status: OverlayStatus?
    @Published var openFlyout: Flyout?
    @Published var toolbarAtBottom = false
    @Published var panelsFaded = false
    @Published var hintVisible = false
    @Published var showTimer = true
    @Published var microphoneTooltip = "Обрати мікрофон"
    /// Room for the notch / menu bar on top of the display.
    @Published var topInset: CGFloat = 0

    /// Interactive areas of the chrome (toolbar, open flyout) in chrome coordinates; clicks elsewhere pass through.
    var hitRects: [CGRect] = []
    var toolbarFrame: CGRect = .zero
    var anchors: [Flyout: CGRect] = [:]
    var microphoneAnchor: CGRect = .zero
    weak var controller: OverlayController?

    var color: NSColor { NSColor(rgb: colorRGB) }
}

private let chromeSpace = "overlayChrome"

private struct HitRectsKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private struct AnchorsKey: PreferenceKey {
    static var defaultValue: [Flyout: CGRect] = [:]
    static func reduce(value: inout [Flyout: CGRect], nextValue: () -> [Flyout: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ToolbarFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct MicAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct FlyoutSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private extension View {
    func reportHitRect() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: HitRectsKey.self, value: [g.frame(in: .named(chromeSpace))])
        })
    }

    func reportAnchor(_ flyout: Flyout) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: AnchorsKey.self, value: [flyout: g.frame(in: .named(chromeSpace))])
        })
    }
}

/// The overlay's floating chrome: the one glass bar, the status pill, the hint and the flyouts.
struct OverlayChrome: View {
    @ObservedObject var model: OverlayModel
    @State private var anchors: [Flyout: CGRect] = [:]
    @State private var flyoutSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear

                if model.hintVisible {
                    HintBadge()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 8) {
                    if model.toolbarAtBottom {
                        Spacer(minLength: 0)
                        statusPill
                        toolbar
                    } else {
                        toolbar
                        statusPill
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .padding(.top, model.toolbarAtBottom ? 0 : 16 + model.topInset)
                .padding(.bottom, model.toolbarAtBottom ? 24 : 0)
                .opacity(model.panelsFaded ? 0.12 : 1)
                .animation(.easeOut(duration: model.panelsFaded ? 0.12 : 0.18), value: model.panelsFaded)

                if let flyout = model.openFlyout, let anchor = anchors[flyout] {
                    flyoutView(flyout)
                        .fixedSize()
                        .background(GeometryReader { g in Color.clear.preference(key: FlyoutSizeKey.self, value: g.size) })
                        .reportHitRect()
                        .onHover { model.controller?.flyoutHover($0) }
                        .position(flyoutCenter(anchor: anchor, container: geo.size))
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: chromeSpace)
            .onPreferenceChange(HitRectsKey.self) { model.hitRects = $0 }
            .onPreferenceChange(AnchorsKey.self) { value in
                anchors = value
                model.anchors = value
            }
            .onPreferenceChange(FlyoutSizeKey.self) { flyoutSize = $0 }
            .onPreferenceChange(ToolbarFrameKey.self) { frame in
                model.toolbarFrame = frame
                model.controller?.toolbarFrameChanged()
            }
            .onPreferenceChange(MicAnchorKey.self) { model.microphoneAnchor = $0 }
        }
        .ignoresSafeArea() // the notch inset is applied by hand (topInset), so hit rects match the window
    }

    private func flyoutCenter(anchor: CGRect, container: CGSize) -> CGPoint {
        let w = max(flyoutSize.width, 40), h = max(flyoutSize.height, 34)
        let x = min(max(anchor.midX, w / 2 + 8), max(w / 2 + 8, container.width - w / 2 - 8))
        let y = model.toolbarAtBottom ? anchor.minY - 12 - h / 2 : anchor.maxY + 12 + h / 2
        return CGPoint(x: x, y: y)
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            iconButton(.region, active: model.mode == .rectangleRegion, tip: "Виділити область") {
                model.controller?.switchMode(.rectangleRegion)
            }
            iconButton(.screen, active: model.mode == .fullScreen, tip: "Весь екран") {
                model.controller?.switchMode(.fullScreen)
            }
            if model.showTimer {
                iconButton(.timer, active: model.openFlyout == .timer,
                           tip: "Знімок із затримкою: наведіть і оберіть секунди — встигнете відкрити меню чи підказку") {
                    model.controller?.toggleFlyout(.timer)
                }
                .reportAnchor(.timer)
                .onHover { model.controller?.anchorHover(.timer, $0) }
            }

            divider

            Button { model.controller?.toggleFlyout(.tool) } label: {
                HStack(spacing: 2) {
                    GlyphIcon(icon: model.tool.icon)
                    chevron
                }
            }
            .buttonStyle(GlassIconButtonStyle(active: model.openFlyout == .tool, width: 46))
            .help("\(model.tool.tooltip) — наведіть, щоб обрати інший інструмент")
            .reportAnchor(.tool)
            .onHover { model.controller?.anchorHover(.tool, $0) }

            Button { model.controller?.toggleFlyout(.color) } label: {
                HStack(spacing: 2) {
                    Circle()
                        .fill(Color(nsColor: model.color))
                        .overlay(Circle().strokeBorder(Color(argb: 0x59FFFFFF), lineWidth: 1))
                        .frame(width: 16, height: 16)
                    chevron
                }
            }
            .buttonStyle(GlassIconButtonStyle(active: model.openFlyout == .color, width: 46))
            .help("Колір і товщина (наведіть, щоб обрати)")
            .reportAnchor(.color)
            .onHover { model.controller?.anchorHover(.color, $0) }

            iconButton(.undo, tip: "Скасувати (⌘Z)") { model.controller?.undo() }
                .disabled(!model.canUndo)
            iconButton(.redo, tip: "Повторити (⇧⌘Z)") { model.controller?.redo() }
                .disabled(!model.canRedo)

            divider

            MicButton(model: model)
            Button { model.controller?.showMicrophoneMenu() } label: { chevron.padding(.top, 1) }
                .buttonStyle(GlassIconButtonStyle(width: 16, cornerRadius: 8))
                .help(model.microphoneTooltip)
                .background(GeometryReader { g in
                    Color.clear.preference(key: MicAnchorKey.self, value: g.frame(in: .named(chromeSpace)))
                })
                .padding(.leading, -3)
                .padding(.trailing, 2)

            CommentField(model: model)
                .frame(width: 300)
                .padding(.leading, 4)
                .padding(.trailing, 6)

            Button { model.controller?.save() } label: { GlyphIcon(icon: .check, weight: 2.3) }
                .buttonStyle(SaveButtonStyle())
                .help("Зберегти PNG і скопіювати Markdown (Enter)")
            iconButton(.close, size: 16, tip: "Скасувати (Esc)") { model.controller?.cancel() }
        }
        .padding(5)
        .glassPanel(cornerRadius: 23)
        .background(GeometryReader { g in
            Color.clear.preference(key: ToolbarFrameKey.self, value: g.frame(in: .named(chromeSpace)))
        })
        .reportHitRect()
    }

    @ViewBuilder
    private var statusPill: some View {
        if let status = model.status {
            StatusPillView(status: status).allowsHitTesting(false)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(argb: 0x29FFFFFF))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 5)
    }

    private var chevron: some View {
        GlyphIcon(icon: .chevron, size: 10, weight: 2.6)
            .opacity(0.7)
            .padding(.top, 1)
    }

    private func iconButton(_ icon: Icon, active: Bool = false, size: CGFloat = 18, tip: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { GlyphIcon(icon: icon, size: size) }
            .buttonStyle(GlassIconButtonStyle(active: active))
            .help(tip)
    }

    // MARK: flyouts

    @ViewBuilder
    private func flyoutView(_ flyout: Flyout) -> some View {
        switch flyout {
        case .tool:
            HStack(spacing: 2) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    iconButton(tool.icon, active: model.tool == tool, tip: tool.tooltip) {
                        model.controller?.selectTool(tool)
                    }
                }
            }
            .padding(4)
            .glassPanel(cornerRadius: 21)
        case .color:
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(Array(Theme.swatches.enumerated()), id: \.offset) { index, swatch in
                        SwatchButton(rgb: swatch.rgb, selected: model.colorRGB == swatch.rgb) {
                            model.controller?.selectColor(swatch.rgb)
                        }
                        .help("\(swatch.name) (\(index + 1))")
                    }
                }
                divider
                Button { model.controller?.cycleThickness() } label: {
                    Circle()
                        .fill(Ink.isDark(model.color) ? Color.white : Color(nsColor: model.color))
                        .frame(width: Thickness.dot[model.thickness], height: Thickness.dot[model.thickness])
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Товщина: \(Thickness.names[model.thickness]) ([ і ] — змінити)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .glassPanel(cornerRadius: 21)
        case .timer:
            HStack(spacing: 2) {
                ForEach([3, 5, 10], id: \.self) { seconds in
                    Button("\(seconds) с") { model.controller?.delayedRetake(seconds) }
                        .font(Theme.font(13, .semibold))
                        .buttonStyle(GlassIconButtonStyle(width: 52))
                        .help("Сховати вікно й зняти екран заново через \(seconds) \(seconds == 10 ? "секунд" : seconds == 3 ? "секунди" : "секунд")")
                }
            }
            .padding(4)
            .glassPanel(cornerRadius: 21)
        }
    }
}

/// Voice: click = start/stop, Space = hold to talk. A solid red disc with a pulsing ring while listening.
private struct MicButton: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        Button { model.controller?.recordClicked() } label: {
            ZStack {
                if model.isRecording {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let p = (1 - cos(t * .pi / 0.5)) / 2 // 0 → 1 in 0.5 s, then back
                        Circle()
                            .fill(Theme.recordFill)
                            .opacity(0.6 - 0.52 * p)
                            .scaleEffect(1 + 0.4 * p)
                    }
                    Circle()
                        .stroke(Color(rgb: 0xFF8E99), lineWidth: 2)
                        .opacity(0.35 + model.level * 0.65)
                        .scaleEffect(1.05 + model.level * 0.45)
                    Circle().fill(Theme.recordFill)
                }
                GlyphIcon(icon: .mic)
                    .foregroundColor(model.isRecording ? .white : Color(rgb: 0xF4F4F5))
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(GlassIconButtonStyle())
        .help("Голос: клацніть, щоб почати й зупинити запис, або утримуйте Пробіл")
    }
}

private struct SwatchButton: View {
    let rgb: UInt32
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(selected ? Color(rgb: 0xF3F3F6) : hover ? Color(argb: 0x66FFFFFF) : .clear, lineWidth: 2)
                Circle()
                    .fill(Color(rgb: rgb))
                    .overlay(Circle().strokeBorder(Color(argb: 0x40FFFFFF), lineWidth: 1))
                    .padding(5)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct StatusPillView: View {
    let status: OverlayStatus

    var body: some View {
        HStack(spacing: 7) {
            if status.kind == .busy {
                TimelineView(.animation) { context in
                    GlyphIcon(icon: .spark, size: 13, weight: 2.4)
                        .foregroundColor(Theme.accentLight)
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
            }
            Text(status.text)
                .font(Theme.font(12.5, .semibold))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: true, vertical: false)
                .help(status.text)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.top, 5)
        .padding(.bottom, 6)
        .glassPanel(cornerRadius: 15)
    }

    private var color: Color {
        switch status.kind {
        case .success: return Theme.green
        case .warning: return Theme.amber
        case .error, .recording: return Theme.red
        default: return Theme.glassText
        }
    }
}

/// First-use hint in the middle of the screen.
struct HintBadge: View {
    var body: some View {
        HStack(spacing: 12) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Виділіть область мишкою")
                    .font(Theme.font(15, .semibold))
                    .foregroundColor(Theme.glassText)
                Text("Enter — весь екран  ·  Пробіл або мікрофон — голос  ·  Esc — скасувати")
                    .font(Theme.font(12))
                    .foregroundColor(Theme.glassMuted)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 18)
    }
}

/// The comment box: a plain NSTextView (Shift+Return = new line, Return = save) with a placeholder.
private struct CommentField: View {
    @ObservedObject var model: OverlayModel
    @State private var height: CGFloat = 20

    var body: some View {
        ZStack(alignment: .leading) {
            if RenderMode.snapshot {
                Text(model.comment)
                    .font(Theme.font(14))
                    .foregroundColor(model.commentIsPreview ? Color(rgb: 0xA1A1AA) : Theme.glassText)
                    .lineLimit(4)
                    .padding(.leading, 2)
            } else {
                CommentTextView(model: model, height: $height)
                    .frame(height: min(max(height, 20), 88))
            }
            if model.comment.isEmpty && !model.commentReadOnly {
                Text(model.placeholder)
                    .font(Theme.font(14))
                    .foregroundColor(Theme.glassMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 34)
    }
}

/// NSTextView subclass so the controller can recognise it as «the comment box».
final class CommentNSTextView: NSTextView {}

private struct CommentTextView: NSViewRepresentable {
    @ObservedObject var model: OverlayModel
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let text = CommentNSTextView()
        text.isRichText = false
        text.importsGraphics = false
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 14)
        text.textColor = NSColor(rgb: 0xF4F4F7)
        text.insertionPointColor = NSColor(rgb: 0xFFC68A)
        text.selectedTextAttributes = [.backgroundColor: NSColor(rgb: 0xFF8A4C, alpha: 0.45), .foregroundColor: NSColor.white]
        text.textContainerInset = NSSize(width: 0, height: 1)
        text.textContainer?.lineFragmentPadding = 2
        text.textContainer?.widthTracksTextView = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.delegate = context.coordinator
        text.string = model.comment
        scroll.documentView = text
        model.controller?.commentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if text.string != model.comment {
            text.string = model.comment
            text.setSelectedRange(NSRange(location: (model.comment as NSString).length, length: 0))
            text.scrollToEndOfDocument(nil)
        }
        text.isEditable = !model.commentReadOnly
        text.isSelectable = true
        text.textColor = model.commentIsPreview ? NSColor(rgb: 0xA1A1AA) : NSColor(rgb: 0xF4F4F7)
        context.coordinator.measure(text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentTextView

        init(_ parent: CommentTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            if parent.model.comment != text.string {
                parent.model.comment = text.string
            }
            parent.model.controller?.commentEdited()
            measure(text)
        }

        func measure(_ text: NSTextView) {
            guard let layout = text.layoutManager, let container = text.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + text.textContainerInset.height * 2
            let value = max(20, ceil(used))
            if abs(value - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = value }
            }
        }
    }
}
