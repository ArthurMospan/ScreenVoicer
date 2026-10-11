import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One push-to-talk fragment; consecutive fragments are appended to the comment in order.
private final class VoiceChunk {
    var text = ""
    var isFinal = false
}

/// One undoable step.
private enum Change {
    case added([AnnotationItem])
    case removed(AnnotationItem, Int)
    case moved(AnnotationItem, CGPoint, CGPoint)
    case labelEdit(LabelAnnotation, String, String)
}

/// The capture overlay: frozen screen, region selection, annotations, voice comment, save.
/// A line-by-line twin of Views/OverlayWindow.xaml.cs — keep their behaviour in sync (see PARITY.md).
@MainActor
final class OverlayController: NSObject, NSTextFieldDelegate {
    private static let maxTake: TimeInterval = 180
    /// Below this share of 1–4 kHz energy the voice is "through a pillow".
    private static let muffledShare = 0.015

    private let capture: ScreenCapture
    private let audio: AudioRecorder
    private let whisper: WhisperService
    private let settings: Settings
    private let history: HistoryService
    private let openGallery: () -> Void
    private let startDelayedCapture: ((Int) -> Void)?
    private let shareItem: ((ScreenshotHistoryItem) -> Void)?
    var onClosed: (() -> Void)?

    let model = OverlayModel()
    private var panel: OverlayPanel!
    private var root: NSView!
    private var canvas: CanvasView!
    private var dimView: DimView!
    private var frameView: FrameView!
    weak var commentView: NSTextView?

    private var closed = false
    private var isSaving = false

    // region selection (points, relative to the display, y-down)
    private var selection: CGRect?
    private var selectionBeforeDrag: CGRect?
    private var isSelecting = false
    private var dragStart = CGPoint.zero

    // adjusting the region: eight small squares on the frame, drag one instead of selecting again
    private var resizeHandle: Int?
    private var resizeStartRect = CGRect.zero
    private var resizeStartPoint = CGPoint.zero

    // drawing
    private(set) var items: [AnnotationItem] = []
    private var undoStack: [Change] = []
    private var redoStack: [Change] = []
    private var shapeStart: CGPoint?
    private var shapeStroke: StrokeAnnotation?
    private var liveStroke: StrokeAnnotation?
    private var blurStart: CGPoint?
    private var blurItem: BlurAnnotation?
    private var erasing = false

    // text labels & numbered markers
    private var editingLabel: LabelAnnotation?
    private var editingIsNew = false
    private var editingOriginalText = ""
    private var labelField: LabelField?
    private var dragItem: AnnotationItem?
    private var dragItemStart = CGPoint.zero
    private var dragItemOrigin = CGPoint.zero
    private var dragItemMoved = false

    // voice
    private var isRecording = false
    private var recordingHandsFree = false   // started by the mic button or a short Space tap
    private var spaceStopsRecording = false  // the current Space press ended a hands-free take
    private var spaceHoldStarted = Date()
    private var textBeforeSpace: (text: String, caret: Int)?
    private var recordingGeneration = 0
    private var currentChunk: VoiceChunk?
    private var baseText = ""
    private var chunks: [VoiceChunk] = []
    private var pendingTranscriptions: [UUID: Task<Void, Never>] = [:]
    private var updatingText = false
    private var displayLevel: Float = 0

    // flyouts
    private var flyoutTimer: Timer?
    private var hoveredAnchor: Flyout?
    private var flyoutHovered = false

    init(capture: ScreenCapture, audio: AudioRecorder, whisper: WhisperService, settings: Settings, history: HistoryService,
         openGallery: @escaping () -> Void, startDelayedCapture: ((Int) -> Void)?, shareItem: ((ScreenshotHistoryItem) -> Void)?) {
        self.capture = capture
        self.audio = audio
        self.whisper = whisper
        self.settings = settings
        self.history = history
        self.openGallery = openGallery
        self.startDelayedCapture = startDelayedCapture
        self.shareItem = shareItem
        super.init()
        model.controller = self
        model.showTimer = startDelayedCapture != nil
        model.mode = settings.defaultCaptureMode
        model.topInset = capture.screen.safeAreaInsets.top
        buildWindow()
        applyTool(.pen)
        updateUndoButtons()
        applyMode(model.mode)
        updateMicrophoneTooltip()
        updateIdleStatus()
    }

    // MARK: - Window

    private func buildWindow() {
        let frame = capture.frame
        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.controller = self
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false

        let size = frame.size
        root = FlippedView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true

        let shot = ScreenshotView(image: capture.image, scale: capture.scale)
        dimView = DimView(frame: root.bounds)
        canvas = CanvasView(frame: root.bounds)
        canvas.controller = self
        frameView = FrameView(frame: root.bounds)
        let chrome = ChromeHostingView(rootView: OverlayChrome(model: model))
        chrome.model = model

        for view in [shot, dimView!, canvas!, frameView!, chrome] as [NSView] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        panel.contentView = root
        panel.setFrame(frame, display: false)
    }

