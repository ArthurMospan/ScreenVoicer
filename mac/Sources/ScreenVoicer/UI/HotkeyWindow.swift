import AppKit
import SwiftUI

@MainActor
final class HotkeyModel: ObservableObject {
    enum Tone { case muted, warning, error }

    @Published var keys: [String] = []
    @Published var status = ""
    @Published var tone: Tone = .muted
    var candidate: HotkeyGesture?
    let defaultGesture = HotkeyGesture.parse(Settings.defaultHotkey)!
    var apply: (HotkeyGesture) -> Bool = { _ in false }
    var close: () -> Void = {}

    init(current: HotkeyGesture) {
        candidate = current
        show(current.modifiers, current.keyCode)
        setStatus("Зараз: \(current.displayText)", .muted)
    }

    func setStatus(_ text: String, _ tone: Tone) {
        status = text
        self.tone = tone
    }

    func show(_ modifiers: HotkeyGesture.Modifiers, _ keyCode: UInt32?) {
        keys = HotkeyGesture.keycaps(modifiers) + [keyCode.flatMap(HotkeyGesture.keyName) ?? "…"]
    }

    /// keyDown in the window (HotkeyWindow.xaml.cs OnPreviewKeyDown).
    func keyDown(_ event: NSEvent) -> Bool {
        let modifiers = HotkeyGesture.modifiers(from: event.modifierFlags)
        if modifiers.isEmpty {
            switch Int(event.keyCode) {
            case 53: close(); return true      // Esc
            case 36, 76: save(); return true   // Return
            case 48: return false              // Tab: keep keyboard navigation
            default: break
            }
        }
        capture(modifiers, event.keyCode)
        return true
    }

    func flagsChanged(_ event: NSEvent) {
        if candidate == nil || !(candidate?.isValid ?? false) {
            show(HotkeyGesture.modifiers(from: event.modifierFlags), nil)
        }
    }

    private func capture(_ modifiers: HotkeyGesture.Modifiers, _ code: UInt16) {
        if HotkeyGesture.isModifierKey(code) {
            show(modifiers, nil) // "⌥ Option + …" while the user is still pressing
            return
        }
        let gesture = HotkeyGesture(modifiers: modifiers, keyCode: UInt32(code))
        show(modifiers, UInt32(code))
        if !gesture.isValid {
            candidate = nil
            setStatus("Додайте ⌃, ⌥, ⇧ або ⌘ — інакше клавіша заважатиме друкувати.", .warning)
            return
        }
        if gesture.isReserved {
            candidate = nil
            setStatus("\(gesture.displayText) потрібна іншим програмам і macOS — оберіть іншу комбінацію.", .warning)
            return
        }
        candidate = gesture
        setStatus("Натисніть «Зберегти» або Enter.", .muted)
    }

    func save() {
        guard let candidate, candidate.isValid else {
            setStatus("Спершу натисніть комбінацію клавіш.", .warning)
            return
        }
        if apply(candidate) {
            close()
        } else {
            setStatus("\(candidate.displayText) вже зайнята іншою програмою або macOS — спробуйте іншу.", .error)
        }
    }

    func useDefault() {
        candidate = defaultGesture
        show(defaultGesture.modifiers, defaultGesture.keyCode)
        setStatus("Натисніть «Зберегти» або Enter.", .muted)
    }
}

struct HotkeyView: View {
    @ObservedObject var model: HotkeyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.activeTint)
                    RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.glassEdge, lineWidth: 1)
                    GlyphIcon(icon: .keyboard, size: 19).foregroundColor(Theme.accentLight)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Гаряча клавіша для знімка").font(Theme.font(18, .semibold)).foregroundColor(Theme.ink)
                    Text("Натисніть нову комбінацію, наприклад ⌃⇧X або F9.").font(Theme.font(13)).foregroundColor(Theme.muted)
                }
            }

            HStack(spacing: 4) {
                ForEach(Array(model.keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 {
                        Text("+").font(Theme.font(16)).foregroundColor(Theme.muted).padding(.horizontal, 2)
                    }
                    Text(key)
                        .font(Theme.font(16, .semibold))
                        .foregroundColor(key == "…" ? Theme.muted : Theme.ink)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .frame(minWidth: 42)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(argb: 0x26FFFFFF)).offset(y: 2)
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(rgb: 0x2A2A32))
                                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(argb: 0x26FFFFFF), lineWidth: 1)
                            }
                        )
                        .padding(3)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(argb: 0x0AFFFFFF)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .padding(.top, 18)

            Text(model.status)
                .font(Theme.font(12.5))
                .foregroundColor(model.tone == .error ? Theme.red : model.tone == .warning ? Theme.amber : Theme.muted)
                .frame(minHeight: 18, alignment: .topLeading)
                .padding(.leading, 2)
                .padding(.top, 12)

            HStack(spacing: 10) {
                Button("За замовчуванням (\(model.defaultGesture.displayText))") { model.useDefault() }
                    .buttonStyle(TextPillButtonStyle(horizontalPadding: 10))
                Spacer()
                Button("Скасувати") { model.close() }.buttonStyle(OutlineButtonStyle(horizontalPadding: 14))
                Button("Зберегти") { model.save() }.buttonStyle(PrimaryButtonStyle(horizontalPadding: 18))
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: 494)
        .darkCard(cornerRadius: 18)
    }
}

/// The hotkey dialog (HotkeyWindow.xaml): a draggable dark card that captures the keys pressed.
@MainActor
final class HotkeyWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: HotkeyModel
    private var monitor: Any?
    var onClosed: (() -> Void)?

    init(current: HotkeyGesture, apply: @escaping (HotkeyGesture) -> Bool) {
        model = HotkeyModel(current: current)
        let host = NSHostingView(rootView: HotkeyView(model: model))
        let size = host.fittingSize
        window = KeyableWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.title = "ScreenVoicer — гаряча клавіша"
        window.delegate = self
        model.apply = apply
        model.close = { [weak self] in self?.window.close() }
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .flagsChanged {
                self.model.flagsChanged(event)
                return event
            }
            return self.model.keyDown(event) ? nil : event
        }
    }

    func activate() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onClosed?()
    }
}

/// A borderless window that can take the keyboard.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
