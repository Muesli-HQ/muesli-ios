import XCTest
#if canImport(MuesliDev)
@testable import MuesliDev
#else
@testable import Muesli
#endif

final class ModelSetupFailureTests: XCTestCase {
    func testLowStorageBlocksOptimizationWithActionableMessage() {
        let required = ModelSetupStorage.requiredBytes(downloadBytes: 0, modelBytes: 626_000_000)
        XCTAssertThrowsError(try ModelSetupStorage.check(availableBytes: 837_152_768, requiredBytes: required)) { error in
            let state = ModelPreparationState.failed(error)
            XCTAssertEqual(state.phase, .failed)
            XCTAssertEqual(state.status, "More storage needed")
            XCTAssertTrue(state.detail.contains("smaller model"))
            XCTAssertFalse(state.detail.contains("connection"))
        }
        XCTAssertNoThrow(try ModelSetupStorage.check(availableBytes: required, requiredBytes: required))
        XCTAssertNoThrow(try ModelSetupStorage.check(availableBytes: nil, requiredBytes: required))
    }

    func testDownloadBudgetIncludesPreparationWorkspace() {
        let cached = ModelSetupStorage.requiredBytes(downloadBytes: 0, modelBytes: 626_000_000)
        let fresh = ModelSetupStorage.requiredBytes(downloadBytes: 626_000_000, modelBytes: 626_000_000)
        XCTAssertEqual(fresh - cached, 626_000_000)
        XCTAssertGreaterThan(cached, 626_000_000)
    }

    func testWrappedOutOfSpaceErrorIsNotMisreportedAsNetworkFailure() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let wrapper = NSError(domain: "com.apple.CoreML", code: 0,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertEqual(ModelSetupFailure.describe(wrapper).status, "More storage needed")
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(ModelSetupFailure.describe(cocoa).status, "More storage needed")
    }

    func testNetworkAndRuntimeErrorsHaveDifferentRecoveryGuidance() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(ModelSetupFailure.describe(offline).status, "Connection interrupted")
        let runtime = NSError(domain: "com.apple.CoreML", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "private/path/token"])
        let failure = ModelSetupFailure.describe(runtime)
        XCTAssertEqual(failure.status, "Model setup failed")
        XCTAssertFalse(failure.detail.contains("connection"))
        XCTAssertFalse(failure.detail.contains("private/path/token"))
    }

    func testOptimizationIsNotShownAsAnotherDownload() {
        for status in ["Optimizing WhisperKit for this iPhone...", "Loading downloaded Whisper model...", "Compiling model"] {
            XCTAssertEqual(ModelPreparationState.progressPhase(status: status), .preparing)
        }
        XCTAssertEqual(ModelPreparationState.progressPhase(status: "100 MB of 626 MB"), .downloading)
    }
}