    var panelForTest: NSPanel? { panel }
    var selectionForTest: CGRect? { selection }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(canvas)
        Log.info("[Overlay] Shown on \(capture.image.width)x\(capture.image.height), key=\(panel.isKeyWindow).")
    }

    func bringToFront() {
        if closed || isSaving { return }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if !isInCommentBox { panel.makeFirstResponder(canvas) }
    }

    private var isInCommentBox: Bool {
        guard let commentView else { return false }
        return panel.firstResponder === commentView
    }

    private var isInLabelField: Bool {
        guard let labelField, let editor = panel.firstResponder as? NSTextView else { return false }
        return editor.delegate === labelField
    }

    /// Clicking the picture leaves the comment box, so Space records again instead of typing spaces.
    private func leaveTextBox() {
        if isInCommentBox { panel.makeFirstResponder(canvas) }
    }

    func cursor(at point: CGPoint) -> NSCursor {
        if let handle = resizeHandle ?? hitHandle(point) {
            return Self.resizeCursor(handle)
        }
        if model.mode == .rectangleRegion, !(selection.map { $0.width >= 8 && $0.contains(point) } ?? false) {
            return .crosshair
        }
        return model.tool == .text ? .iBeam : .crosshair
    }

    private static func resizeCursor(_ handle: Int) -> NSCursor {
        if #available(macOS 15.0, *) {
            let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
            return NSCursor.frameResize(position: positions[handle], directions: .all)
        }
        switch handle {
        case 1, 5: return .resizeUpDown
        case 3, 7: return .resizeLeftRight
        default: return .crosshair // diagonal resize cursors are public only since macOS 15
        }
    }

    // MARK: - Flyouts

    func anchorHover(_ flyout: Flyout, _ inside: Bool) {
        if inside {
            hoveredAnchor = flyout
            openFlyout(flyout)
        } else {
            if hoveredAnchor == flyout { hoveredAnchor = nil }
            restartFlyoutTimer()
        }
    }

    func flyoutHover(_ inside: Bool) {
        flyoutHovered = inside
        if !inside { restartFlyoutTimer() }
    }

    func toggleFlyout(_ flyout: Flyout) {
        if model.openFlyout == flyout { closeFlyout() } else { openFlyout(flyout) }
    }

    private func openFlyout(_ flyout: Flyout) {
        if isSelecting || isSaving { return }
        flyoutTimer?.invalidate()
        if model.openFlyout != flyout {
            withAnimation(.easeOut(duration: 0.12)) { model.openFlyout = flyout }
        }
    }

    private func restartFlyoutTimer() {
        flyoutTimer?.invalidate()
        flyoutTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.model.openFlyout != nil && self.hoveredAnchor == nil && !self.flyoutHovered {
                    self.closeFlyout()
                }
            }
        }
    }

    private func closeFlyout() {
        flyoutTimer?.invalidate()
        model.openFlyout = nil
        flyoutHovered = false
    }

    /// Retake with a delay: the overlay goes away, the countdown runs, and a fresh screenshot opens.
    func delayedRetake(_ seconds: Int) {
        guard let start = startDelayedCapture, !isSaving else { return }
        closeFlyout()
        close()
        DispatchQueue.main.async { start(seconds) } // after the app has seen this overlay close
    }

    // MARK: - Capture mode & region selection

    func switchMode(_ mode: CaptureMode) {
        if mode == .rectangleRegion && model.mode == .rectangleRegion {
            selection = nil // clicking «Область» again starts over
        }
        applyMode(mode)
        if settings.defaultCaptureMode != mode {
            settings.defaultCaptureMode = mode
            settings.save()
        }
    }

    private func applyMode(_ mode: CaptureMode) {
        model.mode = mode
        updateSelectionVisuals()
        repositionPanels()
    }

    private func clampToRoot(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), root.bounds.width), y: min(max(p.y, 0), root.bounds.height))
    }

    private func endSelectionDrag(commit: Bool) {
        isSelecting = false
        // a click without a real drag keeps the previous selection
        if !commit || (selection.map { $0.width < 8 || $0.height < 8 } ?? true) {
            selection = selectionBeforeDrag
        }
        model.panelsFaded = false
        updateSelectionVisuals()
        repositionPanels()
    }

    private func updateSelectionVisuals() {
        let region = model.mode == .rectangleRegion
        guard region else {
            dimView.isHidden = true
            frameView.selection = nil
            frameView.showsHandles = false
            model.hintVisible = false
            canvas.clip = nil
            canvas.needsDisplay = true
            return
        }
        dimView.isHidden = false
        if let s = selection, s.width >= 1, s.height >= 1 {
            dimView.update(hole: s)
            frameView.sizeText = "\(Int((s.width * capture.scale).rounded())) × \(Int((s.height * capture.scale).rounded()))"
            frameView.showsHandles = !isSelecting
            frameView.selection = s
            model.hintVisible = false
            canvas.clip = s
        } else {
            dimView.update(hole: nil)
            frameView.showsHandles = false
            frameView.selection = nil
            model.hintVisible = !isSelecting
            canvas.clip = .zero // ink shows only inside a selection (the canvas still takes the clicks that select)
        }
        canvas.needsDisplay = true
    }

    private func hitHandle(_ p: CGPoint) -> Int? {
        guard model.mode == .rectangleRegion, !isSelecting, !isSaving, let r = selection, r.width >= 8, r.height >= 8 else { return nil }
        return (0..<8).first { i in
            let h = FrameView.handlePoint(r, i)
            return abs(p.x - h.x) <= 7 && abs(p.y - h.y) <= 7
        }
    }

    private func beginResize(_ handle: Int, at point: CGPoint) {
        commitLabelEdit()
        leaveTextBox()
        resizeHandle = handle
        resizeStartRect = selection ?? .zero
        resizeStartPoint = point
        closeFlyout()
        model.panelsFaded = true
    }

    private func updateResize(_ point: CGPoint) {
        guard let handle = resizeHandle else { return }
        let dx = point.x - resizeStartPoint.x, dy = point.y - resizeStartPoint.y
        var left = resizeStartRect.minX, top = resizeStartRect.minY, right = resizeStartRect.maxX, bottom = resizeStartRect.maxY
        if [0, 6, 7].contains(handle) { left += dx }
        if [0, 1, 2].contains(handle) { top += dy }
        if [2, 3, 4].contains(handle) { right += dx }
        if [4, 5, 6].contains(handle) { bottom += dy }
        // dragging an edge past the opposite one just flips the region
        let a = clampToRoot(CGPoint(x: left, y: top)), b = clampToRoot(CGPoint(x: right, y: bottom))
        selection = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        updateSelectionVisuals()
    }

    private func endResize() {
        guard resizeHandle != nil else { return }
        resizeHandle = nil
        if selection.map({ $0.width < 8 || $0.height < 8 }) ?? true {
            selection = resizeStartRect
        }
        model.panelsFaded = false
        updateSelectionVisuals()
        repositionPanels()
    }

    func toolbarFrameChanged() { repositionPanels() }

    /// The bar sits at the top; it moves to the bottom only when the selection would end up under it.
    private func repositionPanels() {
        let width = root.bounds.width, height = root.bounds.height
        let bar = model.toolbarFrame
        guard width > 0, bar.width > 0 else { return }
        let edge: CGFloat = 16 + model.topInset
        var atBottom = false
        if model.mode == .rectangleRegion, let r = selection, r.width >= 8 {
            let topZone = CGRect(x: (width - bar.width) / 2, y: 0, width: bar.width, height: edge + bar.height + 40)
            let bottomZone = CGRect(x: topZone.minX, y: height - topZone.height, width: topZone.width, height: topZone.height)
            atBottom = r.intersects(topZone) && !r.intersects(bottomZone)
        }
        if model.toolbarAtBottom != atBottom {
            closeFlyout() // it was placed for the old position
            model.toolbarAtBottom = atBottom
        }
    }

    /// Region to keep in pixels; nil = the whole display.
    private func cropPixels() -> CGRect? {
        guard model.mode == .rectangleRegion, let r = selection, r.width >= 8, r.height >= 8 else { return nil }
        let s = capture.scale
        let x = (r.minX * s).rounded(), y = (r.minY * s).rounded()
        return CGRect(x: x, y: y, width: (r.maxX * s).rounded() - x, height: (r.maxY * s).rounded() - y)
    }

    // MARK: - Mouse

    func mouseDown(at point: CGPoint, clickCount: Int) {
        if isSaving { return }
        if let handle = hitHandle(point) {
            beginResize(handle, at: clampToRoot(point)) // over a handle no tool starts drawing
            return
        }
        let insideSelection = selection.map { $0.width >= 8 && $0.height >= 8 && $0.contains(point) } ?? false
        if model.mode == .rectangleRegion && !insideSelection {
            commitLabelEdit()
            leaveTextBox()
            isSelecting = true
            selectionBeforeDrag = selection
            dragStart = clampToRoot(point)
            selection = CGRect(origin: dragStart, size: .zero)
            closeFlyout()
            model.panelsFaded = true
            updateSelectionVisuals()
            return
        }

        let annotation = topMovable(at: point)
        if let editing = editingLabel, annotation !== editing {
            commitLabelEdit() // clicking elsewhere finishes the label being typed
        } else if annotation == nil || annotation !== editingLabel {
            leaveTextBox()
        }

        switch model.tool {
        case .eraser:
            if let annotation {
                removeAnnotation(annotation)
            } else if !items.contains(where: { $0 is StrokeAnnotation && $0.hitTest(point) }),
                      let blur = items.last(where: { $0 is BlurAnnotation && $0.hitTest(point) }) {
                removeAnnotation(blur) // a hidden area goes by a click, like tags and markers
            } else {
                erasing = true
                erase(at: point)
            }
        case .blur:
            blurStart = point
            blurItem = nil
        case .text, .marker:
            if let annotation {
                if annotation === editingLabel { return } // the text field places the caret
                if clickCount == 2, let label = annotation as? LabelAnnotation {
                    beginEditLabel(label, isNew: false)
                } else {
                    dragItem = annotation
                    dragItemStart = point
                    dragItemOrigin = annotation.origin
                    dragItemMoved = false
                }
            } else if model.tool == .text {
                addLabel(at: point)
            } else {
                addMarker(at: point)
            }
        case .arrow, .rectangle:
            shapeStart = point
            shapeStroke = nil
        case .pen, .highlighter:
            let stroke = StrokeAnnotation(points: [point], color: model.color,
                                          width: model.tool == .pen ? Thickness.pen[model.thickness] : Thickness.highlighter[model.thickness],
                                          style: model.tool == .pen ? .pen : .highlighter)
            liveStroke = stroke
            items.append(stroke)
            canvas.needsDisplay = true
        }
    }

    func mouseDragged(to point: CGPoint, shift: Bool) {
        if resizeHandle != nil {
            updateResize(clampToRoot(point))
            return
        }
        if let start = blurStart {
            updateBlur(CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y)))
            return
        }
        if isSelecting {
            selection = CGRect(x: min(dragStart.x, clampToRoot(point).x), y: min(dragStart.y, clampToRoot(point).y),
                               width: abs(clampToRoot(point).x - dragStart.x), height: abs(clampToRoot(point).y - dragStart.y))
            updateSelectionVisuals()
            return
        }
        if let item = dragItem {
            let dx = point.x - dragItemStart.x, dy = point.y - dragItemStart.y
            if !dragItemMoved && abs(dx) + abs(dy) < 3 { return }
            dragItemMoved = true
            item.origin = CGPoint(x: dragItemOrigin.x + dx, y: dragItemOrigin.y + dy)
            canvas.needsDisplay = true
            return
        }
        if erasing {
            erase(at: point)
            return
        }
        if let start = shapeStart {
            let end = shift ? constrain(start, point) : point
            guard let points = model.tool == .arrow ? arrowPoints(start, end) : rectanglePoints(start, end) else { return }
            if let stroke = shapeStroke {
                stroke.points = points
            } else {
                let stroke = StrokeAnnotation(points: points, color: model.color, width: Thickness.pen[model.thickness], style: .shape)
                shapeStroke = stroke
                items.append(stroke) // the live preview is not an undo step; the finished shape is
            }
            canvas.needsDisplay = true
            return
        }
        if let stroke = liveStroke {
            if let last = stroke.points.last, hypot(last.x - point.x, last.y - point.y) < 0.75 { return }
            stroke.points.append(point)
            canvas.needsDisplay = true
        }
    }

    func mouseUp(at point: CGPoint) {
        if resizeHandle != nil {
            endResize()
            return
        }
        if blurStart != nil {
            blurStart = nil
            if let blur = blurItem { pushHistory(.added([blur])) }
            blurItem = nil
            return
        }
        if isSelecting {
            endSelectionDrag(commit: true)
            return
        }
        if let item = dragItem {
            dragItem = nil
            if dragItemMoved { pushHistory(.moved(item, dragItemOrigin, item.origin)) }
            return
        }
        if erasing {
            erasing = false
            return
        }
        if shapeStart != nil {
            shapeStart = nil
            if let stroke = shapeStroke { pushHistory(.added([stroke])) }
            shapeStroke = nil
            return
        }
        if let stroke = liveStroke {
            liveStroke = nil
            pushHistory(.added([stroke]))
        }
    }

    /// «Приховати»: rebuilds the hidden area from the screenshot as the rectangle grows.
    private func updateBlur(_ rect: CGRect) {
        let r = rect.intersection(root.bounds)
        guard !r.isNull, r.width >= 4, r.height >= 4 else { return }
        let block = Thickness.blurBlock[model.thickness]
        if let blur = blurItem {
            blur.update(capture: capture.image, scale: capture.scale, rect: r, block: block)
        } else if let blur = BlurAnnotation.make(capture: capture.image, scale: capture.scale, rect: r, block: block) {
            blurItem = blur
            items.append(blur) // the live preview is not an undo step; the finished area is
        }
        canvas.needsDisplay = true
    }

    private func topMovable(at point: CGPoint) -> AnnotationItem? {
        items.reversed().first { $0.isMovable && $0.hitTest(point) }
    }

    /// Eraser by stroke: every stroke it touches goes (each one undoable), tags and markers only by a click.
    private func erase(at point: CGPoint) {
        guard let index = items.lastIndex(where: { $0 is StrokeAnnotation && $0.hitTest(point) }) else { return }
        let item = items.remove(at: index)
        pushHistory(.removed(item, index))
        canvas.needsDisplay = true
    }

    private func constrain(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        let vx = end.x - start.x, vy = end.y - start.y
        if model.tool == .rectangle {
            let side = max(abs(vx), abs(vy))
            return CGPoint(x: start.x + (vx < 0 ? -side : side), y: start.y + (vy < 0 ? -side : side))
        }
        // arrow: snap to multiples of 45°
        let angle = (atan2(vy, vx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(vx, vy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private func arrowPoints(_ from: CGPoint, _ to: CGPoint) -> [CGPoint]? {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        if length < 6 { return nil }
        let ux = dx / length, uy = dy / length
        let head = min(length * 0.5, max(14, Thickness.pen[model.thickness] * 4.5))
        func rotated(_ degrees: CGFloat) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: ux * cos(r) - uy * sin(r), y: ux * sin(r) + uy * cos(r))
        }
        let l = rotated(28), r = rotated(-28)
        return [from, to, CGPoint(x: to.x - l.x * head, y: to.y - l.y * head), to, CGPoint(x: to.x - r.x * head, y: to.y - r.y * head)]
    }

    private func rectanglePoints(_ a: CGPoint, _ b: CGPoint) -> [CGPoint]? {
        if abs(b.x - a.x) < 4 && abs(b.y - a.y) < 4 { return nil }
        return [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y), a]
    }

    // MARK: - Tools

    func selectTool(_ tool: Tool) {
        applyTool(tool)
        closeFlyout()
    }

    private func applyTool(_ tool: Tool) {
        if tool != .text { commitLabelEdit() }
        model.tool = tool
        panel.invalidateCursorRects(for: canvas)
    }

    func selectColor(_ rgb: UInt32) {
        model.colorRGB = rgb
        closeFlyout()
        if let label = editingLabel {
            label.color = model.color // recolour the label being typed
            labelField?.textColor = Ink.contrast(for: model.color)
            canvas.needsDisplay = true
            return
        }
        applyTool(model.tool == .eraser ? .pen : model.tool)
    }

    func cycleThickness() { changeThickness(1, wrap: true) }

    private func changeThickness(_ delta: Int, wrap: Bool) {
        let next = model.thickness + delta
        model.thickness = wrap ? (next + 3) % 3 : min(max(next, 0), 2)
    }

    // MARK: - Text labels & numbered markers

    private func addLabel(at point: CGPoint) {
        let fontSize = Thickness.labelFont[model.thickness]
        let label = LabelAnnotation(position: CGPoint(x: point.x, y: point.y - fontSize * 0.8), text: "",
                                    color: model.color, fontSize: fontSize)
        items.append(label)
        beginEditLabel(label, isNew: true)
    }

    private func beginEditLabel(_ label: LabelAnnotation, isNew: Bool) {
        commitLabelEdit()
        editingLabel = label
        editingIsNew = isNew
        editingOriginalText = isNew ? "" : label.text
        label.isEditing = true

        let field = LabelField(string: editingOriginalText)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = label.font
        field.textColor = Ink.contrast(for: label.color)
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.delegate = self
        canvas.addSubview(field)
        labelField = field
        layoutLabelField()
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (editingOriginalText as NSString).length, length: 0)
        }
    }

    private func layoutLabelField() {
        guard let label = editingLabel, let field = labelField else { return }
        let measured = (field.stringValue.isEmpty ? " " : field.stringValue as NSString).boundingRect(
            with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin], attributes: label.attributes).size
        let size = CGSize(width: max(ceil(measured.width) + 4, label.fontSize * 1.2), height: ceil(measured.height))
        label.editingTextSize = size
        let pad = label.padding
        field.frame = CGRect(x: label.position.x + pad.left - 2, y: label.position.y + pad.top, width: size.width + 4, height: size.height + 2)
        canvas.needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) { layoutLabelField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === labelField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                layoutLabelField()
            } else {
                commitLabelEdit()
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitLabelEdit(cancel: true)
            return true
        }
        return false
    }

    /// Turns the label being typed back into text and records it for undo.
    private func commitLabelEdit(cancel: Bool = false) {
        guard let label = editingLabel, let field = labelField else {
            editingLabel = nil
            return
        }
        editingLabel = nil
        labelField = nil
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = cancel ? editingOriginalText : typed
        field.delegate = nil
        field.removeFromSuperview()
        label.isEditing = false
        label.editingTextSize = nil

        if editingIsNew {
            if text.isEmpty {
                items.removeAll { $0 === label } // nothing typed: no label, no undo step
            } else {
                label.text = text
                pushHistory(.added([label]))
            }
        } else if text.isEmpty {
            label.text = editingOriginalText
            removeAnnotation(label) // cleared an existing label = delete it (undoable)
        } else if text != editingOriginalText {
            label.text = text
            pushHistory(.labelEdit(label, editingOriginalText, text))
        } else {
            label.text = editingOriginalText
        }
        panel.makeFirstResponder(canvas)
        canvas.needsDisplay = true
    }

    private func addMarker(at center: CGPoint) {
        let number = (items.compactMap { ($0 as? MarkerAnnotation)?.number }.max() ?? 0) + 1
        let marker = MarkerAnnotation(center: center, number: number, color: model.color, size: Thickness.marker[model.thickness])
        items.append(marker)
        pushHistory(.added([marker]))
        canvas.needsDisplay = true
    }

    private func removeAnnotation(_ item: AnnotationItem) {
        if item === editingLabel {
            let wasNew = editingIsNew
            commitLabelEdit(cancel: true)
            if wasNew { return } // a label that was never committed simply disappears
        }
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        items.remove(at: index)
        pushHistory(.removed(item, index))
        canvas.needsDisplay = true
    }

    // MARK: - Undo / redo

    private func pushHistory(_ change: Change) {
        undoStack.append(change)
        redoStack.removeAll()
        updateUndoButtons()
    }

    func undo() {
        commitLabelEdit()
        guard let change = undoStack.popLast() else { return }
        revert(change, undo: true)
        redoStack.append(change)
        updateUndoButtons()
    }

    func redo() {
        commitLabelEdit()
        guard let change = redoStack.popLast() else { return }
        revert(change, undo: false)
        undoStack.append(change)
        updateUndoButtons()
    }

    private func revert(_ change: Change, undo: Bool) {
        switch change {
        case .added(let added):
            if undo {
                items.removeAll { item in added.contains { $0 === item } }
            } else {
                items.append(contentsOf: added.filter { item in !items.contains { $0 === item } })
            }
        case .removed(let item, let index):
            if undo {
                if !items.contains(where: { $0 === item }) { items.insert(item, at: min(index, items.count)) }
            } else {
                items.removeAll { $0 === item }
            }
        case .moved(let item, let from, let to):
            item.origin = undo ? from : to
        case .labelEdit(let label, let from, let to):
            label.text = undo ? from : to
        }
        canvas.needsDisplay = true
    }

    private func updateUndoButtons() {
        model.canUndo = !undoStack.isEmpty
        model.canRedo = !redoStack.isEmpty
    }

    // MARK: - Keyboard

    /// Returns true when the key was handled (it then never reaches the text boxes).
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if isInLabelField { return false } // typing a text label: Enter/Esc/Space/letters belong to it

        let code = Int(event.keyCode)
        let inTextBox = isInCommentBox
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if code == kVK_Space && mods.isEmpty {
            return handleSpaceDown(event, inTextBox: inTextBox)
        }

        switch code {
        case kVK_Escape:
            if isSelecting {
                endSelectionDrag(commit: false)
            } else if isRecording {
                cancelCurrentRecording() // Esc while talking drops the take, not the whole screenshot
            } else if model.openFlyout != nil {
                closeFlyout()
            } else if inTextBox {
                panel.makeFirstResponder(canvas) // the first Esc just leaves the text box
            } else if !isSaving {
                close()
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if inTextBox && mods.contains(.shift) { return false } // Shift+Return inside the comment = new line
            save()
            return true
        default:
            break
        }

        if inTextBox || isSaving { return false } // the text box handles its own ⌘Z, letters, etc.

        if mods.contains(.command) {
            if code == kVK_ANSI_Z {
                if mods.contains(.shift) { redo() } else { undo() }
                return true
            }
            if code == kVK_ANSI_Y {
                redo()
                return true
            }
            return false
        }
        if !mods.subtracting(.shift).isEmpty { return false }

        switch code {
        case kVK_ANSI_P: applyTool(.pen)
        case kVK_ANSI_H: applyTool(.highlighter)
        case kVK_ANSI_A: applyTool(.arrow)
        case kVK_ANSI_R: applyTool(.rectangle)
        case kVK_ANSI_T: applyTool(.text)
        case kVK_ANSI_N: applyTool(.marker)
        case kVK_ANSI_B: applyTool(.blur)
        case kVK_ANSI_E: applyTool(.eraser)
        case kVK_ANSI_LeftBracket: changeThickness(-1, wrap: false)
        case kVK_ANSI_RightBracket: changeThickness(1, wrap: false)
        case kVK_ANSI_1: selectColor(Theme.swatches[0].rgb)
        case kVK_ANSI_2: selectColor(Theme.swatches[1].rgb)
        case kVK_ANSI_3: selectColor(Theme.swatches[2].rgb)
        case kVK_ANSI_4: selectColor(Theme.swatches[3].rgb)
        case kVK_ANSI_5: selectColor(Theme.swatches[4].rgb)
        case kVK_ANSI_6: selectColor(Theme.swatches[5].rgb)
        default: return false
        }
        return true
    }

    /// Space talks: hold it and speak, or tap it to keep recording hands-free until the next tap / mic click.
    /// In the comment box a tap still types a space; holding it takes that space back and starts recording.
    private func handleSpaceDown(_ event: NSEvent, inTextBox: Bool) -> Bool {
        if !event.isARepeat {
            if isRecording {
                spaceStopsRecording = true // a hands-free take: this press ends it
                Task { await endRecording() }
                return true
            }
            if !inTextBox {
                startSpaceRecording(heldAlready: false)
                return true
            }
            // in the comment box: let this press type its space, but remember the text in case it becomes a hold
            if let commentView {
                textBeforeSpace = (commentView.string, commentView.selectedRange().location)
            }
            return false
        }

        // auto-repeat: Space is being held (never type a run of spaces)
        if inTextBox && !isRecording && !spaceStopsRecording && !model.commentReadOnly, let before = textBeforeSpace, let commentView {
            if (commentView.string as NSString).length == (before.text as NSString).length + 1 {
                commentView.string = before.text // take back the space the first press typed
                commentView.setSelectedRange(NSRange(location: min(before.caret, (before.text as NSString).length), length: 0))
                model.comment = before.text
                commentEdited()
            }
            textBeforeSpace = nil
            startSpaceRecording(heldAlready: true) // the repeat delay already proves it is a hold
        }
        return true
    }

    private func startSpaceRecording(heldAlready: Bool) {
        if beginRecording(handsFree: false) {
            spaceHoldStarted = heldAlready ? .distantPast : Date()
        }
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        guard Int(event.keyCode) == kVK_Space, !isInLabelField else { return false }
        textBeforeSpace = nil
        if spaceStopsRecording {
            spaceStopsRecording = false // the release of the press that stopped a hands-free take
            return true
        }
        guard isRecording, !recordingHandsFree else { return false }
        if Date().timeIntervalSince(spaceHoldStarted) < 0.35 {
            recordingHandsFree = true // a quick tap: keep listening until Space or the mic is pressed again
            showRecordingStatus()
        } else {
            Task { await endRecording() }
        }
        return true
    }

    // MARK: - Voice comment

    func recordClicked() {
        if isRecording {
            Task { await endRecording() }
        } else {
            _ = beginRecording(handsFree: true)
        }
    }

    private func beginRecording(handsFree: Bool) -> Bool {
        if isRecording || isSaving || closed { return false }
        if chunks.isEmpty {
            baseText = model.comment.trimmingCharacters(in: .whitespacesAndNewlines) // keep what the user typed
        }
        guard audio.start() else {
            showStatus(audio.lastError ?? "Не вдалося увімкнути мікрофон.", .error)
            return false
        }

        isRecording = true
        recordingHandsFree = handsFree
        recordingGeneration += 1
        let generation = recordingGeneration
        let chunk = VoiceChunk()
        currentChunk = chunk
        chunks.append(chunk)
        refreshCommentText()
        setRecordingVisuals(true)
        showRecordingStatus()

        if !whisper.isModelReady {
            Task { await whisper.ensureModelLoaded() }
        }
        Task { await runLivePreview(generation: generation, chunk: chunk) }
        return true
    }

    private func showRecordingStatus() {
        let how = recordingHandsFree
            ? "Говоріть… щоб зупинити — натисніть Пробіл або мікрофон"
            : "Говоріть… відпустіть Пробіл, коли закінчите"
        showStatus(whisper.isModelReady ? how : how + " (модель ще готується)", .recording)
    }

    /// Esc while talking: drop this take, keep the rest of the comment.
    private func cancelCurrentRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingGeneration += 1
        audio.cancel()
        if let chunk = currentChunk {
            chunks.removeAll { $0 === chunk }
            currentChunk = nil
        }
        setRecordingVisuals(false)
        refreshCommentText()
        if chunks.isEmpty { updateIdleStatus() }
    }

    /// Re-transcribes the growing recording with the fast preview settings for live feedback.
    private func runLivePreview(generation: Int, chunk: VoiceChunk) async {
        let started = Date()
        while true {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !isRecording || generation != recordingGeneration || closed { return }
            if Date().timeIntervalSince(started) > Self.maxTake {
                await endRecording() // a forgotten hands-free take
                return
            }
            if !whisper.isModelReady { continue }
            let samples = audio.snapshot()
            if samples.count < AudioAnalysis.sampleRate / 2 { continue }
            let text = await whisper.tryTranscribePreview(samples)
            if let text, !chunk.isFinal, !closed, chunks.contains(where: { $0 === chunk }), !text.isEmpty {
                chunk.text = text
                refreshCommentText()
            }
        }
    }

    private func endRecording() async {
        guard isRecording, let chunk = currentChunk else { return }
        isRecording = false
        recordingHandsFree = false
        setRecordingVisuals(false)

        let samples = await audio.stop()
        if closed { return }
        if Double(samples.count) < Double(AudioAnalysis.sampleRate) * 0.3 {
            chunks.removeAll { $0 === chunk }
            refreshCommentText()
            showStatus("Запис був надто короткий — говоріть трохи довше.", .warning)
            return
        }

        let id = UUID()
        pendingTranscriptions[id] = Task { [weak self] in
            await self?.finishChunk(chunk, samples: samples)
            self?.pendingTranscriptions[id] = nil
        }
    }

    private func finishChunk(_ chunk: VoiceChunk, samples: [Float]) async {
        showStatus(whisper.isModelReady ? "Розпізнаю…" : "Чекаю на модель розпізнавання…", .busy)
        let started = Date()
        let analysis = Task.detached(priority: .utility) { AudioAnalysis.highBandShare(samples) }
        let text = await whisper.transcribe(samples)
        let highBand = await analysis.value
        Log.info("[Overlay] \(String(format: "%.1f", Double(samples.count) / 16000)) s → \(Int(Date().timeIntervalSince(started) * 1000)) ms, '\(whisper.activeModel?.id ?? "-")' \(whisper.isRunningOnGpu ? "GPU" : "CPU"), lang=\(whisper.language), 1–4 kHz \(highBand.map { String(format: "%.2f%%", $0 * 100) } ?? "n/a"): \"\(text)\"")

        chunk.text = text
        chunk.isFinal = true
        commitFinishedChunks()
        refreshCommentText()

        if closed || isRecording || chunks.contains(where: { !$0.isFinal }) { return }

        if let highBand, highBand < Self.muffledShare {
            // recognition can't be good when the consonants never reached the computer: say so plainly
            showStatus("Мікрофон звучить глухо — через це погано розпізнає. Послухайте себе: ▾ біля мікрофона", .warning)
        } else if !text.isEmpty {
            showStatus("Готово! Enter — зберегти і скопіювати, Пробіл — додати ще.", .success)
        } else if !whisper.isModelReady {
            showStatus(whisper.lastError ?? "Модель розпізнавання недоступна.", .error)
        } else if AudioAnalysis.isDigitalSilence(samples) {
            showStatus("«\(microphoneName)» передає повну тишу — оберіть інший мікрофон (▾ біля мікрофона).", .warning)
        } else if !AudioAnalysis.hasSpeech(samples) {
            showStatus("Не чути голосу — перевірте мікрофон (▾ біля мікрофона).", .warning)
        } else {
            showStatus("Не вдалося розпізнати мову — спробуйте ще раз чіткіше.", .warning)
        }
    }

    /// Moves finished fragments (in recording order) into the settled text.
    private func commitFinishedChunks() {
        while let first = chunks.first, first.isFinal {
            baseText = TranscriptCleaner.append(baseText, first.text)
            chunks.removeFirst()
        }
    }

    private func composeComment() -> String {
        var text = baseText
        for chunk in chunks {
            text = TranscriptCleaner.append(text, chunk.text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshCommentText() {
        updatingText = true
        let text = composeComment()
        if model.comment != text { model.comment = text }
        updatingText = false
        // while fragments are being transcribed the box is read-only (and grey for live previews)
        model.commentReadOnly = !chunks.isEmpty
        model.commentIsPreview = chunks.contains { !$0.isFinal }
    }

    /// The user typed in the comment box.
    func commentEdited() {
        if !updatingText && chunks.isEmpty {
            baseText = model.comment
        }
    }

    private func setRecordingVisuals(_ recording: Bool) {
        model.isRecording = recording
        if !recording {
            displayLevel = 0
            model.level = 0
        }
    }

    /// Microphone level from the audio thread (already hopped to the main thread).
    func levelChanged(_ level: Float) {
        guard isRecording else { return }
        displayLevel = max(level, displayLevel * 0.75) // fast attack, smooth release
        model.level = CGFloat(displayLevel)
    }

    func modelStateChanged() { updateIdleStatus() }

    private func updateIdleStatus() {
        if closed || isRecording || isSaving || !chunks.isEmpty || !pendingTranscriptions.isEmpty { return }
        switch whisper.state {
        case .ready:
            if let next = whisper.downloadingModel {
                showStatus("Говоріть або пишіть · модель «\(next.id)»: \(Formats.percent(whisper.downloadProgress))", .idle)
            } else {
                showStatus("Утримуйте Пробіл і говоріть, або пишіть", .idle)
            }
        case .downloading:
            showStatus("Завантажую модель розпізнавання… \(Formats.percent(whisper.downloadProgress)) — записувати вже можна.", .busy)
        case .failed:
            showStatus("Голос недоступний: \(whisper.lastError ?? "")", .error)
        default:
            showStatus("Запускаю модель розпізнавання…", .busy)
        }
    }

    /// Idle hints live in the comment placeholder; anything else gets the small status line.
    private func showStatus(_ text: String, _ kind: StatusKind) {
        if kind == .idle {
            model.placeholder = text
            model.status = nil
        } else {
            model.status = OverlayStatus(text: text, kind: kind)
        }
    }

    private var microphoneName: String {
        let uid = settings.selectedMicrophone
        if uid.isEmpty { return "Системний мікрофон" }
        return audio.microphones().first { $0.uid == uid }?.displayName ?? uid
    }

    private func updateMicrophoneTooltip() {
        model.microphoneTooltip = "Мікрофон: \(microphoneName) (клацніть, щоб змінити)"
    }

    func showMicrophoneMenu() {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        for mic in audio.microphones() {
            let item = ClosureMenuItem(title: mic.displayName) { [weak self] in
                guard let self else { return }
                self.settings.selectedMicrophone = mic.uid
                self.settings.save()
                self.audio.preferredMicrophone = mic.uid
                self.updateMicrophoneTooltip()
                self.panel.makeFirstResponder(self.canvas)
            }
            item.state = mic.uid == settings.selectedMicrophone ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let listen = ClosureMenuItem(title: "▶  Прослухати останній запис") { [weak self] in
            if self?.audio.playLast() == false {
                self?.showStatus("Не вдалося відтворити запис.", .warning)
            }
        }
        listen.isEnabled = audio.hasLastRecording && !isRecording
        listen.toolTip = "Так звучить ваш голос для розпізнавання. Якщо глухо чи тихо — справа в мікрофоні або його підключенні."
        menu.addItem(listen)
        menu.autoenablesItems = false

        let anchor = model.microphoneAnchor
        let point = model.toolbarAtBottom ? CGPoint(x: anchor.minX, y: anchor.minY - 6) : CGPoint(x: anchor.minX, y: anchor.maxY + 6)
        if model.toolbarAtBottom {
            menu.popUp(positioning: nil, at: CGPoint(x: point.x, y: point.y - menu.size.height), in: root)
        } else {
            menu.popUp(positioning: nil, at: point, in: root)
        }
    }

    // MARK: - Save

    func cancel() {
        if !isSaving { close() }
    }

    func save() {
        Task { await saveAsync() }
    }

    private func saveAsync() async {
        if isSaving || closed { return }
        if isSelecting { endSelectionDrag(commit: true) }
        commitLabelEdit() // a label still being typed is part of the picture
        isSaving = true
        closeFlyout()

        if isRecording { await endRecording() }

        // the annotations are rendered right here, so the window can go at once; encoding the PNG and
        // waiting for the voice text happen while the user moves on
        guard let image = ImageCompositor.render(capture: capture.image, cropPx: cropPixels(), scale: capture.scale, items: items) else {
            failSave("не вдалося зібрати зображення")
            return
        }
        panel.orderOut(nil)

        do {
            let settings = self.settings
            let saved = try await Task.detached(priority: .userInitiated) { try ImageCompositor.save(image, settings: settings) }.value
            let (comment, voiceLost) = await collectComment()

            var entry = ScreenshotHistoryItem()
            entry.imagePath = saved.path
            entry.transcribedText = comment
            entry.width = saved.width
            entry.height = saved.height
            entry.fileSizeBytes = saved.fileSizeBytes
            entry.createdAt = Date()
            await history.add(entry)

            let markdown = Clipboard.formatMarkdown(imagePath: saved.path, comment: comment)
            let copied = Clipboard.copy(markdown, imagePath: saved.path)
            var message = comment.isEmpty
                ? "Вставте (⌘V) у чат чи задачу — шлях до PNG і коментар уже в буфері."
                : "«\(comment)»"
            if voiceLost {
                message = "Голосовий коментар не встиг розпізнатися (модель ще готується). " + message
            }

            let share = shareItem
            ToastCenter.shared.show(ToastOptions(
                title: copied ? "Скопійовано в буфер обміну" : "Збережено, але буфер обміну зайнятий",
                message: message,
                kind: copied && !voiceLost ? .success : .warning,
                imagePath: saved.path,
                copyText: markdown,
                onOpenGallery: openGallery,
                actionText: share != nil ? "Посилання" : nil,
                onAction: share.map { share in { share(entry) } },
                durationMs: 5000))
            close()
        } catch {
            Log.error("[Overlay] Saving failed", error)
            failSave(error.localizedDescription)
        }
    }

    private func failSave(_ reason: String) {
        isSaving = false
        guard !closed else { return }
        panel.orderFrontRegardless()
        bringToFront()
        showStatus("Не вдалося зберегти: \(reason)", .error)
    }

    private func collectComment() async -> (String, Bool) {
        let pending = Array(pendingTranscriptions.values)
        if !pending.isEmpty && (whisper.state == .ready || whisper.state == .loading) {
            // normally ~1 s; never block the screenshot behind a model download
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for task in pending { await task.value }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
                await group.next()
                group.cancelAll()
            }
        }
        let voiceLost = chunks.contains { !$0.isFinal && $0.text.isEmpty }
        return (composeComment(), voiceLost)
    }

    // MARK: - Close

    func close() {
        if closed { return }
        closed = true
        flyoutTimer?.invalidate()
        if isRecording {
            isRecording = false
            audio.cancel()
        }
        panel.orderOut(nil)
        panel.close()
        onClosed?()
    }
}

/// A view whose origin is top-left, like WPF and the annotation model.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// NSMenuItem with a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
