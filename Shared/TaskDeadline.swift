import Foundation

/// Waits for a task, but no longer than a deadline.
///
/// A task group can't do this: `withTaskGroup` returns only after every child
/// finishes, and a child awaiting another task's `value` does not stop when
/// cancelled. So a group would keep waiting for a stuck task after the timer
/// fired. This resumes once, from whichever finishes first, and leaves the
/// slower side running in the background.
enum TaskDeadline {
    /// True if `task` finished within `limit`.
    static func wait(for task: Task<Void, Never>, limit: Duration) async -> Bool {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.set(continuation)
            Task {
                await task.value
                once.resume(returning: true)
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(returning: false)
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func set(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resume(returning value: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }
}
