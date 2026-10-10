import AppKit
import SwiftUI

/// --snapshots renders views offscreen, where NSVisualEffectView can't draw: it then uses a flat stand-in colour.
enum RenderMode {
    static var snapshot = false
}

/// The real macOS material (dark), masked to a rounded rectangle.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blending
        view.maskImage = cornerRadius > 0 ? Self.mask(radius: cornerRadius) : nil
    }

    static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Matte glass: the frosted material, a light neutral tint and one thin even edge. No sheen, no glow, no gradient.
struct GlassBackground: View {
    var cornerRadius: CGFloat
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var tint: Color = Color(argb: 0x40202028)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if RenderMode.snapshot {
                Color(rgb: 0x2B2B33)
            } else {
                VisualEffectBlur(material: .hudWindow, blending: blending, cornerRadius: cornerRadius)
            }
            tint
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
    }
}

extension View {
    /// A glass panel with the soft drop shadow of the Windows GlassShadow (blur 28, depth 5, 35 %).
    func glassPanel(cornerRadius: CGFloat, blending: NSVisualEffectView.BlendingMode = .withinWindow, shadow: Bool = true) -> some View {
        background(GlassBackground(cornerRadius: cornerRadius, blending: blending))
            .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 14, x: 0, y: 5)
    }

    /// The opaque dark card of toasts, the countdown and dialogs (#F51B1B21 + thin rim).
    func darkCard(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(Theme.card))
            .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
    }
}
