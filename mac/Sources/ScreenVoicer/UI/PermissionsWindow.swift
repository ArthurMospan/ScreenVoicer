import AppKit
import SwiftUI

/// macOS only: Screen Recording and Microphone need the user's consent (Windows asks for neither).
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var screen = Permissions.screenGranted
    @Published var microphone = Permissions.microphoneGranted
    @Published var microphoneUndecided = Permissions.microphoneUndecided
    /// Granted while running: macOS applies screen access only after a restart.
    @Published var needsRestart = false
    private var screenAtStart = Permissions.screenGranted
    var close: () -> Void = {}
    var restart: () -> Void = {}

    func refresh() {
        let nowScreen = Permissions.screenGranted
        if nowScreen && !screenAtStart { needsRestart = true }
        screen = nowScreen
        microphone = Permissions.microphoneGranted
        microphoneUndecided = Permissions.microphoneUndecided
    }

    func allowScreen() {
        // The system prompt appears only the first time; afterwards macOS offers System Settings.
        if !ScreenCaptureService.requestPermission() {
            Permissions.openScreenRecordingSettings()
        }
    }

    func allowMicrophone() {
        if microphoneUndecided {
            Permissions.requestMicrophone { [weak self] _ in self?.refresh() }
        } else {
            Permissions.openMicrophoneSettings()
        }
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                BrandMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Дозволи для ScreenVoicer").font(Theme.font(18, .semibold)).foregroundColor(Theme.ink)
                    Text("macOS питає один раз. Без них знімки й голос не працюватимуть.")
                        .font(Theme.font(13)).foregroundColor(Theme.muted)
                }
            }
            .padding(.bottom, 18)

            permissionRow(icon: .screen, title: "Запис екрана",
                          detail: "Щоб зробити знімок. Натисніть «Дозволити»: відкриються налаштування — увімкніть там перемикач біля ScreenVoicer. Apple не дає програмам вмикати його самим, а ScreenVoicer помітить це сам.",
                          granted: model.screen, action: "Дозволити", perform: model.allowScreen)
            permissionRow(icon: .mic, title: "Мікрофон",
                          detail: "Щоб надиктувати коментар до знімка: затисніть Пробіл і говоріть.",
                          granted: model.microphone, action: model.microphoneUndecided ? "Дозволити" : "Відкрити налаштування",
                          perform: model.allowMicrophone)
                .padding(.top, 10)

            Text(model.needsRestart
                 ? "Запис екрана дозволено. macOS увімкне його після перезапуску ScreenVoicer."
                 : "Раз на місяць macOS перепитує дозвіл на запис екрана — натисніть «Дозволити».")
                .font(Theme.font(12.5))
                .foregroundColor(model.needsRestart ? Theme.amber : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack(spacing: 10) {
                Spacer()
                if model.needsRestart {
                    Button("Перезапустити ScreenVoicer", action: model.restart).buttonStyle(PrimaryButtonStyle(horizontalPadding: 16))
                } else {
                    Button("Готово", action: model.close).buttonStyle(PrimaryButtonStyle(horizontalPadding: 18))
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: 520)
        .darkCard(cornerRadius: 18)
        .onReceive(timer) { _ in model.refresh() }
    }

    private func permissionRow(icon: Icon, title: String, detail: String, granted: Bool, action: String,
                               perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(granted ? Theme.green.opacity(0.18) : Theme.activeTint)
                GlyphIcon(icon: granted ? .check : icon, size: 19, weight: granted ? 2.4 : 1.9)
                    .foregroundColor(granted ? Theme.green : Theme.accentLight)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(14, .semibold)).foregroundColor(Theme.ink)
                Text(detail).font(Theme.font(12.5)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text("Дозволено").font(Theme.font(12.5, .semibold)).foregroundColor(Theme.green).padding(.top, 8)
            } else {
                Button(action, action: perform).buttonStyle(OutlineButtonStyle()).fixedSize()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(argb: 0x0FFFFFFF)))
    }
}

@MainActor
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    let model = PermissionsModel()
    var onClosed: (() -> Void)?

    override init() {
        let host = NSHostingView(rootView: PermissionsView(model: model))
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
        window.delegate = self
        model.close = { [weak self] in self?.window.close() }
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClosed?() }

    func windowDidResize(_ notification: Notification) {}
}
