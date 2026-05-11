import Foundation

enum OnboardingPreferenceKeys {
    static let currentStep = "muesli.onboarding.currentStep"
    static let keyboardEnabledConfirmed = "muesli.onboarding.keyboardEnabledConfirmed"
    static let fullAccessConfirmed = "muesli.onboarding.fullAccessConfirmed"

    static func clear() {
        UserDefaults.standard.removeObject(forKey: currentStep)
        UserDefaults.standard.removeObject(forKey: keyboardEnabledConfirmed)
        UserDefaults.standard.removeObject(forKey: fullAccessConfirmed)
    }
}
