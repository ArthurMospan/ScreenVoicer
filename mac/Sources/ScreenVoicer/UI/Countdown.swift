import AppKit
import SwiftUI

final class CountdownModel: ObservableObject {
    @Published var seconds = 3
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color(argb: 0x26FFFFFF), lineWidth: 2.5)
                // the brand lamp counts down
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let p = (1 - cos(t * .pi / 0.5)) / 2
                    Circle().fill(Theme.accent).frame(width: 14, height: 14).scaleEffect(1 + 0.6 * p)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                (Text("Знімок через ") + Text("\(model.seconds)").foregroundColor(Theme.accent) + Text(" с"))
                    .font(Theme.font(15, .semibold))
                    .foregroundColor(Theme.ink)
                Text("клацніть, щоб скасувати").font(Theme.font(11.5)).foregroundColor(Theme.muted)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 22)
        .padding(.vertical, 10)
        .darkCard(cornerRadius: 20)
        .contentShape(Rectangle())
        .onTapGesture(perform: cancel)
        .help("Клацніть, щоб скасувати")
    }
}

/// «Знімок через N с» at the top of the screen (CountdownWindow.xaml).
@MainActor
final class CountdownController {
    private let panel: NSPanel
    private let model = CountdownModel()
    private var cancelled = false

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CountdownView(model: model, cancel: { [weak self] in self?.cancelled = true }))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    private func fadeIn() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    /// Counts down and closes itself. Returns false if the user clicked to cancel.
    func run(seconds: Int) async -> Bool {
        let screen = ScreenCaptureService.screenUnderCursor()
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: area.midX - size.width / 2, y: area.maxY - 24 - size.height))
        fadeIn()

        var left = seconds
        while left > 0 && !cancelled {
            model.seconds = left
            for _ in 0..<10 where !cancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            left -= 1
        }
        panel.orderOut(nil)
        panel.close()
        return !cancelled
    }
}
