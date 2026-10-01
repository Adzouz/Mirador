import AppKit
import SwiftUI

/// shadcn/ui "zinc" tokens, light and dark.
enum Theme {
    static let background = dynamic(light: 0xFFFFFF, dark: 0x09090B)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x0C0C0E)
    static let muted = dynamic(light: 0xF4F4F5, dark: 0x18181B)
    static let mutedForeground = dynamic(light: 0x71717A, dark: 0xA1A1AA)
    static let foreground = dynamic(light: 0x09090B, dark: 0xFAFAFA)
    static let border = dynamic(light: 0xE4E4E7, dark: 0x27272A)
    static let primary = dynamic(light: 0x18181B, dark: 0xFAFAFA)
    static let primaryForeground = dynamic(light: 0xFAFAFA, dark: 0x18181B)
    static let accent = dynamic(light: 0xF4F4F5, dark: 0x27272A)
    static let destructive = dynamic(light: 0xDC2626, dark: 0xEF4444)
    static let sidebar = dynamic(light: 0xFAFAFA, dark: 0x0F0F11)

    static let radius: CGFloat = 8

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: Card

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius + 2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius + 2).strokeBorder(Theme.border))
    }
}

struct CardHeader<Trailing: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.foreground)
                if let description {
                    Text(description).font(.system(size: 12)).foregroundStyle(Theme.mutedForeground)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, description: String? = nil) {
        self.init(title: title, description: description) { EmptyView() }
    }
}

// MARK: Badge

struct Badge: View {
    enum Variant { case secondary, outline, solid }
    let text: String
    var variant: Variant = .outline
    var color: Color?
    var mono = false

    var body: some View {
        HStack(spacing: 5) {
            if let color, variant == .outline {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text)
                .font(mono ? .system(size: 11, weight: .medium, design: .monospaced) : .system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(variant == .outline ? Theme.border : .clear))
    }

    private var foreground: Color {
        switch variant {
        case .solid: color ?? Theme.primaryForeground
        case .secondary: Theme.foreground
        case .outline: Theme.foreground
        }
    }

    private var background: Color {
        switch variant {
        case .solid: (color ?? Theme.primary).opacity(color == nil ? 1 : 0.16)
        case .secondary: Theme.muted
        case .outline: .clear
        }
    }
}

// MARK: Buttons

struct ShadButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, outline, ghost, destructive }
    enum Size { case sm, md, icon }
    var variant: Variant = .outline
    var size: Size = .sm

    func makeBody(configuration: Configuration) -> some View {
        ShadButton(configuration: configuration, variant: variant, size: size)
    }

    private struct ShadButton: View {
        let configuration: Configuration
        let variant: Variant
        let size: Size
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .labelStyle(TightLabelStyle())
                .lineLimit(1)
                .padding(.horizontal, size == .icon ? 0 : (size == .md ? 14 : 10))
                .frame(width: size == .icon ? 28 : nil, height: size == .md ? 32 : 28)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.radius - 2))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius - 2).strokeBorder(variant == .outline ? Theme.border : .clear))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius - 2))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var foreground: Color {
            switch variant {
            case .primary: Theme.primaryForeground
            case .destructive: .white
            default: Theme.foreground
            }
        }

        private var background: Color {
            switch variant {
            case .primary: hovering ? Theme.primary.opacity(0.88) : Theme.primary
            case .secondary: hovering ? Theme.accent : Theme.muted
            case .outline, .ghost: hovering ? Theme.accent : .clear
            case .destructive: hovering ? Theme.destructive.opacity(0.88) : Theme.destructive
            }
        }
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension View {
    func shadButton(_ variant: ShadButtonStyle.Variant = .outline, size: ShadButtonStyle.Size = .sm) -> some View {
        buttonStyle(ShadButtonStyle(variant: variant, size: size))
    }
}

/// A `Menu` that looks like an outline button.
struct ShadMenu<Label: View, Content: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    var body: some View {
        Menu { content } label: { label }
            .menuStyle(.button)
            .buttonStyle(ShadButtonStyle(variant: .outline))
            .menuIndicator(.visible)
            .fixedSize()
    }
}

// MARK: Input

struct ShadTextFieldStyle: TextFieldStyle {
    var large = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: large ? 14 : 13))
            .padding(.horizontal, 10)
            .frame(height: large ? 38 : 32)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius - 2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius - 2).strokeBorder(Theme.border))
    }
}

struct Muted: View {
    let text: String
    var size: CGFloat = 12

    init(_ text: String, size: CGFloat = 12) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text).font(.system(size: size)).foregroundStyle(Theme.mutedForeground)
    }
}
