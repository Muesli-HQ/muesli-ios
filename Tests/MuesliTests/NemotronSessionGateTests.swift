import XCTest
#if canImport(MuesliDev)
@testable import MuesliDev
#else
@testable import Muesli
#endif

final class NemotronSessionGateTests: XCTestCase {
    // Models a stopped notepad still feeding audio while a new live session asks
    // to reset the same decoder. The reset must wait for the file's finish.
    func testLiveSessionWaitsForEntireFileTranscription() async throws {
        let gate = NemotronSessionGate()
        let file = try await gate.acquire()
        let live = Task { try await gate.acquire() }
        try await waitForWaiter(gate)
        let ownsFile = await gate.isOwned(by: file)
        XCTAssertTrue(ownsFile)
        await gate.release(file)
        let liveToken = try await live.value
        XCTAssertNotEqual(file, liveToken)
        await gate.release(liveToken)
    }

    func testFileWaitsBetweenLiveAudioBuffersUntilSessionFinishes() async throws {
        let gate = NemotronSessionGate()
        let live = try await gate.acquire()
        try await gate.beginOperation(live)
        await gate.endOperation(live)
        let file = Task { try await gate.acquire() }
        try await waitForWaiter(gate)
        // Returning from an audio-feed call must not release the whole session.
        try await gate.beginOperation(live)
        await gate.endOperation(live)
        let ownsLive = await gate.isOwned(by: live)
        XCTAssertTrue(ownsLive)
        await gate.release(live)
        let fileToken = try await file.value
        await gate.release(fileToken)
    }

    func testCancellationWaitsForInFlightModelCallAndRejectsMoreAudio() async throws {
        let gate = NemotronSessionGate()
        let live = try await gate.acquire()
        try await gate.beginOperation(live)
        await gate.release(live)
        let file = Task { try await gate.acquire() }
        try await waitForWaiter(gate)
        let stillOwned = await gate.isOwned(by: live)
        XCTAssertTrue(stillOwned)
        do {
            try await gate.beginOperation(live)
            XCTFail("Cancelled session accepted another audio buffer")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await gate.endOperation(live)
        let fileToken = try await file.value
        await gate.release(fileToken)
    }

    func testCancelledWaiterDoesNotAcquireOrBlockNextSession() async throws {
        let gate = NemotronSessionGate()
        let file = try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        try await waitForWaiter(gate)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled request acquired the decoder")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await gate.release(file)
        let next = try await gate.acquire()
        await gate.release(next)
    }

    func testDelayedCleanupCannotReleaseNewSession() async throws {
        let gate = NemotronSessionGate()
        let old = try await gate.acquire()
        await gate.release(old)
        let current = try await gate.acquire()
        await gate.release(old)
        let ownsCurrent = await gate.isOwned(by: current)
        XCTAssertTrue(ownsCurrent)
        await gate.release(current)
    }

    private func waitForWaiter(_ gate: NemotronSessionGate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await gate.waitingCount == 0 {
            guard ContinuousClock.now < deadline else {
                XCTFail("Request never reached the session gate")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
