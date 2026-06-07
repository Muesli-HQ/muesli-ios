import FluidAudio
import Foundation

final class StreamingVadController: @unchecked Sendable {
    var onChunkBoundary: (() -> Void)?

    private struct State {
        var generation = 0
        var isActive = false
        var isDraining = false
        var pendingChunks: [[Float]] = []
        var streamState: VadStreamState?
        var lastRotationTime: Date?
    }

    private let lock = NSLock()
    private var state = State()
    private let makeInitialState: @Sendable () async -> VadStreamState
    private let processStreamChunk: @Sendable ([Float], VadStreamState) async throws -> VadStreamResult
    private let minChunkDuration: TimeInterval
    private let maxChunkDuration: TimeInterval
    private var maxDurationTimer: Timer?

    convenience init(vadManager: VadManager) {
        self.init(
            minChunkDuration: 3.0,
            maxChunkDuration: 60.0,
            makeInitialState: { await vadManager.makeStreamState() },
            processStreamChunk: { samples, state in
                try await vadManager.processStreamingChunk(samples, state: state)
            }
        )
    }

    init(
        minChunkDuration: TimeInterval,
        maxChunkDuration: TimeInterval,
        makeInitialState: @escaping @Sendable () async -> VadStreamState,
        processStreamChunk: @escaping @Sendable ([Float], VadStreamState) async throws -> VadStreamResult
    ) {
        self.minChunkDuration = minChunkDuration
        self.maxChunkDuration = maxChunkDuration
        self.makeInitialState = makeInitialState
        self.processStreamChunk = processStreamChunk
    }

    func start() {
        let generation: Int
        lock.lock()
        guard !state.isActive else {
            lock.unlock()
            return
        }
        state.generation += 1
        state.isActive = true
        state.isDraining = false
        state.pendingChunks.removeAll(keepingCapacity: true)
        state.streamState = nil
        state.lastRotationTime = Date()
        generation = state.generation
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            let initialState = await self.makeInitialState()
            let shouldDrain = self.withLockedState { state in
                if state.isActive, state.generation == generation {
                    state.streamState = initialState
                    return !state.pendingChunks.isEmpty
                }
                return false
            }
            if shouldDrain {
                self.startDrainIfNeeded()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.maxDurationTimer?.invalidate()
            self.maxDurationTimer = Timer.scheduledTimer(withTimeInterval: self.maxChunkDuration, repeats: true) { [weak self] _ in
                self?.handleMaxDurationTimer()
            }
        }
    }

    func stop() {
        lock.lock()
        state.isActive = false
        state.pendingChunks.removeAll(keepingCapacity: false)
        state.streamState = nil
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.maxDurationTimer?.invalidate()
            self?.maxDurationTimer = nil
        }
    }

    func processAudio(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        let shouldDrain: Bool
        lock.lock()
        if state.isActive {
            state.pendingChunks.append(samples)
            shouldDrain = state.streamState != nil && !state.isDraining
        } else {
            shouldDrain = false
        }
        lock.unlock()

        if shouldDrain {
            startDrainIfNeeded()
        }
    }

    func notifyRotation() {
        lock.lock()
        state.lastRotationTime = Date()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.maxDurationTimer?.fireDate = Date().addingTimeInterval(self.maxChunkDuration)
        }
    }

    private func handleMaxDurationTimer() {
        let shouldRotate: Bool
        lock.lock()
        if state.isActive {
            let now = Date()
            let elapsed = now.timeIntervalSince(state.lastRotationTime ?? now)
            if elapsed >= minChunkDuration {
                state.lastRotationTime = now
                shouldRotate = true
            } else {
                shouldRotate = false
            }
        } else {
            shouldRotate = false
        }
        lock.unlock()

        guard shouldRotate else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onChunkBoundary?()
        }
    }

    private func startDrainIfNeeded() {
        lock.lock()
        guard state.isActive, state.streamState != nil, !state.isDraining, !state.pendingChunks.isEmpty else {
            lock.unlock()
            return
        }
        state.isDraining = true
        let generation = state.generation
        lock.unlock()

        Task { [weak self] in
            await self?.drainQueue(generation: generation)
        }
    }

    private func drainQueue(generation: Int) async {
        while true {
            let next: (chunk: [Float], streamState: VadStreamState)? = withLockedState { state in
                if state.isActive, state.generation == generation, let streamState = state.streamState, !state.pendingChunks.isEmpty {
                    return (state.pendingChunks.removeFirst(), streamState)
                }
                state.isDraining = false
                return nil
            }

            guard let next else { return }

            do {
                let result = try await processStreamChunk(next.chunk, next.streamState)
                let shouldRotate = withLockedState { state in
                    if state.isActive, state.generation == generation {
                        state.streamState = result.state
                        if result.event?.kind == .speechEnd {
                            let now = Date()
                            let elapsed = now.timeIntervalSince(state.lastRotationTime ?? now)
                            let shouldRotate = elapsed >= minChunkDuration
                            if shouldRotate {
                                state.lastRotationTime = now
                            }
                            return shouldRotate
                        }
                    }
                    return false
                }

                if shouldRotate {
                    DispatchQueue.main.async { [weak self] in
                        self?.onChunkBoundary?()
                        self?.notifyRotation()
                    }
                }
            } catch {
                // VAD is an optimization for chunk boundaries. A failed VAD chunk
                // should not kill an active recording; max-duration rotation remains.
            }
        }
    }

    private func withLockedState<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
