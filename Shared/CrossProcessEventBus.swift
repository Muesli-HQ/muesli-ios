import CoreFoundation
import Foundation

enum CrossProcessEvent: String, CaseIterable, Sendable {
    case commandChanged = "command.changed"
    case handoffStatusChanged = "handoff-status.changed"
    case runtimeStatusChanged = "runtime-status.changed"
    case liveTranscriptChanged = "live-transcript.changed"
    case resultChanged = "result.changed"
    case ownershipChanged = "ownership.changed"

    var notificationName: String {
        "com.phequals7.muesli.\(rawValue).v1"
    }

    init?(notificationName: String) {
        guard let event = Self.allCases.first(where: { $0.notificationName == notificationName }) else {
            return nil
        }
        self = event
    }
}

protocol CrossProcessEventPosting: Sendable {
    func post(_ event: CrossProcessEvent)
}

protocol CrossProcessEventStreaming: CrossProcessEventPosting {
    func events() -> AsyncStream<CrossProcessEvent>
}

final class DarwinCrossProcessEventBus: CrossProcessEventStreaming, @unchecked Sendable {
    static let shared = DarwinCrossProcessEventBus()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CrossProcessEvent>.Continuation] = [:]
    private let center = CFNotificationCenterGetDarwinNotifyCenter()

    private init() {
        for event in CrossProcessEvent.allCases {
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                crossProcessEventCallback,
                event.notificationName as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func post(_ event: CrossProcessEvent) {
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(event.notificationName as CFString),
            nil,
            nil,
            true
        )
    }

    func events() -> AsyncStream<CrossProcessEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
        }
    }

    fileprivate func receive(notificationName: String) {
        guard let event = CrossProcessEvent(notificationName: notificationName) else { return }
        lock.lock()
        let currentContinuations = Array(continuations.values)
        lock.unlock()
        for continuation in currentContinuations {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

private let crossProcessEventCallback: CFNotificationCallback = { _, observer, name, _, _ in
    guard let observer,
          let name
    else { return }
    let bus = Unmanaged<DarwinCrossProcessEventBus>.fromOpaque(observer).takeUnretainedValue()
    bus.receive(notificationName: name.rawValue as String)
}
