import CloudKit
import UIKit

enum MuesliCKSyncBackgroundFetch {
    static let cloudKitBudget: Duration = .seconds(20)

    static func shouldFetch(isCloudKitNotification: Bool, syncEnabled: Bool) -> Bool {
        isCloudKitNotification && syncEnabled
    }

    static func run(
        fetch: @Sendable () async throws -> ICloudTextSyncResult
    ) async -> UIBackgroundFetchResult {
        do {
            let result = try await fetch()
            return result.downloaded > 0 ? .newData : .noData
        } catch {
            return .failed
        }
    }
}

final class MuesliAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Create/restore CKSyncEngine independently of SwiftUI view ownership so
        // automatic CloudKit push handling is available from process launch.
        let runtime = MuesliCKSyncRuntime.shared
        if let initialIntent = MuesliCKSyncLaunchPolicy.initialIntent(
            syncEnabled: MuesliPreferences.iCloudSyncEnabled
        ) {
            Task {
                // Startup convergence replays SQLite's durable outbox even if
                // CKSyncEngine restored no pending state, then fetches remote work.
                if initialIntent == .manual {
                    _ = try? await runtime.syncManually()
                }
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard MuesliCKSyncBackgroundFetch.shouldFetch(
            isCloudKitNotification: CKNotification(fromRemoteNotificationDictionary: userInfo) != nil,
            syncEnabled: MuesliPreferences.iCloudSyncEnabled
        ) else {
            completionHandler(.noData)
            return
        }

        // Forward the trigger to the process-wide request coordinator. The
        // CKSyncEngine delegate only reconciles events; it never recursively
        // starts a sync operation from inside its callbacks.
        Task {
            let result = await MuesliCKSyncBackgroundFetch.run {
                try await MuesliCKSyncRuntime.shared.fetchRemoteChanges(
                    deadline: MuesliCKSyncBackgroundFetch.cloudKitBudget
                )
            }
            await MainActor.run {
                completionHandler(result)
            }
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        ModelBackgroundDownloadService.shared.setBackgroundCompletionHandler(completionHandler)
    }
}
