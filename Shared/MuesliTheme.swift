import SwiftUI
import UIKit

enum MuesliTheme {
    static let backgroundDeep = Color.adaptive(dark: 0x111214, light: 0xF5F5F7)
    static let backgroundBase = Color.adaptive(dark: 0x161719, light: 0xFFFFFF)
    static let backgroundRaised = Color.adaptive(dark: 0x1C1D20, light: 0xF0F0F2)
    static let backgroundHover = Color.adaptive(dark: 0x232528, light: 0xE8E8EC)

    static let surfacePrimary = Color.adaptive(dark: 0x262830, light: 0xE5E5EA)
    static let surfaceSelected = Color.adaptive(dark: 0x2E3340, light: 0xD6DFFE)
    static let surfaceBorder = Color.adaptiveAlpha(
        dark: .white,
        darkAlpha: 0.07,
        light: .black,
        lightAlpha: 0.08
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

    static let defaultAccent = Color.adaptive(dark: 0x6BA3F7, light: 0x2563EB)
    static let accent = defaultAccent
    static let accentSubtle = defaultAccent.opacity(0.15)

    static let recording = Color(hex: 0xEF4444)
    static let transcribing = Color(hex: 0xF59E0B)
    static let success = Color(hex: 0x34D399)

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

    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 10
    static let cornerLarge: CGFloat = 14
    static let cornerXL: CGFloat = 20
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
    @ViewBuilder var content: Content

    init(cornerRadius: CGFloat = MuesliTheme.cornerMedium, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }
}

