import AppKit
import SwiftUI

/// Tokens from the Clay design system: warm paper grounds, one clay accent,
/// serif for headings and sans for interface. Type uses the system faces in
/// Clay's fallback stacks (New York, SF Pro, SF Mono) so the app stays offline
/// and ships no extra font files.
enum Clay {
    // MARK: Color

    static let ivory = dynamic(0xFAF9F5, 0x262624)
    static let surface = dynamic(0xFFFFFF, 0x30302E)
    static let sunken = dynamic(0xF0EEE6, 0x1F1E1D)
    static let hairline = dynamic(0xE8E6DC, 0x3E3E38, highContrast: (0x8F8D84, 0x83817A))
    static let borderStrong = dynamic(0x8F8D84, 0x83817A)
    static let ink = dynamic(0x141413, 0xFAF9F5)
    static let inkMuted = dynamic(0x5E5D59, 0xC2C0B6)
    static let clay = dynamic(0xC96442, 0xD97757)
    static let accent = dynamic(0xAE5630, 0xAE5630)
    static let accentHover = dynamic(0x9A4A28, 0xC4633F)
    static let accentText = dynamic(0x9C4A2A, 0xE08A6D)
    static let onAccent = dynamic(0xFFFFFF, 0xFFFFFF)
    static let claySoft = dynamic(0xF5E4DA, 0x4A3128)
    static let manilla = dynamic(0xEBDBBC, 0x5C4D36)
    static let success = dynamic(0x2F6B3A, 0x9FD3A8)
    static let successSoft = dynamic(0xE6EFE3, 0x2A3A2C)
    static let warning = dynamic(0x8A5A0B, 0xE9C27A)
    static let warningSoft = dynamic(0xF6ECD6, 0x3D3424)
    static let danger = dynamic(0xA33A2C, 0xF0A596)
    static let dangerSoft = dynamic(0xF7E3DF, 0x402B27)
    static let focus = dynamic(0x2C84DB, 0x61AAF2)

    // MARK: Space and shape

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let space8: CGFloat = 32
    static let space12: CGFloat = 48

    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 8
    static let radiusLarge: CGFloat = 12

    /// Readable width for the detail column.
    static let contentWidth: CGFloat = 860

    // MARK: Type

    static let display = Font.system(size: 40, weight: .regular, design: .serif)
    static let heading1 = Font.system(size: 32, weight: .regular, design: .serif)
    static let heading2 = Font.system(size: 24, weight: .medium, design: .serif)
    static let heading3 = Font.system(size: 16, weight: .semibold)
    static let body = Font.system(size: 15)
    static let bodyMedium = Font.system(size: 15, weight: .medium)
    static let label = Font.system(size: 14, weight: .medium)
    static let caption = Font.system(size: 12)
    static let captionMedium = Font.system(size: 12, weight: .medium)
    static let code = Font.system(size: 12.5, design: .monospaced)

    private static func dynamic(
        _ light: UInt32,
        _ dark: UInt32,
        highContrast: (light: UInt32, dark: UInt32)? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let isHighContrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            let value: UInt32
            if isHighContrast, let highContrast {
                value = isDark ? highContrast.dark : highContrast.light
            } else {
                value = isDark ? dark : light
            }
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Status tones

/// The only meanings colour carries in this app. Each tone pairs a text colour
/// with its own soft ground, as Clay specifies for status colours.
enum ClayTone: Equatable, Sendable {
    case neutral
    case progress
    case success
    case warning
    case danger

    var foreground: Color {
        switch self {
        case .neutral: Clay.inkMuted
        case .progress: Clay.accentText
        case .success: Clay.success
        case .warning: Clay.warning
        case .danger: Clay.danger
        }
    }

    var background: Color {
        switch self {
        case .neutral: Clay.sunken
        case .progress: Clay.claySoft
        case .success: Clay.successSoft
        case .warning: Clay.warningSoft
        case .danger: Clay.dangerSoft
        }
    }

    var symbol: String {
        switch self {
        case .neutral: "circle"
        case .progress: "circle.dotted"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "xmark.octagon"
        }
    }
}

// MARK: - Surfaces

private struct ClayCard: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Clay.surface, in: RoundedRectangle(cornerRadius: Clay.radiusLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Clay.radiusLarge, style: .continuous)
                    .strokeBorder(Clay.hairline, lineWidth: 1)
            }
    }
}

extension View {
    /// A raised Clay card: surface ground, hairline border, large radius, no shadow.
    func clayCard(padding: CGFloat = Clay.space6) -> some View {
        modifier(ClayCard(padding: padding))
    }
}

/// Card title in the interface sans, with an optional trailing accessory.
struct ClayCardHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Clay.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Clay.heading3)
                    .foregroundStyle(Clay.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Clay.space3)
            accessory
        }
    }
}

extension ClayCardHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Badge and banner

struct ClayBadge: View {
    let text: String
    var tone: ClayTone = .neutral
    var showsDot = false

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(tone.foreground).frame(width: 6, height: 6)
            }
            Text(text)
        }
        .font(Clay.captionMedium)
        .foregroundStyle(tone.foreground)
        .lineLimit(1)
        .padding(.horizontal, Clay.space2)
        .padding(.vertical, 2)
        .background(tone.background, in: RoundedRectangle(cornerRadius: Clay.radiusSmall, style: .continuous))
    }
}

