import AppKit
import SwiftUI

extension Color {
    /// 0xRRGGBB
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: 1)
    }

    /// 0xAARRGGBB, the way App.xaml writes colours (#2EFFFFFF = white at 18 %).
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// The design tokens of App.xaml (brand «Tally», matte glass). Keep both apps in sync: see PARITY.md.
enum Theme {
    static let accent = Color(rgb: 0xFF8A4C)
    static let accentLight = Color(rgb: 0xFFC68A)

    static let window = Color(rgb: 0x0F0F13)
    static let surface = Color(rgb: 0x17171D)
    static let raised = Color(rgb: 0x1E1E25)
    static let ink = Color(rgb: 0xF3F3F6)
    static let muted = Color(rgb: 0xAAAAB6)
    static let faint = Color(rgb: 0x6B6B78)
    static let line = Color(argb: 0x1FFFFFFF)
    static let subtle = Color(argb: 0x0DFFFFFF)
    static let danger = Color(rgb: 0xF87171)

    // Matte glass: flat frosted fills, one thin even edge, no sheen, no glow.
    static let glassEdge = Color(argb: 0x2EFFFFFF)
    static let glassText = Color(rgb: 0xF4F4F7)
    static let glassMuted = Color(rgb: 0xCFCFD6)
    static let glassTint = Color(argb: 0xA6202028)
    static let primaryFill = Color(argb: 0xEBFFFFFF)
    static let primaryInk = Color(rgb: 0x1D1D22)
    static let recordFill = Color(rgb: 0xFF4D5E)
    static let activeTint = Color(argb: 0x38FFFFFF)
    static let hoverTint = Color(argb: 0x1AFFFFFF)
    static let pressedTint = Color(argb: 0x2BFFFFFF)
    static let buttonInk = Color(rgb: 0xECECF1)

    static let menuMuted = Color(rgb: 0xBDBDC7)
    static let menuFaint = Color(rgb: 0x8F8F9B)

    static let green = Color(rgb: 0x4ADE80)
    static let amber = Color(rgb: 0xFBBF24)
    static let red = Color(rgb: 0xF87171)

    /// Opaque dark card used by toasts, the countdown and dialogs (#F51B1B21).
    static let card = Color(argb: 0xF51B1B21)

    /// Annotation palette, keys 1–6.
    static let swatches: [(name: String, rgb: UInt32)] = [
        ("Червоний", 0xEF4444), ("Жовтий", 0xFACC15), ("Зелений", 0x22C55E),
        ("Синій", 0x3B82F6), ("Чорний", 0x18181B), ("Білий", 0xFFFFFF)
    ]

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// «Screen» + «Voicer» in the accent colour, as in every header of the Windows app.
struct Wordmark: View {
    var size: CGFloat = 15

    var body: some View {
        (Text("Screen").foregroundColor(Theme.glassText) + Text("Voicer").foregroundColor(Theme.accent))
            .font(Theme.font(size, .semibold))
    }
}
