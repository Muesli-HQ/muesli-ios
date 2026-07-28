import CloudKit
import XCTest
@testable import Muesli

/// The legacy default-zone migration runs before any real syncing, so anything
/// it treats as fatal takes down sync in both directions. A TestFlight user hit
/// exactly that: "Sync failed: Type is not marked indexable: MuesliTextRecord",
/// on every sync, permanently, because the migration flag is only set on
/// success.
///
/// These pin which errors mean "there are no legacy records to read" and,
/// more importantly, which must still be allowed to fail the sync.
final class ICloudLegacyMigrationToleranceTests: XCTestCase {
    private func ckError(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> CKError {
        CKError(code, userInfo: userInfo)
    }

    /// A missing queryable index reports `invalidArguments`. This is the one
    /// that was breaking sync in Production, where the app cannot create schema.
    func testAMissingQueryableIndexIsTolerated() {
        XCTAssertTrue(
            ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(ckError(.invalidArguments))
        )
    }

    func testTheOtherEmptyLegacySchemaCodesAreTolerated() {
        for code in [CKError.Code.unknownItem, .serverRejectedRequest, .zoneNotFound] {
            XCTAssertTrue(
                ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(ckError(code)),
                "\(code) should read as 'no legacy records'"
            )
        }
    }

    /// The point of the classifier is to be narrow. A network drop or a signed
    /// out account is a real failure and must still surface, or this becomes a
    /// blanket catch that hides genuine sync breakage.
    func testRealFailuresAreStillFatal() {
        for code in [
            CKError.Code.networkUnavailable,
            .networkFailure,
            .notAuthenticated,
            .quotaExceeded,
            .permissionFailure,
            .serviceUnavailable,
            .requestRateLimited
        ] {
            XCTAssertFalse(
                ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(ckError(code)),
                "\(code) is a real failure and must not be swallowed"
            )
        }
    }

    /// CloudKit reports batch operations as a partial failure wrapping the real
    /// per-item errors, so the classifier has to look inside.
    func testAPartialFailureWrappingATolerableErrorIsTolerated() {
        let inner = ckError(.invalidArguments)
        let partial = ckError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "legacy"): inner]]
        )
        XCTAssertTrue(ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(partial))
    }

    func testAPartialFailureWrappingARealFailureIsNotTolerated() {
        let inner = ckError(.networkFailure)
        let partial = ckError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "legacy"): inner]]
        )
        XCTAssertFalse(ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(partial))
    }

    /// A real failure batched alongside a missing-schema error is still a real
    /// failure. Tolerating the batch because one item happened to be benign
    /// would hide it.
    func testAMixedPartialFailureIsNotTolerated() {
        let partial = ckError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [
                CKRecord.ID(recordName: "legacy"): ckError(.invalidArguments),
                CKRecord.ID(recordName: "other"): ckError(.networkFailure)
            ]]
        )
        XCTAssertFalse(ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(partial))
    }

    func testAnEmptyPartialFailureIsNotTolerated() {
        let partial = ckError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CKRecord.ID: Error]()]
        )
        XCTAssertFalse(ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(partial))
    }

    /// Errors surfacing through URL loading or an operation wrapper arrive
    /// nested rather than as a top-level CKError.
    func testANestedUnderlyingErrorIsUnwrapped() {
        let wrapper = NSError(
            domain: "com.example.wrapper",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: ckError(.invalidArguments)]
        )
        XCTAssertTrue(ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(wrapper))
    }

    func testAnUnrelatedErrorIsNotTolerated() {
        let unrelated = NSError(domain: NSPOSIXErrorDomain, code: 2)
        XCTAssertFalse(ICloudTextSyncEngine.isMissingLegacyDefaultZoneRecords(unrelated))
    }
}
