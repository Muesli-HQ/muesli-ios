import SwiftUI
import UIKit

enum MuesliTheme {
    static let backgroundDeep = Color.adaptive(dark: 0x111214, light: 0xF0F4FA)
    static let backgroundBase = Color.adaptive(dark: 0x15171B, light: 0xF7F9FC)
    static let backgroundRaised = Color.adaptive(dark: 0x1B1D22, light: 0xFFFFFF)
    static let backgroundHover = Color.adaptive(dark: 0x252A32, light: 0xE8EEF8)

    static let surfacePrimary = Color.adaptive(dark: 0x252934, light: 0xEEF3FB)
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
        darkAlpha: 0.62,
        light: .black,
        lightAlpha: 0.55
    )
    static let textTertiary = Color.adaptiveAlpha(
        dark: .white,
        darkAlpha: 0.40,
        light: .black,
        lightAlpha: 0.33
    )

    static var defaultAccent: Color { color(for: .blue) }
    static var accent: Color { color(for: selectedAccentTheme) }
    static var accentSubtle: Color { accent.opacity(0.14) }

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
    static let destructive = Color.adaptive(dark: 0xFF453A, light: 0xD70015)
    static var destructiveSubtle: Color { destructive.opacity(0.16) }

    static func title1() -> Font { .system(size: 28, weight: .bold) }
    static func title2() -> Font { .system(size: 22, weight: .semibold) }
    static func title3() -> Font { .system(size: 18, weight: .semibold) }
    static func headline() -> Font { .system(size: 15, weight: .semibold) }
    static func body() -> Font { .system(size: 14, weight: .regular) }
    static func callout() -> Font { .system(size: 13, weight: .regular) }
    static func caption() -> Font { .system(size: 12, weight: .regular) }
    static func captionMedium() -> Font { .system(size: 12, weight: .medium) }

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

    static func color(for accent: MuesliAccentTheme) -> Color {
        Color.adaptive(dark: accent.darkHex, light: accent.lightHex)
    }

    private static var selectedAccentTheme: MuesliAccentTheme {
        MuesliAccentTheme(
            rawValue: UserDefaults.standard.string(forKey: "muesli.appearance.accent") ?? ""
        ) ?? .blue
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
}

private struct MuesliGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let isInteractive: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .background(tintBackground, in: shape)
                .glassEffect(glassEffect(), in: .rect(cornerRadius: cornerRadius))
                .overlay(shape.strokeBorder(MuesliTheme.glassHighlight, lineWidth: 0.7))
                .shadow(color: MuesliTheme.glassShadow, radius: 10, x: 0, y: 5)
        } else {
            fallback(content: content, shape: shape)
        }
        #else
        fallback(content: content, shape: shape)
        #endif
    }

    private var tintBackground: Color {
        tint?.opacity(0.08) ?? MuesliTheme.backgroundRaised.opacity(0.74)
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func glassEffect() -> Glass {
        let base = Glass.regular.tint(tint?.opacity(0.18) ?? .clear)
        return isInteractive ? base.interactive() : base
    }
    #endif

    private func fallback(content: Content, shape: RoundedRectangle) -> some View {
        content
            .background {
                shape.fill(.regularMaterial)
                shape.fill(tintBackground)
            }
            .overlay(shape.strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1))
            .shadow(color: MuesliTheme.glassShadow, radius: 8, x: 0, y: 4)
    }
}

private struct MuesliGlassButtonModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .background((tint ?? MuesliTheme.accent).opacity(0.10), in: shape)
                .glassEffect(.regular.tint((tint ?? MuesliTheme.accent).opacity(0.22)).interactive(), in: .rect(cornerRadius: cornerRadius))
                .overlay(shape.strokeBorder((tint ?? MuesliTheme.accent).opacity(0.24), lineWidth: 1))
                .contentShape(shape)
        } else {
            fallback(content: content, shape: shape)
        }
        #else
        fallback(content: content, shape: shape)
        #endif
    }

    private func fallback(content: Content, shape: RoundedRectangle) -> some View {
        content
            .background {
                shape.fill(.ultraThinMaterial)
                shape.fill((tint ?? MuesliTheme.accent).opacity(0.12))
            }
            .overlay(shape.strokeBorder((tint ?? MuesliTheme.accent).opacity(0.24), lineWidth: 1))
            .contentShape(shape)
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
            0x059669
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
