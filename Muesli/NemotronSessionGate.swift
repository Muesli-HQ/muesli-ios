import Foundation

/// Owns the mutable decoder for a whole file or realtime session, not just one call.
/// A cancelled session remains exclusive until its outstanding model calls return.
actor NemotronSessionGate {
    private var owner: UUID?
    private var operations = 0
    private var closing = false
    private(set) var waitingCount = 0

    func acquire() async throws -> UUID {
        waitingCount += 1
        defer { waitingCount -= 1 }
        while owner != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        let token = UUID()
        owner = token
        closing = false
        return token
    }

    func beginOperation(_ token: UUID) throws {
        try Task.checkCancellation()
        guard owner == token, !closing else { throw CancellationError() }
        operations += 1
    }

    func endOperation(_ token: UUID) {
        guard owner == token else { return }
        precondition(operations > 0)
        operations -= 1
        if closing && operations == 0 { owner = nil }
    }

    func release(_ token: UUID) {
        guard owner == token else { return }
        closing = true
        if operations == 0 { owner = nil }
    }

    // Also used by deterministic concurrency tests to inspect ownership.
    func isOwned(by token: UUID) -> Bool { owner == token }
}
