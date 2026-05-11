import UIKit

@MainActor
enum MuesliHaptics {
    static func dictationStart() {
        impact(.medium, intensity: 0.85)
    }

    static func dictationStop() {
        impact(.rigid, intensity: 0.9)
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }
}
