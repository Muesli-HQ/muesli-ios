import AudioToolbox
import UIKit

@MainActor
enum MuesliAudioCues {
    static func modelReady() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlayAlertSound(SystemSoundID(1007))
    }
}
