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

struct KeyboardSetupVerificationChallenge: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let expiresAt: Date

    var responseToken: String {
        "muesli-verified-\(id.uuidString.lowercased())"
    }

    func isActive(at date: Date = .now) -> Bool {
        date < expiresAt
    }
}

struct KeyboardSetupVerificationReceipt: Codable, Equatable, Sendable {
    let challengeID: UUID
    let verifiedAt: Date
    let hasFullAccess: Bool
}

enum ActionButtonCaptureSource {
    static let standard = "action_button"
    static let clipboard = "action_button_clipboard"

    static func isActionButton(_ source: String?) -> Bool {
        source == standard || source == clipboard
    }
}

enum ActionButtonCaptureMode: String, Codable, CaseIterable, Sendable {
    case dictation
    case meeting

    var shortcutTitle: String {
        self == .dictation ? "Muesli Dictation" : "Muesli Meeting Note"
    }
}

struct ActionButtonSetupVerificationChallenge: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    // Missing on receipts issued by the first dictation-only build.
    var mode: ActionButtonCaptureMode? = nil

    var captureMode: ActionButtonCaptureMode { mode ?? .dictation }

    func isActive(at date: Date = .now) -> Bool {
        date < expiresAt
    }
}

struct ActionButtonSetupVerificationReceipt: Codable, Equatable, Sendable {
    let challengeID: UUID
    var startedAt: Date?
    var stoppedAt: Date?
    var sessionID: UUID? = nil

    var isVerified: Bool {
        startedAt != nil && stoppedAt != nil
    }
}

enum ActionButtonSetupVerificationEvent: Sendable {
    case started
    case stopped
}

/// A small App Group transport dedicated to setup probes.
///
/// Keyboard setup must be verifiable before Full Access has been granted, so
/// this cannot depend on the shared SQLite database: opening that database can
/// require writes for WAL bookkeeping. App Group preferences remain readable
/// to the keyboard and only the Full Access receipt requires an extension
/// write. Every receipt is bound to a fresh, expiring challenge so stale setup
/// state is never accepted as current evidence.
struct SetupVerificationStore {
    private enum Key {
        static let keyboardChallenge = "muesli.setup.keyboard.challenge"
        static let keyboardReceipt = "muesli.setup.keyboard.receipt"
        static let actionButtonChallenge = "muesli.setup.actionButton.challenge"
        static let actionButtonReceipt = "muesli.setup.actionButton.receipt"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: MuesliAppConstants.appGroupIdentifier)
            ?? .standard
    }

    @discardableResult
    func beginKeyboardChallenge(
        now: Date = .now,
        lifetime: TimeInterval = 10 * 60
    ) -> KeyboardSetupVerificationChallenge {
        let challenge = KeyboardSetupVerificationChallenge(
            id: UUID(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        save(challenge, forKey: Key.keyboardChallenge)
        defaults.removeObject(forKey: Key.keyboardReceipt)
        defaults.synchronize()
        return challenge
    }

    func activeKeyboardChallenge(now: Date = .now) -> KeyboardSetupVerificationChallenge? {
        guard let challenge: KeyboardSetupVerificationChallenge = value(forKey: Key.keyboardChallenge),
              challenge.isActive(at: now) else { return nil }
        return challenge
    }

    func saveKeyboardReceipt(
        for challenge: KeyboardSetupVerificationChallenge,
        hasFullAccess: Bool,
        now: Date = .now
    ) {
        guard challenge.isActive(at: now),
              activeKeyboardChallenge(now: now)?.id == challenge.id else { return }
        save(
            KeyboardSetupVerificationReceipt(
                challengeID: challenge.id,
                verifiedAt: now,
                hasFullAccess: hasFullAccess
            ),
            forKey: Key.keyboardReceipt
        )
    }

    func keyboardReceipt(
        for challenge: KeyboardSetupVerificationChallenge
    ) -> KeyboardSetupVerificationReceipt? {
        guard challenge.isActive(),
              let receipt: KeyboardSetupVerificationReceipt = value(forKey: Key.keyboardReceipt),
              receipt.challengeID == challenge.id else { return nil }
        return receipt
    }

    func clearKeyboardChallenge(_ challenge: KeyboardSetupVerificationChallenge) {
        guard activeKeyboardChallenge()?.id == challenge.id else { return }
        defaults.removeObject(forKey: Key.keyboardChallenge)
        defaults.removeObject(forKey: Key.keyboardReceipt)
        defaults.synchronize()
    }

    @discardableResult
    func beginActionButtonChallenge(
        mode: ActionButtonCaptureMode = .dictation,
        now: Date = .now,
        lifetime: TimeInterval = 5 * 60
    ) -> ActionButtonSetupVerificationChallenge {
        let challenge = ActionButtonSetupVerificationChallenge(
            id: UUID(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime),
            mode: mode
        )
        save(challenge, forKey: Key.actionButtonChallenge)
        defaults.removeObject(forKey: Key.actionButtonReceipt)
        defaults.synchronize()
        return challenge
    }

    func activeActionButtonChallenge(now: Date = .now) -> ActionButtonSetupVerificationChallenge? {
        guard let challenge: ActionButtonSetupVerificationChallenge = value(forKey: Key.actionButtonChallenge),
              challenge.isActive(at: now) else { return nil }
        return challenge
    }

    func recordActionButtonEvent(
        _ event: ActionButtonSetupVerificationEvent,
        mode: ActionButtonCaptureMode = .dictation,
        sessionID: UUID? = nil,
        now: Date = .now
    ) {
        guard let challenge = activeActionButtonChallenge(now: now),
              challenge.captureMode == mode else { return }
        var receipt = actionButtonReceipt(for: challenge)
            ?? ActionButtonSetupVerificationReceipt(
                challengeID: challenge.id,
                startedAt: nil,
                stoppedAt: nil
            )

        switch event {
        case .started:
            receipt.startedAt = now
            receipt.stoppedAt = nil
            receipt.sessionID = sessionID
        case .stopped:
            guard let startedAt = receipt.startedAt,
                  now >= startedAt,
                  receipt.sessionID == sessionID else { return }
            receipt.stoppedAt = now
        }
        save(receipt, forKey: Key.actionButtonReceipt)
    }

    func actionButtonReceipt(
        for challenge: ActionButtonSetupVerificationChallenge
    ) -> ActionButtonSetupVerificationReceipt? {
        guard challenge.isActive(),
              let receipt: ActionButtonSetupVerificationReceipt = value(forKey: Key.actionButtonReceipt),
              receipt.challengeID == challenge.id else { return nil }
        return receipt
    }

    func clearActionButtonChallenge(_ challenge: ActionButtonSetupVerificationChallenge) {
        guard activeActionButtonChallenge()?.id == challenge.id else { return }
        defaults.removeObject(forKey: Key.actionButtonChallenge)
        defaults.removeObject(forKey: Key.actionButtonReceipt)
        defaults.synchronize()
    }

    private func save<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    private func value<Value: Decodable>(forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
