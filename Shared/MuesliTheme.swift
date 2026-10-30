import SwiftUI
import UIKit

enum MuesliTheme {
    static let backgroundDeep = Color.adaptive(dark: 0x0B0C0E, light: 0xF3F4F6)
    static let backgroundBase = Color.adaptive(dark: 0x161719, light: 0xF8F9FA)
    static let backgroundRaised = Color.adaptive(dark: 0x1E2023, light: 0xFFFFFF)
    static let backgroundHover = Color.adaptive(dark: 0x252A32, light: 0xE8EEF8)

    static let surfacePrimary = Color.adaptive(dark: 0x25272B, light: 0xEFF1F4)
    static let surfaceSelected = Color.adaptive(dark: 0x2A3243, light: 0xE4EEFF)
    static let surfaceBorder = Color.adaptiveAlpha(
        dark: .white,
        darkAlpha: 0.12,
        light: .black,
        lightAlpha: 0.10
    )

    static let textPrimary = Color.adaptiveAlpha(
        dark: .white,
        darkAlpha: 0.92,
        light: .black,
        lightAlpha: 0.88
    )
    static let textSecondary = Color.adaptiveAlpha(
        dark: .white,
        darkAlpha: 0.72,
        light: .black,
        lightAlpha: 0.66
    )
    static let textTertiary = Color.adaptiveAlpha(
        dark: .white,
        darkAlpha: 0.55,
        light: .black,
        lightAlpha: 0.55
    )

    static var defaultAccent: Color { color(for: .blue) }
    static var accent: Color { color(for: selectedAccentTheme) }
    static var accentSubtle: Color { accent.opacity(0.14) }

    static let onAccent = Color.adaptive(dark: 0x0B0C0E, light: 0xFFFFFF)

    static let brandBlue = Color(hex: 0x69A1FF)
    static let brandBlueSubtle = Color.adaptive(dark: 0x18253A, light: 0xE6F0FF)
    static let syncGreen = Color(hex: 0x34D8C3)
    static let syncGreenSubtle = Color.adaptive(dark: 0x173633, light: 0xDCFDF6)
    static let glassHighlight = Color.adaptiveAlpha(
        dark: .white,
        darkAlpha: 0.10,
        light: .white,
        lightAlpha: 0.52
    )
    static let glassShadow = Color.adaptiveAlpha(
        dark: .black,
        darkAlpha: 0.22,
        light: .black,
        lightAlpha: 0.045
    )

    static let recording = Color(hex: 0x69A1FF)
    static let transcribing = Color(hex: 0x6BA3F7)
    static let success = syncGreen
    static let recordingStop = Color.adaptive(dark: 0x19704F, light: 0x126544)
    static let destructive = Color.adaptive(dark: 0xFF453A, light: 0xD70015)
    static var destructiveSubtle: Color { destructive.opacity(0.16) }

    // Match macOS PR #705's family, with iOS-sized, Dynamic Type-aware roles.
    // UIAppFonts registers the bundled faces once at process launch.
    static func font(size: CGFloat, weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        let face: String
        switch weight {
        case .bold, .heavy, .black: face = "Bold"
        case .semibold: face = "SemiBold"
        case .medium: face = "Medium"
        default: face = "Regular"
        }
        return .custom("NunitoSans-\(face)", size: size, relativeTo: style)
    }

    static func title1() -> Font { font(size: 28, weight: .bold, relativeTo: .title) }
    static func title2() -> Font { font(size: 22, weight: .semibold, relativeTo: .title2) }
    static func title3() -> Font { font(size: 19, weight: .semibold, relativeTo: .headline) }
    static func headline() -> Font { font(size: 16, weight: .semibold, relativeTo: .callout) }
    static func body() -> Font { font(size: 16, relativeTo: .body) }
    static let transcriptPointSize: CGFloat = 17
    static func transcript() -> Font { font(size: transcriptPointSize, relativeTo: .body) }

    /// UIKit measurement must use the same face, base size and scaling as SwiftUI.
    static func transcriptUIFont(compatibleWith traits: UITraitCollection) -> UIFont {
        let base = UIFont(name: "NunitoSans-Regular", size: transcriptPointSize)
            ?? UIFont.systemFont(ofSize: transcriptPointSize)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traits)
    }
    static func callout() -> Font { font(size: 15, relativeTo: .subheadline) }
    static func caption() -> Font { font(size: 13, relativeTo: .footnote) }
    static func captionMedium() -> Font { font(size: 13, weight: .medium, relativeTo: .footnote) }

    static let spacing4: CGFloat = 4
    static let spacing8: CGFloat = 8
    static let spacing12: CGFloat = 12
    static let spacing16: CGFloat = 16
    static let spacing20: CGFloat = 20
    static let spacing24: CGFloat = 24
    static let spacing32: CGFloat = 32

    static let cornerSmall: CGFloat = 8
    static let cornerMedium: CGFloat = 12
    static let cornerLarge: CGFloat = 16
    static let cornerXL: CGFloat = 22

    enum Navigation {
        static let horizontalInset: CGFloat = 28
        static let itemSpacing: CGFloat = 4
        static let itemHeight: CGFloat = 44
        static let containerPadding: CGFloat = 5
        static let containerCornerRadius: CGFloat = 18
        static let selectionCornerRadius: CGFloat = 12
    }

    static func color(for accent: MuesliAccentTheme) -> Color {
        Color.adaptive(dark: accent.darkHex, light: accent.lightHex)
    }

    private static var selectedAccentTheme: MuesliAccentTheme {
        MuesliAccentTheme.resolved(
            rawValue: UserDefaults.standard.string(forKey: "muesli.appearance.accent") ?? ""
        )
    }
}

