import SwiftUI

/// Hover state for button styles (ButtonStyle itself has only isPressed).
private struct HoverBody<Content: View>: View {
    let content: (Bool) -> Content
    @State private var hover = false

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(hover).onHover { hover = $0 }
    }
}

/// Round 34 px icon button of the toolbar (PillButton / ActiveButton in OverlayWindow.xaml).
struct GlassIconButtonStyle: ButtonStyle {
    var active = false
    var width: CGFloat = 34
    var height: CGFloat = 34
    var cornerRadius: CGFloat = 17

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, style: self)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let style: GlassIconButtonStyle
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .foregroundColor(style.active || hover ? .white : Theme.buttonInk)
                .frame(width: style.width, height: style.height)
                .background(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous).fill(fill))
                .contentShape(Rectangle())
                .onHover { hover = $0 && enabled }
                .opacity(enabled ? 1 : 0.35)
        }

        private var fill: Color {
            if style.active { return hover ? Color(argb: 0x47FFFFFF) : Theme.activeTint }
            if configuration.isPressed { return Theme.pressedTint }
            return hover ? Theme.hoverTint : .clear
        }
    }
}

/// Save: a 34 px rounded square of denser glass with a thin white edge — set apart from the round tools.
struct SaveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody { hover in
            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            configuration.label
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(shape.fill(Color(argb: configuration.isPressed ? 0x40FFFFFF : hover ? 0x6BFFFFFF : 0x57FFFFFF)))
                .overlay(shape.strokeBorder(Color(argb: 0x80FFFFFF), lineWidth: 1))
                .contentShape(Rectangle())
        }
    }
}

/// Primary action: white matte with dark ink and an orange icon («Зробити знімок», «Новий знімок»).
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var horizontalPadding: CGFloat = 14
    var fontSize: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, style: self)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let style: PrimaryButtonStyle
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(Theme.font(style.fontSize, .semibold))
                .foregroundColor(Theme.primaryInk)
                .padding(.horizontal, style.horizontalPadding)
                .frame(height: style.height)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(argb: configuration.isPressed ? 0xD9FFFFFF : hover ? 0xFFFFFFFF : 0xEBFFFFFF)))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .opacity(enabled ? 1 : 0.45)
        }
    }
}

/// Secondary action: frosted glass with a thin edge.
struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var horizontalPadding: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        HoverBody { hover in
            let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
            configuration.label
                .font(Theme.font(12.5, .semibold))
                .foregroundColor(Theme.ink)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(shape.fill(Color(argb: configuration.isPressed ? 0x33FFFFFF : hover ? 0x26FFFFFF : 0x14FFFFFF)))
                .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
                .contentShape(Rectangle())
        }
    }
}

/// Text button without a frame; a frosted fill appears on hover (App.xaml PillButton).
struct TextPillButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var horizontalPadding: CGFloat = 12
    var fontSize: CGFloat = 12.5
    var ink: Color = Color(rgb: 0xE2E2E8)

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, style: self)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let style: TextPillButtonStyle
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(Theme.font(style.fontSize, .semibold))
                .foregroundColor(hover ? .white : style.ink)
                .padding(.horizontal, style.horizontalPadding)
                .frame(height: style.height)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(configuration.isPressed ? Theme.pressedTint : hover ? Theme.hoverTint : .clear))
                .contentShape(Rectangle())
                .onHover { hover = $0 && enabled }
                .opacity(enabled ? 1 : 0.35)
        }
    }
}

/// Small frosted chip (gallery cards, toasts).
struct ChipButtonStyle: ButtonStyle {
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody { hover in
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            configuration.label
                .font(Theme.font(11.5, .semibold))
                .foregroundColor(hover ? .white : danger ? Theme.danger : Color(rgb: 0xE8E8ED))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .frame(minHeight: 28)
                .background(shape.fill(hover ? (danger ? Color(argb: 0x59EF4444) : Color(argb: 0x26FFFFFF)) : Color(argb: 0x12FFFFFF)))
                .overlay(shape.strokeBorder(Color(argb: 0x1AFFFFFF), lineWidth: 1))
                .contentShape(Rectangle())
        }
    }
}

/// A line of the menu-bar menu: glass highlight on hover.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(Theme.font(13.5))
                .foregroundColor(Theme.glassText)
                .padding(.leading, 9)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? Color(argb: 0x22FFFFFF) : hover ? Color(argb: 0x1FFFFFFF) : .clear))
                .contentShape(Rectangle())
                .onHover { hover = $0 && enabled }
                .opacity(enabled ? 1 : 0.45)
        }
    }
}

/// Glass chip of the menu: delay buttons, the language switch.
struct MenuChipStyle: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody { hover in
            configuration.label
                .font(Theme.font(12.5, .semibold))
                .foregroundColor(on || hover ? .white : Color(rgb: 0xE6E6EC))
                .padding(.horizontal, 11)
                .padding(.top, 6)
                .padding(.bottom, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(on ? Theme.activeTint : hover ? Color(argb: 0x26FFFFFF) : Color(argb: 0x14FFFFFF)))
                .contentShape(Rectangle())
        }
    }
}
