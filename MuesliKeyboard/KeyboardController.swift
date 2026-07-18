import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private static let staleRecordingInterval: TimeInterval = 45
    private static let staleStoppingInterval: TimeInterval = 10
    private static let staleTranscribingInterval: TimeInterval = 120
    private static let runtimeFreshnessInterval: TimeInterval = 2
    private static let activeReconciliationInterval = Duration.milliseconds(750)
    private let store: SharedStore
    private let eventBus: any CrossProcessEventStreaming
    private let handoffRecoveryPolicy = KeyboardHandoffRecoveryPolicy.keyboardDefaults
    private var eventObservationTask: Task<Void, Never>?
    private var presentationReconciliationTask: Task<Void, Never>?
    private var commandAcknowledgementTask: Task<Void, Never>?
    private var latestResultID: UUID?
    private var preparedRequest: DictationRequest?
    private var activeRequestID: UUID?
    private var recoveryRequestID: UUID?
    private var latestHandoffState: KeyboardHandoffState?
    private var latestRuntimeStatus: KeyboardRuntimeStatus?
    private var insertedRequestIDs = Set<UUID>()
    private var cancelledRequestIDs = Set<UUID>()
    private let presentationOwnerID = UUID()
    private var isPresentationEligible = false
    private var hasPresentationLease = false
    private var pendingManualInsertionResult: DictationResult?
    private var manualInsertionAwaitingConfirmation = false
    private var isBlockedByAppVoiceNote = false

    var statusText = "Record a voice note first"
    var hasLatestDictation = false
    var dictationPhase: DictationPhase = .idle
    var launchURL: URL?
    var textInserter: (@MainActor (String) -> Void)?
    var textDeleter: (@MainActor (Int) -> Void)?
    var inputModeSwitcher: (@MainActor () -> Void)?
    var keyboardDismisser: (@MainActor () -> Void)?
    var liveTranscript = ""
    var inputLevel = 0.0
    var isCaptureRecovering = false
    var isLaunchSettled = false
    var waveformRenderGeneration = 0
    private var lastInsertedCharacterCount = 0
    private var canUseRuntimeStart = false

    init(
        store: SharedStore? = nil,
        eventBus: any CrossProcessEventStreaming = DarwinCrossProcessEventBus.shared
    ) {
        self.eventBus = eventBus
        self.store = store ?? SharedStore(eventPoster: eventBus)
    }

    var showsLiveTranscript: Bool {
        activeRequestID != nil
            && !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [.recording, .transcribing].contains(dictationPhase)
    }

    var primaryButtonTitle: String {
        return switch primaryButtonRole {
        case .blocked:
            "Voice Note Active"
        case .openMuesliRecovery:
            "Open Muesli"
        case .waitingForMuesli:
            "Waiting for Muesli"
        case .openMuesliRequested:
            "Open Muesli"
        case .stop:
            "Stop"
        case .transcribing:
            "Transcribing"
        case .inserted:
            "Inserted"
        case .manualInsert:
            manualInsertionAwaitingConfirmation
                ? "Insert if missing"
                : "Review recovered text"
        case .record:
            "Record"
        }
    }

    var primaryButtonIcon: String {
        return switch primaryButtonRole {
        case .blocked:
            "waveform"
        case .openMuesliRecovery:
            "arrow.up.forward.app"
        case .waitingForMuesli:
            "hourglass"
        case .openMuesliRequested:
            "arrow.up.forward.app"
        case .stop:
            "stop.fill"
        case .transcribing:
            "waveform"
        case .inserted:
            "checkmark"
        case .manualInsert:
            manualInsertionAwaitingConfirmation
                ? "text.badge.plus"
                : "exclamationmark.triangle"
        case .record:
            "mic.fill"
        }
    }

    var stylesPrimaryButtonAsStop: Bool {
        primaryButtonRole == .stop
    }

    var primaryButtonRole: KeyboardPrimaryButtonRole {
        if isBlockedByAppVoiceNote {
            return .blocked
        }
        if recoveryRequestID != nil {
            return .openMuesliRecovery
        }
        if pendingManualInsertionResult != nil {
            return .manualInsert
        }

        if latestHandoffState.map({ [.stopRequested, .cancelRequested].contains($0.phase) }) == true {
            return .waitingForMuesli
        }

        return switch dictationPhase {
        case .requested:
            activeRequestID == nil ? .openMuesliRequested : .stop
        case .recording:
            .stop
        case .transcribing:
            .transcribing
        case .finished:
            .record
        default:
            .record
        }
    }

    var isPrimaryButtonDisabled: Bool {
        isBlockedByAppVoiceNote || recoveryRequestID == nil && (
            dictationPhase == .transcribing
            || latestHandoffState.map({ [.stopRequested, .cancelRequested].contains($0.phase) }) == true
        )
    }

    var canInsertLatest: Bool {
        hasLatestDictation && activeRequestID == nil
    }

    var showsActiveWaveform: Bool {
        [.requested, .recording, .transcribing].contains(dictationPhase)
    }

    var waveformMode: MuesliFloatingWaveformMode {
        isCaptureRecovering
            ? .waiting
            : MuesliKeyboardWaveformPresentation.mode(for: dictationPhase)
    }

    var waveformLevel: Double? {
        isCaptureRecovering
            ? nil
            : MuesliKeyboardWaveformPresentation.level(for: dictationPhase, inputLevel: inputLevel)
    }

    var canCancelActiveDictation: Bool {
        [.requested, .recording, .transcribing].contains(dictationPhase)
            && latestHandoffState.map {
                ![.stopRequested, .cancelRequested].contains($0.phase)
            } != false
    }

    var settingsURL: URL? {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.settingsHost
        return components.url
    }

    var opensMuesliFromPrimaryButton: Bool {
        !isBlockedByAppVoiceNote
            && (recoveryRequestID != nil
                || !canUseRuntimeStart
                && (
                    dictationPhase == .idle
                        || dictationPhase == .finished
                        || dictationPhase == .failed
                        || (dictationPhase == .requested && activeRequestID == nil)
                ))
    }

    func primaryLaunchAction() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote else { return }
        if recoveryRequestID != nil {
            statusText = "Opening Muesli"
            return
        }

        startDictation()
    }

    func primaryAction() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote else { return }
        if pendingManualInsertionResult != nil {
            guard manualInsertionAwaitingConfirmation else {
                manualInsertionAwaitingConfirmation = true
                statusText = "Verify the text is missing before inserting"
                return
            }
            insertRecoveredResultAfterUserConfirmation()
            return
        }
        switch dictationPhase {
        case .requested, .recording:
            stopActiveDictation()
        case .transcribing:
            break
        case .finished:
            if canUseRuntimeStart {
                startDictation()
            } else {
                prepareLaunchRequestIfNeeded()
                statusText = "Open Muesli"
            }
        default:
            startDictation()
        }
    }

    func insertLatestDictation() {
        do {
            guard let result = try store.resultsHistory().first else {
                latestResultID = nil
                hasLatestDictation = false
                statusText = "Record a voice note first"
                return
            }

            insertText(result.text)
            latestResultID = result.id
            hasLatestDictation = true
            statusText = "Inserted"
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func prepareLaunchRequestIfNeeded() {
        guard preparedRequest == nil, activeRequestID == nil else { return }
        let request = DictationRequest()
        preparedRequest = request
        launchURL = makeLaunchURL(for: request)

        do {
            try store.saveRequest(request)
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func startDictation() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote else { return }
        guard ensurePresentationAuthority() else {
            statusText = "Switch back to Muesli Keyboard"
            return
        }

        MuesliHaptics.dictationStart()
        let request = preparedRequest ?? DictationRequest()
        preparedRequest = nil
        recoveryRequestID = nil
        launchURL = makeLaunchURL(for: request)
        activeRequestID = request.id
        liveTranscript = ""
        insertedRequestIDs.remove(request.id)
        cancelledRequestIDs.remove(request.id)
        dictationPhase = .requested
        statusText = "Opening Muesli"

        do {
            try store.clearKeyboardLiveTranscript()
            let handoff = makeLocalHandoffState(
                requestID: request.id,
                phase: .startRequested,
                message: canUseRuntimeStart ? "Starting" : "Opening Muesli",
                createdAt: request.createdAt
            )
            let command = DictationCommand(requestID: request.id, action: .start)
            guard try store.submitKeyboardIntent(
                request: request,
                command: command,
                handoffState: handoff
            ) else {
                refreshLatestDictation()
                return
            }
            latestHandoffState = handoff
            if canUseRuntimeStart {
                awaitCommandAcknowledgement(
                    requestID: request.id,
                    action: .start,
                    requestedPhase: .startRequested
                )
            }
        } catch {
            statusText = "Enable Full Access"
            activeRequestID = nil
            dictationPhase = .idle
            return
        }

        statusText = canUseRuntimeStart ? "Starting" : "Recording in Muesli"
    }

    private func stopActiveDictation() {
        guard ensurePresentationAuthority() else {
            statusText = "Switch back to Muesli Keyboard"
            return
        }
        guard let activeRequestID else {
            dictationPhase = .idle
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
            prepareLaunchRequestIfNeeded()
            return
        }

        MuesliHaptics.dictationStop()
        do {
            let handoff = makeLocalHandoffState(
                requestID: activeRequestID,
                phase: .stopRequested,
                message: "Stopping"
            )
            let command = DictationCommand(requestID: activeRequestID, action: .stop)
            guard try store.submitKeyboardIntent(
                request: nil,
                command: command,
                handoffState: handoff
            ) else {
                refreshLatestDictation()
                return
            }
            latestHandoffState = handoff
            dictationPhase = .recording
            statusText = "Stopping"
            awaitCommandAcknowledgement(
                requestID: activeRequestID,
                action: .stop,
                requestedPhase: .stopRequested
            )
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func insertSpace() {
        insertText(" ")
    }

    func insertTextKey(_ text: String) {
        insertText(text)
    }

    func insertReturn() {
        insertText("\n")
    }

    func switchInputMode() {
        inputModeSwitcher?()
    }

    func dismissKeyboard() {
        keyboardDismisser?()
    }

    func clearInsertedText() {
        let deleteCount = max(lastInsertedCharacterCount, 1)
        textDeleter?(deleteCount)
        lastInsertedCharacterCount = 0
        statusText = deleteCount > 1 ? "Cleared" : "Deleted"
    }

    func deleteBackward() {
        textDeleter?(1)
        lastInsertedCharacterCount = 0
        statusText = "Deleted"
    }

    func cancelActiveDictation() {
        refreshLatestDictation()
        guard canCancelActiveDictation else {
            statusText = dictationPhase == .transcribing ? "Transcribing" : statusText
            return
        }
        guard ensurePresentationAuthority() else {
            statusText = "Switch back to Muesli Keyboard"
            return
        }

        guard let activeRequestID else {
            dictationPhase = .idle
            liveTranscript = ""
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
            prepareLaunchRequestIfNeeded()
            return
        }

        MuesliHaptics.dictationStop()
        do {
            let handoff = makeLocalHandoffState(
                requestID: activeRequestID,
                phase: .cancelRequested,
                message: "Cancelling"
            )
            let command = DictationCommand(requestID: activeRequestID, action: .cancel)
            guard try store.submitKeyboardIntent(
                request: nil,
                command: command,
                handoffState: handoff
            ) else {
                refreshLatestDictation()
                return
            }
            latestHandoffState = handoff
            dictationPhase = .recording
            statusText = "Cancelling"
            awaitCommandAcknowledgement(
                requestID: activeRequestID,
                action: .cancel,
                requestedPhase: .cancelRequested
            )
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func prepareInitialPresentationState() {
        guard isPresentationEligible else { return }
        refreshLatestDictation()
        prepareLaunchRequestIfNeeded()
    }

    func startObservingSharedState() {
        beginObservingSharedState(reconciliation: .full)
    }

    private enum ObservationReconciliation {
        case full
        case activePresentation
    }

    private func beginObservingSharedState(reconciliation: ObservationReconciliation) {
        renewPresentationLease()
        markKeyboardVisible()
        eventObservationTask?.cancel()
        let events = eventBus.events()
        switch reconciliation {
        case .full:
            refreshLatestDictation()
        case .activePresentation:
            refreshActivePresentationState()
        }
        prepareLaunchRequestIfNeeded()
        eventObservationTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .runtimeStatusChanged:
                    self.refreshRuntimeStatus()
                case .liveTranscriptChanged:
                    self.refreshLiveTranscript()
                case .handoffStatusChanged, .resultChanged:
                    self.refreshLatestDictation()
                case .ownershipChanged:
                    if self.hasActivePresentationWork {
                        self.refreshActivePresentationState()
                    } else {
                        self.refreshLatestDictation()
                    }
                case .commandChanged:
                    break
                }
            }
        }
        startActivePresentationReconciliation()
    }

    /// Darwin notifications are an acceleration hint, not a durable event log.
    /// The extension host may suspend while the container continues recording,
    /// so every host activation restarts the stream and pulls the latest SQLite
    /// projection before accepting more UI input.
    func resumeAfterHostActivation() {
        guard isPresentationEligible else { return }
        renewPresentationLease()
        waveformRenderGeneration &+= 1
        beginObservingSharedState(reconciliation: .activePresentation)
    }

    func activatePresentationLease() {
        isPresentationEligible = true
        renewPresentationLease()
    }

    func suspendPresentationEligibility() {
        isPresentationEligible = false
        hasPresentationLease = false
    }

    func deactivatePresentationLease() {
        isPresentationEligible = false
        _ = try? store.releaseKeyboardPresentationLease(ownerID: presentationOwnerID)
        hasPresentationLease = false
    }

    func reconcileSharedPresentationState() {
        refreshActivePresentationState()
    }

    func markKeyboardVisible() {
        do {
            try store.saveKeyboardExtensionStatus(.init(lastSeenAt: .now, hasOpenAccess: true))
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func stopObservingSharedState() {
        eventObservationTask?.cancel()
        eventObservationTask = nil
        presentationReconciliationTask?.cancel()
        presentationReconciliationTask = nil
        commandAcknowledgementTask?.cancel()
        commandAcknowledgementTask = nil
    }

    private func startActivePresentationReconciliation() {
        presentationReconciliationTask?.cancel()
        presentationReconciliationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.activeReconciliationInterval)
                } catch {
                    return
                }
                guard let self, self.isPresentationEligible else { continue }
                self.renewPresentationLease()
                if self.hasActivePresentationWork {
                    self.refreshActivePresentationState()
                }
            }
        }
    }

    private func renewPresentationLease() {
        guard isPresentationEligible else {
            hasPresentationLease = false
            return
        }
        hasPresentationLease = (try? store.acquireKeyboardPresentationLease(
            ownerID: presentationOwnerID
        )) == true
    }

    private func ensurePresentationAuthority() -> Bool {
        guard isPresentationEligible else { return false }
        renewPresentationLease()
        return hasPresentationLease
    }

    private var hasActivePresentationWork: Bool {
        activeRequestID != nil
            || recoveryRequestID != nil
            || latestHandoffState.map {
                ![.idle, .inserted, .failed, .cancelled].contains($0.phase)
            } == true
    }

    private func refreshLatestDictation() {
        do {
            let snapshot = try store.keyboardPresentationSnapshot(
                preferredRequestID: activeRequestID
            )
            let runtimeStatus = snapshot.runtimeStatus
            latestRuntimeStatus = runtimeStatus
            let status = snapshot.status

            let handoffState = snapshot.handoffState
            latestHandoffState = handoffState
            apply(handoffState: handoffState)

            let statusBelongsToAppVoiceNote = applyAppVoiceNoteOwnership(status: status)
            if !statusBelongsToAppVoiceNote,
               (handoffState.requestID == nil || handoffState.phase == .idle) {
                apply(status: status)
            }
            apply(runtimeStatus: runtimeStatus)
            apply(liveTranscript: snapshot.liveTranscript)
            if isBlockedByAppVoiceNote {
                return
            }

            if let activeRequestID,
               snapshot.targetRequestID == activeRequestID,
               let activeResult = snapshot.result {
                insertCompletedResult(activeResult)
                return
            }

            guard let result = try store.resultsHistory().first else {
                latestResultID = nil
                hasLatestDictation = false
                if activeRequestID == nil, !isBlockedByAppVoiceNote {
                    statusText = "Ready"
                }
                return
            }

            hasLatestDictation = true
            if latestResultID != result.id {
                latestResultID = result.id
                if activeRequestID == nil, !isBlockedByAppVoiceNote {
                    statusText = "Latest ready"
                }
            } else if activeRequestID == nil,
                      !isBlockedByAppVoiceNote,
                      statusText != "Inserted" {
                statusText = "Latest ready"
            }
        } catch {
            apply(runtimeStatus: latestRuntimeStatus)
            statusText = "Waiting for Full Access"
        }
    }

    /// Lightweight reconciliation used while a request is active. It deliberately
    /// avoids loading the complete history, which may contain thousands of notes.
    /// Request ownership is established before applying the meter row so the first
    /// post-resume level cannot be discarded during cold rehydration.
    private func refreshActivePresentationState() {
        do {
            let snapshot = try store.keyboardPresentationSnapshot(
                preferredRequestID: activeRequestID
            )
            let runtimeStatus = snapshot.runtimeStatus
            let status = snapshot.status
            let handoffState = snapshot.handoffState

            latestRuntimeStatus = runtimeStatus
            latestHandoffState = handoffState
            apply(handoffState: handoffState)

            let statusBelongsToAppVoiceNote = applyAppVoiceNoteOwnership(status: status)
            if !statusBelongsToAppVoiceNote,
               (handoffState.requestID == nil || handoffState.phase == .idle) {
                apply(status: status)
            }
            apply(runtimeStatus: runtimeStatus)
            apply(liveTranscript: snapshot.liveTranscript)

            guard !isBlockedByAppVoiceNote,
                  let requestID = activeRequestID,
                  snapshot.targetRequestID == requestID,
                  let result = snapshot.result
            else { return }
            insertCompletedResult(result)
        } catch {
            apply(runtimeStatus: latestRuntimeStatus)
            statusText = "Waiting for Full Access"
        }
    }

    private func refreshRuntimeStatus() {
        do {
            let runtimeStatus = try store.keyboardRuntimeStatus()
            latestRuntimeStatus = runtimeStatus
            apply(runtimeStatus: runtimeStatus)
        } catch {
            statusText = "Waiting for Full Access"
        }
    }

    private func refreshLiveTranscript() {
        do {
            apply(liveTranscript: try store.keyboardLiveTranscript())
        } catch {
            statusText = "Waiting for Full Access"
        }
    }

    private func apply(
        handoffState: KeyboardHandoffState,
        evaluatesRecovery: Bool = true
    ) {
        reconcilePendingManualInsertion(with: handoffState)
        guard let requestID = handoffState.requestID else { return }

        if ![.startRequested, .stopRequested, .cancelRequested].contains(handoffState.phase) {
            commandAcknowledgementTask?.cancel()
            commandAcknowledgementTask = nil
        }

        if activeRequestID != requestID {
            // The single durable handoff row is the cross-process authority.
            // After suspension the extension may still remember an older local
            // request; replace it before applying terminal state, meter, or result.
            activeRequestID = requestID
            recoveryRequestID = nil
            liveTranscript = ""
            inputLevel = 0
        }

        if cancelledRequestIDs.contains(requestID) {
            if [.cancelled, .idle, .failed].contains(handoffState.phase),
               activeRequestID == nil || activeRequestID == requestID
            {
                activeRequestID = nil
                recoveryRequestID = nil
                liveTranscript = ""
                dictationPhase = .idle
                inputLevel = 0
                statusText = hasLatestDictation ? "Latest ready" : "Ready"
            }
            return
        }

        if evaluatesRecovery, markHandoffForRecoveryIfStale(handoffState) {
            return
        }

        recoveryRequestID = handoffState.phase == .recoveryRequested ? requestID : nil
        if handoffState.phase != .recordingStarted {
            isCaptureRecovering = false
        }

        switch handoffState.phase {
        case .idle:
            dictationPhase = .idle
            activeRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        case .startRequested:
            dictationPhase = .requested
            statusText = handoffState.message ?? "Starting"
        case .startAcknowledged:
            dictationPhase = .requested
            statusText = handoffState.message ?? "Starting"
        case .recordingStarted:
            dictationPhase = .recording
            statusText = handoffState.message ?? "Listening"
        case .stopRequested:
            dictationPhase = .recording
            statusText = handoffState.message ?? "Stopping"
        case .cancelRequested:
            dictationPhase = .recording
            statusText = handoffState.message ?? "Cancelling"
        case .stopAcknowledged:
            dictationPhase = .transcribing
            inputLevel = 0
            statusText = handoffState.message ?? "Finalizing audio"
        case .audioSaved:
            dictationPhase = .transcribing
            inputLevel = 0
            statusText = handoffState.message ?? "Audio saved"
        case .transcribingStarted:
            dictationPhase = .transcribing
            inputLevel = 0
            statusText = handoffState.message ?? "Transcribing"
        case .resultReady:
            dictationPhase = .transcribing
            inputLevel = 0
            statusText = handoffState.message ?? "Inserting"
        case .inserted:
            dictationPhase = .idle
            activeRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = "Inserted"
        case .recoveryRequested:
            dictationPhase = .failed
            recoveryRequestID = requestID
            launchURL = makeLaunchURL(
                for: requestID,
                action: urlAction(for: handoffState.recoveryAction ?? .start)
            )
            statusText = handoffState.message ?? "Open Muesli to finish"
        case .failed:
            dictationPhase = .failed
            activeRequestID = nil
            recoveryRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = handoffState.message ?? "Voice note failed"
        case .cancelled:
            cancelledRequestIDs.insert(requestID)
            dictationPhase = .idle
            activeRequestID = nil
            recoveryRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        }
    }

    private func apply(runtimeStatus: KeyboardRuntimeStatus?) {
        let now = Date()
        let isFresh = runtimeStatus.map {
            now.timeIntervalSince($0.updatedAt) >= 0
                && now.timeIntervalSince($0.updatedAt) < Self.runtimeFreshnessInterval
        } ?? false
        let runtimeMatchesActiveRequest = runtimeStatus.map {
            isFresh
                && $0.isActive
                && $0.activeRequestID == activeRequestID
        } ?? false
        let blocksRecordingRuntime = activeRequestID.map {
            handoffBlocksRecordingRuntime(requestID: $0)
        } ?? false
        let isWaitingForControlAcknowledgement = latestHandoffState.map {
            [.stopRequested, .cancelRequested].contains($0.phase)
        } == true
        let hasFreshRecordingLevel = runtimeStatus.map {
            runtimeMatchesActiveRequest
                && $0.phase == .recording
                && !$0.isRecoveringCapture
                && !blocksRecordingRuntime
        } ?? false
        inputLevel = hasFreshRecordingLevel ? (runtimeStatus?.inputLevel ?? 0) : 0
        canUseRuntimeStart = isFresh && runtimeStatus?.canAcceptStartCommand == true
        isCaptureRecovering = dictationPhase == .recording
            && !isWaitingForControlAcknowledgement
            && (!runtimeMatchesActiveRequest || runtimeStatus?.isRecoveringCapture == true)

        guard isFresh,
              let runtimeStatus,
              let runtimeRequestID = runtimeStatus.activeRequestID,
              runtimeRequestID == activeRequestID,
              !cancelledRequestIDs.contains(runtimeRequestID),
              [.recording, .transcribing].contains(runtimeStatus.phase)
        else { return }

        if runtimeStatus.phase == .recording, blocksRecordingRuntime {
            isCaptureRecovering = false
            inputLevel = 0
            return
        }

        recoveryRequestID = nil
        dictationPhase = runtimeStatus.phase
        if runtimeStatus.phase == .transcribing {
            isCaptureRecovering = false
            inputLevel = 0
        }
        if !isWaitingForControlAcknowledgement {
            statusText = runtimeStatus.message ?? runtimeStatus.phase.rawValue.capitalized
        }
    }

    private func handoffBlocksRecordingRuntime(requestID: UUID) -> Bool {
        guard let latestHandoffState,
              latestHandoffState.requestID == requestID
        else { return false }
        return [
            .stopAcknowledged,
            .audioSaved,
            .transcribingStarted,
            .resultReady,
            .inserted,
            .failed,
            .cancelled,
        ].contains(latestHandoffState.phase)
    }

    private func apply(status: DictationStatus) {
        guard !applyAppVoiceNoteOwnership(status: status) else { return }
        guard let requestID = status.requestID else {
            if activeRequestID != nil {
                activeRequestID = nil
                dictationPhase = .idle
                liveTranscript = ""
            }
            return
        }

        if activeRequestID == nil, preparedRequest?.id == requestID, status.phase == .requested {
            return
        }

        if cancelledRequestIDs.contains(requestID) {
            return
        }

        let resumablePhases: [DictationPhase] = [.requested, .recording, .transcribing, .finished]
        let isRecentStatus = Date().timeIntervalSince(status.updatedAt) < 120
        if activeRequestID == nil, isRecentStatus, resumablePhases.contains(status.phase) {
            activeRequestID = requestID
        }

        guard activeRequestID == requestID else { return }

        if markForRecoveryIfStale(status, requestID: requestID) {
            return
        }

        switch status.phase {
        case .requested:
            recoveryRequestID = nil
            if activeRequestID == nil {
                dictationPhase = .requested
                statusText = "Open Muesli to record"
            } else {
                dictationPhase = .recording
                statusText = "Recording in Muesli"
            }
        case .recording:
            recoveryRequestID = nil
            dictationPhase = .recording
            statusText = "Recording in Muesli"
        case .transcribing:
            recoveryRequestID = nil
            dictationPhase = .transcribing
            isCaptureRecovering = false
            statusText = status.message ?? "Transcribing"
        case .failed:
            recoveryRequestID = nil
            dictationPhase = .failed
            activeRequestID = nil
            liveTranscript = ""
            isCaptureRecovering = false
            statusText = status.message ?? "Voice note failed"
        case .finished:
            recoveryRequestID = nil
            dictationPhase = .finished
            break
        case .idle:
            recoveryRequestID = nil
            dictationPhase = .idle
            activeRequestID = nil
            liveTranscript = ""
            isCaptureRecovering = false
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
        }
    }

    @discardableResult
    private func applyAppVoiceNoteOwnership(status: DictationStatus) -> Bool {
        guard let requestID = status.requestID,
              let session = try? store.recordingSession(requestID: requestID),
              !session.isKeyboardOwnedVoiceNote
        else {
            isBlockedByAppVoiceNote = false
            return false
        }

        isBlockedByAppVoiceNote = session.hasActiveVoiceNoteWork
        if isBlockedByAppVoiceNote {
            activeRequestID = nil
            recoveryRequestID = nil
            dictationPhase = .idle
            liveTranscript = ""
            inputLevel = 0
            statusText = "Finish the voice note in Muesli"
        }
        return true
    }

    private func apply(liveTranscript transcript: KeyboardLiveTranscript?) {
        guard let activeRequestID else {
            liveTranscript = ""
            return
        }

        guard let transcript,
              transcript.requestID == activeRequestID,
              Date().timeIntervalSince(transcript.updatedAt) < 120
        else {
            return
        }

        liveTranscript = transcript.text
    }

    private func markForRecoveryIfStale(_ status: DictationStatus, requestID: UUID) -> Bool {
        if let latestRuntimeStatus,
           latestRuntimeStatus.activeRequestID == requestID,
           Date().timeIntervalSince(latestRuntimeStatus.updatedAt) < handoffRecoveryPolicy.runtimeFreshnessInterval,
           [.recording, .transcribing].contains(latestRuntimeStatus.phase)
        {
            recoveryRequestID = nil
            dictationPhase = latestRuntimeStatus.phase
            statusText = latestRuntimeStatus.message ?? status.message ?? latestRuntimeStatus.phase.rawValue.capitalized
            return true
        }

        let age = Date().timeIntervalSince(status.updatedAt)
        let threshold: TimeInterval
        let message: String

        switch status.phase {
        case .requested, .recording:
            threshold = Self.staleRecordingInterval
            message = "Open Muesli to continue"
        case .transcribing:
            threshold = status.message == "Stopping" ? Self.staleStoppingInterval : Self.staleTranscribingInterval
            message = "Open Muesli to finish"
        default:
            return false
        }

        guard age > threshold else { return false }

        if hasDurableActiveSession(requestID: requestID) {
            recoveryRequestID = nil
            return false
        }

        recoveryRequestID = requestID
        launchURL = makeLaunchURL(for: requestID, action: MuesliAppConstants.startAction)
        dictationPhase = .failed
        activeRequestID = nil
        liveTranscript = ""
        statusText = message
        return true
    }

    private func markHandoffForRecoveryIfStale(_ state: KeyboardHandoffState) -> Bool {
        guard let requestID = state.requestID else { return false }

        // A stale cross-process heartbeat is not evidence that recording died.
        // Persisted session phase is the container-owned authority; keep Stop and
        // Cancel available while transport catches up instead of mutating the
        // durable handoff to recoveryRequested from the extension.
        if hasDurableActiveSession(requestID: requestID) {
            recoveryRequestID = nil
            return false
        }

        let action = handoffRecoveryPolicy.action(
            for: state,
            latestRuntimeStatus: latestRuntimeStatus,
            canUseRuntimeStart: canUseRuntimeStart
        )

        switch action {
        case .none:
            return false

        case let .retry(retryAction, retrying):
            guard (try? store.saveKeyboardHandoffState(retrying)) == true else {
                reconcileRejectedHandoffTransition()
                return true
            }
            latestHandoffState = retrying
            _ = try? store.saveCommand(.init(requestID: requestID, action: retryAction))
            dictationPhase = retrying.phase.dictationPhase
            statusText = retrying.message ?? "Retrying"
            return true

        case let .recover(recovery):
            guard (try? store.saveKeyboardHandoffState(recovery)) == true else {
                reconcileRejectedHandoffTransition()
                return true
            }
            latestHandoffState = recovery
            recoveryRequestID = requestID
            launchURL = makeLaunchURL(for: requestID, action: MuesliAppConstants.startAction)
            dictationPhase = .failed
            activeRequestID = nil
            liveTranscript = ""
            statusText = recovery.message ?? "Open Muesli to finish"
            return true
        }
    }

    private func insertCompletedResult(_ result: DictationResult) {
        guard !cancelledRequestIDs.contains(result.requestID) else { return }
        guard ensurePresentationAuthority() else { return }
        attemptResultInsertion(result, allowsAbandonedClaimRecovery: false)
    }

    private func insertRecoveredResultAfterUserConfirmation() {
        guard let result = pendingManualInsertionResult else { return }
        guard ensurePresentationAuthority() else {
            statusText = "Switch back to Muesli Keyboard to insert"
            return
        }
        attemptResultInsertion(result, allowsAbandonedClaimRecovery: true)
    }

    private func attemptResultInsertion(
        _ result: DictationResult,
        allowsAbandonedClaimRecovery: Bool
    ) {
        let claim = KeyboardResultInsertionClaim(
            id: UUID(),
            requestID: result.requestID,
            ownerID: presentationOwnerID,
            claimedAt: .now
        )
        let outcome: KeyboardResultInsertionClaimOutcome
        do {
            outcome = try store.claimKeyboardResultInsertion(
                claim: claim,
                allowsAbandonedClaimRecovery: allowsAbandonedClaimRecovery
            )
        } catch {
            statusText = "Waiting to insert"
            return
        }

        switch outcome {
        case .acquired:
            performClaimedResultInsertion(result, claim: claim)
        case .busy:
            statusText = "Finishing insertion"
        case .recoveryRequired:
            if pendingManualInsertionResult?.requestID != result.requestID {
                manualInsertionAwaitingConfirmation = false
            }
            pendingManualInsertionResult = result
            dictationPhase = .finished
            inputLevel = 0
            statusText = "Tap to insert recovered text"
        case .unavailable:
            statusText = "Waiting for result"
        }
    }

    private func performClaimedResultInsertion(
        _ result: DictationResult,
        claim: KeyboardResultInsertionClaim
    ) {
        guard ensurePresentationAuthority(),
              (try? store.validateKeyboardResultInsertionClaim(claim)) == true
        else {
            // The controller lost its visible text proxy or presentation lease
            // after claiming. Preserve the claim and require explicit recovery;
            // never send text through a stale keyboard instance.
            pendingManualInsertionResult = result
            manualInsertionAwaitingConfirmation = false
            dictationPhase = .finished
            statusText = "Insertion paused; verify the text is missing"
            return
        }
        insertText(result.text)
        insertedRequestIDs.insert(result.requestID)
        let inserted = makeLocalHandoffState(
            requestID: result.requestID,
            phase: .inserted,
            message: "Inserted"
        )
        guard (try? store.finalizeKeyboardResultInsertion(
            claim: claim,
            handoffState: inserted
        )) == true else {
            // The proxy side effect cannot participate in SQLite's transaction.
            // Keep the durable claim so a future instance never auto-inserts a
            // possible duplicate; recovery becomes an explicit user decision.
            pendingManualInsertionResult = result
            dictationPhase = .finished
            statusText = "Inserted; tap only if text is missing"
            return
        }

        latestHandoffState = inserted
        pendingManualInsertionResult = nil
        manualInsertionAwaitingConfirmation = false
        latestResultID = result.id
        hasLatestDictation = true
        activeRequestID = nil
        liveTranscript = ""
        preparedRequest = nil
        recoveryRequestID = nil
        launchURL = nil
        dictationPhase = .idle
        isCaptureRecovering = false
        statusText = "Latest ready"
        try? store.clearKeyboardLiveTranscript()
        prepareLaunchRequestIfNeeded()
    }

    private func reconcilePendingManualInsertion(with handoffState: KeyboardHandoffState) {
        guard let pendingResult = pendingManualInsertionResult else { return }
        let pickupStillExists = (try? store.result(for: pendingResult.requestID)) != nil
        guard handoffState.phase == .resultReady,
              handoffState.requestID == pendingResult.requestID,
              pickupStillExists
        else {
            pendingManualInsertionResult = nil
            manualInsertionAwaitingConfirmation = false
            return
        }
    }

    private func makeLocalHandoffState(
        requestID: UUID,
        phase: KeyboardHandoffPhase,
        message: String?,
        createdAt: Date? = nil
    ) -> KeyboardHandoffState {
        let current = latestHandoffState ?? (try? store.keyboardHandoffState())
        if let current, current.requestID == requestID {
            return current.advanced(to: phase, message: message)
        }
        return KeyboardHandoffState(
            requestID: requestID,
            phase: phase,
            message: message,
            createdAt: createdAt ?? .now
        )
    }

    @discardableResult
    private func saveLocalHandoffState(_ state: KeyboardHandoffState) throws -> Bool {
        let didSave = try store.saveKeyboardHandoffState(state)
        if didSave {
            latestHandoffState = state
        }
        return didSave
    }

    /// A rejected write means another process advanced the durable row first.
    /// Adopt that projection instead of continuing to mutate the UI from the
    /// stale state that lost the compare-and-set race.
    private func reconcileRejectedHandoffTransition() {
        guard let persisted = try? store.keyboardHandoffState() else { return }
        latestHandoffState = persisted
        // Avoid re-entering stale-recovery policy while resolving a rejected
        // transition. The persisted phase itself is authoritative here.
        apply(handoffState: persisted, evaluatesRecovery: false)
    }

    private func hasDurableActiveSession(requestID: UUID) -> Bool {
        guard let session = try? store.recordingSession(requestID: requestID),
              session.isKeyboardOwnedVoiceNote
        else { return false }
        return [.recording, .interrupted, .transcriptionQueued, .transcribing]
            .contains(session.phase)
    }

    private func awaitCommandAcknowledgement(
        requestID: UUID,
        action: DictationCommandAction,
        requestedPhase: KeyboardHandoffPhase
    ) {
        commandAcknowledgementTask?.cancel()
        commandAcknowledgementTask = Task { @MainActor [weak self, eventBus] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.refreshLatestDictation()
            guard self.isAwaitingAcknowledgement(requestID: requestID, phase: requestedPhase) else { return }
            eventBus.post(.commandChanged)

            try? await Task.sleep(for: .milliseconds(1_250))
            guard !Task.isCancelled else { return }
            self.refreshLatestDictation()
            guard self.isAwaitingAcknowledgement(requestID: requestID, phase: requestedPhase) else { return }

            if let session = try? self.store.recordingSession(requestID: requestID),
               session.isKeyboardOwnedVoiceNote,
               [.recording, .interrupted, .transcriptionQueued, .transcribing].contains(session.phase)
            {
                self.recoveryRequestID = nil
                self.activeRequestID = requestID
                switch session.phase {
                case .recording, .interrupted:
                    self.dictationPhase = .recording
                    self.isCaptureRecovering = session.phase == .interrupted
                case .transcriptionQueued, .transcribing:
                    self.dictationPhase = .transcribing
                    self.isCaptureRecovering = false
                    self.inputLevel = 0
                default:
                    break
                }
                // The command is durable; re-notify the container and let the
                // periodic reconciliation observe its authoritative progress.
                // A slow acknowledgement must not be converted into failure.
                eventBus.post(.commandChanged)
                return
            }

            let urlAction: String
            let message: String
            switch action {
            case .start:
                urlAction = MuesliAppConstants.startAction
                message = "Open Muesli to start"
            case .stop:
                urlAction = MuesliAppConstants.stopAction
                message = "Open Muesli to finish"
            case .cancel:
                urlAction = MuesliAppConstants.cancelAction
                message = "Open Muesli to cancel"
            }
            let current = self.latestHandoffState ?? (try? self.store.keyboardHandoffState())
            let recovery: KeyboardHandoffState
            if let current, current.requestID == requestID {
                recovery = current.advanced(
                    to: .recoveryRequested,
                    message: message,
                    recoveryAttemptCount: max(current.recoveryAttemptCount, 1),
                    recoveryAction: action
                )
            } else {
                recovery = KeyboardHandoffState(
                    requestID: requestID,
                    phase: .recoveryRequested,
                    message: message,
                    recoveryAttemptCount: 1,
                    recoveryAction: action
                )
            }
            guard (try? self.saveLocalHandoffState(recovery)) == true else {
                self.reconcileRejectedHandoffTransition()
                return
            }
            self.canUseRuntimeStart = false
            self.recoveryRequestID = requestID
            self.activeRequestID = nil
            self.dictationPhase = .failed
            self.launchURL = self.makeLaunchURL(for: requestID, action: urlAction)
            self.statusText = message
        }
    }

    private func isAwaitingAcknowledgement(
        requestID: UUID,
        phase: KeyboardHandoffPhase
    ) -> Bool {
        guard let state = try? store.keyboardHandoffState() else { return false }
        return state.requestID == requestID && state.phase == phase
    }

    private func makeLaunchURL(for request: DictationRequest) -> URL? {
        makeLaunchURL(for: request.id, action: MuesliAppConstants.startAction)
    }

    private func urlAction(for action: DictationCommandAction) -> String {
        switch action {
        case .start: MuesliAppConstants.startAction
        case .stop: MuesliAppConstants.stopAction
        case .cancel: MuesliAppConstants.cancelAction
        }
    }

    private func makeLaunchURL(for requestID: UUID, action: String) -> URL? {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.dictateHost
        components.queryItems = [
            URLQueryItem(name: MuesliAppConstants.requestQueryItem, value: requestID.uuidString),
            URLQueryItem(name: MuesliAppConstants.actionQueryItem, value: action)
        ]

        return components.url
    }

    private func insertText(_ text: String) {
        textInserter?(text)
        lastInsertedCharacterCount = text.count
    }
}

enum KeyboardPrimaryButtonRole: Equatable {
    case blocked
    case openMuesliRecovery
    case waitingForMuesli
    case openMuesliRequested
    case stop
    case transcribing
    case inserted
    case manualInsert
    case record
}
