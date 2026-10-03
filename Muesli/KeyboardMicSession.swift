import Foundation

/// Invalidating a session also invalidates outstanding asynchronous startup.
struct KeyboardMicSession: Equatable {
    private(set) var id: UUID?
    private(set) var generation = UUID()
    private(set) var isPaused = false

    mutating func begin() -> UUID {
        if let id { return id }
        let id = UUID()
        self.id = id
        generation = UUID()
        isPaused = false
        return id
    }

    mutating func stop() {
        id = nil
        generation = UUID()
        isPaused = true
    }

    func owns(_ id: UUID) -> Bool { self.id == id }
}
