/// Invalidates deferred presentation work when a keyboard appearance ends.
struct MuesliKeyboardAppearanceGuard: Equatable {
    typealias Generation = UInt

    private(set) var generation: Generation = 0

    @discardableResult
    mutating func beginAppearance() -> Generation {
        generation &+= 1
        return generation
    }

    mutating func endAppearance() {
        generation &+= 1
    }

    func acceptsDeferredWork(
        from capturedGeneration: Generation,
        isPresented: Bool,
        hasActivatedRuntime: Bool
    ) -> Bool {
        capturedGeneration == generation
            && isPresented
            && hasActivatedRuntime
    }
}
