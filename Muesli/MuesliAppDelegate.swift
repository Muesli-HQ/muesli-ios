import UIKit

final class MuesliAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        ModelBackgroundDownloadService.shared.setBackgroundCompletionHandler(completionHandler)
    }
}