/// One verdict per screen: what we know about the file and what to do next.
struct ClayBanner<Accessory: View>: View {
    let tone: ClayTone
    let title: String
    var message: String?
    var showsProgress = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: Clay.space3) {
            Group {
                if showsProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 15, weight: .regular))
                }
            }
            .foregroundStyle(tone.foreground)
            .frame(width: 18, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Clay.bodyMedium)
                    .foregroundStyle(tone.foreground)
                if let message, !message.isEmpty {
                    // No vertical fixedSize: banners also sit in fixed headers, where a
                    // fixed text height measured at a narrow width inflates the window's
                    // minimum height and pushes content under the toolbar.
                    Text(message)
                        .font(Clay.body)
                        .foregroundStyle(Clay.ink)
                        .lineSpacing(3)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Clay.space3)
            accessory
        }
        .padding(.horizontal, Clay.space4)
        .padding(.vertical, Clay.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: RoundedRectangle(cornerRadius: Clay.radiusLarge, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension ClayBanner where Accessory == EmptyView {
    init(tone: ClayTone, title: String, message: String? = nil, showsProgress: Bool = false) {
        self.init(tone: tone, title: title, message: message, showsProgress: showsProgress) { EmptyView() }
    }
}

// MARK: - Buttons

struct ClayButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ghost
        case destructive
    }

    var kind: Kind = .secondary
    var isLarge = false

    func makeBody(configuration: Configuration) -> some View {
        ClayButtonBody(configuration: configuration, kind: kind, isLarge: isLarge)
    }
}

private struct ClayButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ClayButtonStyle.Kind
    let isLarge: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(Clay.label)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, isLarge ? Clay.space4 : Clay.space3)
            .padding(.vertical, isLarge ? 9 : 6)
            .background(background, in: RoundedRectangle(cornerRadius: Clay.radiusMedium, style: .continuous))
            .overlay {
                if kind == .secondary || kind == .destructive {
                    RoundedRectangle(cornerRadius: Clay.radiusMedium, style: .continuous)
                        .strokeBorder(Clay.borderStrong.opacity(0.7), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Clay.radiusMedium, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Clay.onAccent
        case .secondary, .ghost: Clay.ink
        case .destructive: Clay.danger
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary:
            return pressed || isHovered ? Clay.accentHover : Clay.accent
        case .secondary, .destructive:
            return pressed ? Clay.hairline : (isHovered ? Clay.sunken : Clay.surface)
        case .ghost:
            return pressed ? Clay.hairline : (isHovered ? Clay.sunken : .clear)
        }
    }
}

extension ButtonStyle where Self == ClayButtonStyle {
    static var clayPrimary: ClayButtonStyle { ClayButtonStyle(kind: .primary) }
    static var claySecondary: ClayButtonStyle { ClayButtonStyle(kind: .secondary) }
    static var clayGhost: ClayButtonStyle { ClayButtonStyle(kind: .ghost) }
    static var clayDestructive: ClayButtonStyle { ClayButtonStyle(kind: .destructive) }
}

/// Inline link-style action in accessible clay text.
struct ClayLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Clay.captionMedium)
            .foregroundStyle(Clay.accentText)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Text field

/// A single-line field with a visible boundary in both themes and a cool
/// focus ring, so focus is never mistaken for the brand colour.
struct ClayTextField: View {
    let label: String
    @Binding var text: String
    var prompt = "Not set"
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Clay.inkMuted))
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(Clay.body)
            .foregroundStyle(Clay.ink)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Clay.surface, in: RoundedRectangle(cornerRadius: Clay.radiusMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Clay.radiusMedium, style: .continuous)
                    .strokeBorder(isFocused ? Clay.focus : Clay.borderStrong.opacity(0.75), lineWidth: isFocused ? 2 : 1)
            }
            .accessibilityLabel(label)
    }
}

// MARK: - Tabs

struct ClayTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var badge: (Tab) -> String? = { _ in nil }
    var identifier: (Tab) -> String

    var body: some View {
        HStack(spacing: Clay.space6) {
            ForEach(tabs) { tab in
                ClayTabButton(
                    title: title(tab),
                    badge: badge(tab),
                    isSelected: selection == tab
                ) {
                    selection = tab
                }
                .accessibilityIdentifier(identifier(tab))
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ClayTabButton: View {
    let title: String
    let badge: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Clay.label)
                        .foregroundStyle(isSelected || isHovered ? Clay.ink : Clay.inkMuted)
                    if let badge {
                        Text(badge)
                            .font(Clay.captionMedium)
                            .monospacedDigit()
                            .foregroundStyle(Clay.inkMuted)
                            .padding(.horizontal, 6)
                            .background(Clay.sunken, in: Capsule())
                    }
                }
                Rectangle()
                    .fill(isSelected ? Clay.accent : .clear)
                    .frame(height: 2)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Rows

/// A setting with a title, an explanation and a trailing switch.
struct ClayToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var identifier: String?

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Clay.bodyMedium)
                    .foregroundStyle(Clay.ink)
                Text(detail)
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier ?? title)
    }
}

/// Label and value in the two aligned columns used across detail cards.
struct ClayKeyValueRow: View {
    let key: String
    let value: String?
    var monospaced = false

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(key)
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .gridColumnAlignment(.leading)
            Text(value?.isEmpty == false ? value! : "Not provided")
                .font(monospaced ? Clay.code : Clay.body)
                .foregroundStyle(value?.isEmpty == false ? Clay.ink : Clay.inkMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A plain disclosure in caption type for secondary detail.
struct ClayDisclosure<Content: View>: View {
    let title: String
    @State private var isExpanded = false
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, Clay.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(Clay.captionMedium)
                .foregroundStyle(Clay.inkMuted)
                .contentShape(Rectangle())
                .onTapGesture { isExpanded.toggle() }
        }
    }
}

/// Small rounded tile that holds a line icon.
struct ClayIconTile: View {
    let systemImage: String
    var size: CGFloat = 40
    var tint: Color = Clay.inkMuted

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Clay.sunken, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .strokeBorder(Clay.hairline, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