private struct MuesliAccentEnvironmentKey: EnvironmentKey {
    static let defaultValue = MuesliTheme.accent
}

extension EnvironmentValues {
    var muesliAccent: Color {
        get { self[MuesliAccentEnvironmentKey.self] }
        set { self[MuesliAccentEnvironmentKey.self] = newValue }
    }
}

extension Color {
    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    static func adaptive(dark: Int, light: Int) -> Color {
        Color(uiColor: UIColor { traitCollection in
            let hex = traitCollection.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1.0
            )
        })
    }

    static func adaptiveAlpha(
        dark: UIColor,
        darkAlpha: CGFloat,
        light: UIColor,
        lightAlpha: CGFloat
    ) -> Color {
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark
                ? dark.withAlphaComponent(darkAlpha)
                : light.withAlphaComponent(lightAlpha)
        })
    }
}

struct MuesliSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let tint: Color?
    let isInteractive: Bool
    @ViewBuilder var content: Content

    init(
        cornerRadius: CGFloat = MuesliTheme.cornerMedium,
        tint: Color? = nil,
        isInteractive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.isInteractive = isInteractive
        self.content = content()
    }

    var body: some View {
        content
            .muesliGlassSurface(
                cornerRadius: cornerRadius,
                tint: tint,
                isInteractive: isInteractive
            )
    }
}

struct MuesliGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = MuesliTheme.spacing16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func muesliGlassSurface(
        cornerRadius: CGFloat = MuesliTheme.cornerMedium,
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            MuesliGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                isInteractive: isInteractive
            )
        )
    }

    func muesliGlassButton(
        cornerRadius: CGFloat = MuesliTheme.cornerMedium,
        tint: Color? = nil
    ) -> some View {
        modifier(MuesliGlassButtonModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func muesliNavigationGlassSurface(cornerRadius: CGFloat) -> some View {
        modifier(MuesliNavigationGlassSurfaceModifier(cornerRadius: cornerRadius))
    }

    func muesliNavigationSelection(
        isSelected: Bool,
        tint: Color,
        namespace: Namespace.ID
    ) -> some View {
        modifier(
            MuesliNavigationSelectionModifier(
                isSelected: isSelected,
                tint: tint,
                namespace: namespace
            )
        )
    }
}

// Shared surface names remain stable for existing callers. Content cards are
// opaque, so text contrast does not depend on the content scrolling behind them.
private struct MuesliNavigationGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(MuesliTheme.backgroundRaised, in: shape)
            .overlay(shape.strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 0.5))
    }
}

private struct MuesliNavigationSelectionModifier: ViewModifier {
    let isSelected: Bool
    let tint: Color
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: MuesliTheme.Navigation.selectionCornerRadius, style: .continuous)
                .fill(isSelected ? tint.opacity(0.12) : .clear)
        }
    }
}

private struct MuesliGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let isInteractive: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(MuesliTheme.backgroundRaised, in: shape)
            .overlay(shape.strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 0.5))
    }
}

private struct MuesliGlassButtonModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(cornerRadius, MuesliTheme.cornerMedium), style: .continuous)
        content
            .background((tint ?? MuesliTheme.accent).opacity(0.10), in: shape)
            .overlay(shape.strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 0.5))
            .contentShape(shape)
    }
}

/// A consistent primary action: comfortable touch target, quiet shape, no glow.
struct MuesliPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.muesliAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MuesliTheme.headline())
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: 48)
            .foregroundStyle(isEnabled ? MuesliTheme.onAccent : MuesliTheme.textSecondary)
            .background(isEnabled ? accent : MuesliTheme.surfacePrimary,
                        in: RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

enum MuesliAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }
}

enum MuesliAccentTheme: String, CaseIterable, Identifiable {
    case blue
    case green
    case slate

    var id: String { rawValue }

    static func resolved(rawValue: String) -> MuesliAccentTheme {
        if let theme = MuesliAccentTheme(rawValue: rawValue) {
            return theme
        }

        switch rawValue {
        case "orange":
            return .green
        case "purple", "pink":
            return .slate
        default:
            return .blue
        }
    }

    var label: String {
        switch self {
        case .blue:
            "Blue"
        case .green:
            "Green"
        case .slate:
            "Slate"
        }
    }

    var lightHex: Int {
        switch self {
        case .blue:
            0x2563EB
        case .green:
            0x047857
        case .slate:
            0x475569
        }
    }

    var darkHex: Int {
        switch self {
        case .blue:
            0x6BA3F7
        case .green:
            0x34D399
        case .slate:
            0xCBD5E1
        }
    }
}
