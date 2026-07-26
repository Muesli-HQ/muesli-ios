import Foundation
import Observation

@MainActor
@Observable
final class KeyboardController {
    private static let staleRecordingInterval: TimeInterval = 45
    private static let staleStoppingInterval: TimeInterval = 10
    private static let staleTranscribingInterval: TimeInterval = 120
    private let store: SharedStore
    private let eventBus: any CrossProcessEventStreaming
    private let handoffRecoveryPolicy = KeyboardHandoffRecoveryPolicy.keyboardDefaults
    private var eventObservationTask: Task<Void, Never>?
    private var commandAcknowledgementTask: Task<Void, Never>?
    private var latestResultID: UUID?
    private var preparedRequest: DictationRequest?
    private var activeRequestID: UUID?
    private var recoveryRequestID: UUID?
    private var latestHandoffState: KeyboardHandoffState?
    private var latestRuntimeStatus: KeyboardRuntimeStatus?
    private var insertedRequestIDs = Set<UUID>()
    private var cancelledRequestIDs = Set<UUID>()
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
    var isLaunchSettled = false
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
        MuesliKeyboardWaveformPresentation.mode(for: dictationPhase)
    }

    var waveformLevel: Double? {
        MuesliKeyboardWaveformPresentation.level(for: dictationPhase, inputLevel: inputLevel)
    }

    var canCancelActiveDictation: Bool {
        [.requested, .recording, .transcribing].contains(dictationPhase)
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

    func prepareLaunchRequestIfNeeded(clearsPendingCommand: Bool = true) {
        guard preparedRequest == nil, activeRequestID == nil else { return }
        let request = DictationRequest()
        preparedRequest = request
        launchURL = makeLaunchURL(for: request)

        do {
            if clearsPendingCommand, !hasPendingCancelCommand() {
                try store.clearPendingCommand()
            }
            try store.saveRequest(request)
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func startDictation() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote else { return }
        if hasPendingCancelCommand() {
            try? store.clearPendingCommand()
        }

        MuesliHaptics.dictationStart()
        KeyboardDiagnosticsLog.record("intent.start", [
            "canUseRuntimeStart": canUseRuntimeStart ? "yes" : "no",
            "appPhase": latestRuntimeStatus?.phase.rawValue ?? "unknown",
            "appSeenAt": latestRuntimeStatus.map {
                String(format: "%.1fs", Date.now.timeIntervalSince($0.updatedAt))
            } ?? "never"
        ])
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
            try store.clearPendingCommand()
            try store.clearKeyboardLiveTranscript()
            try store.saveRequest(request)
            try store.saveKeyboardHandoffState(.init(
                requestID: request.id,
                phase: .startRequested,
                message: canUseRuntimeStart ? "Starting" : "Opening Muesli"
            ))
            if canUseRuntimeStart {
                try store.saveCommand(.init(requestID: request.id, action: .start))
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
        guard let activeRequestID else {
            dictationPhase = .idle
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
            prepareLaunchRequestIfNeeded()
            return
        }

        MuesliHaptics.dictationStop()
        KeyboardDiagnosticsLog.record("intent.stop", [
            "request": String(activeRequestID.uuidString.prefix(8).lowercased()),
            "localPhase": dictationPhase.rawValue
        ])
        do {
            try store.saveKeyboardHandoffState(.init(
                requestID: activeRequestID,
                phase: .stopRequested,
                message: "Stopping"
            ))
            try store.saveCommand(.init(requestID: activeRequestID, action: .stop))
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

        guard let activeRequestID else {
            dictationPhase = .idle
            liveTranscript = ""
            statusText = hasLatestDictation ? "Latest ready" : "Ready"
            prepareLaunchRequestIfNeeded()
            return
        }

        MuesliHaptics.dictationStop()
        do {
            try store.saveKeyboardHandoffState(.init(
                requestID: activeRequestID,
                phase: .cancelRequested,
                message: "Cancelling"
            ))
            try store.saveCommand(.init(requestID: activeRequestID, action: .cancel))
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

    private func hasPendingCancelCommand() -> Bool {
        guard let command = try? store.pendingCommand(), command.action == .cancel else { return false }
        return cancelledRequestIDs.contains(command.requestID)
    }

    func prepareInitialPresentationState() {
        refreshLatestDictation()
        prepareLaunchRequestIfNeeded()
    }

    func startObservingSharedState() {
        KeyboardDiagnosticsLog.record("keyboard.appeared")
        markKeyboardVisible()
        eventObservationTask?.cancel()
        let events = eventBus.events()
        refreshLatestDictation()
        prepareLaunchRequestIfNeeded()
        eventObservationTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                switch event {
                case .runtimeStatusChanged:
                    self.refreshRuntimeStatus()
                case .liveTranscriptChanged:
                    self.refreshLiveTranscript()
                case .handoffStatusChanged, .resultChanged, .ownershipChanged:
                    self.refreshLatestDictation()
                case .commandChanged:
                    break
                }
            }
        }
    }

    func markKeyboardVisible() {
        do {
            try store.saveKeyboardExtensionStatus(.init(lastSeenAt: .now, hasOpenAccess: true))
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func stopObservingSharedState() {
        KeyboardDiagnosticsLog.record("keyboard.disappeared", [
            "localPhase": dictationPhase.rawValue,
            "active": activeRequestID?.uuidString.prefix(8).lowercased() ?? "none"
        ])
        eventObservationTask?.cancel()
        eventObservationTask = nil
        commandAcknowledgementTask?.cancel()
        commandAcknowledgementTask = nil
    }

    private func refreshLatestDictation() {
        do {
            let runtimeStatus = try store.keyboardRuntimeStatus()
            latestRuntimeStatus = runtimeStatus
            apply(runtimeStatus: runtimeStatus)
            let status = try store.status()

            let handoffState = try store.keyboardHandoffState()
            latestHandoffState = handoffState
            apply(handoffState: handoffState)
            apply(liveTranscript: try store.keyboardLiveTranscript())

            let statusBelongsToAppVoiceNote = applyAppVoiceNoteOwnership(status: status)
            if !statusBelongsToAppVoiceNote,
               (handoffState.requestID == nil
                || [.idle, .failed, .cancelled, .inserted].contains(handoffState.phase)) {
                apply(status: status)
            }
            if isBlockedByAppVoiceNote {
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
            if let activeRequestID, let activeResult = try store.result(for: activeRequestID) {
                insertCompletedResult(activeResult)
                return
            }

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

    private func apply(handoffState: KeyboardHandoffState) {
        guard let requestID = handoffState.requestID else { return }

        // The handoff record is written by both processes with no ordering
        // guarantee, so record what arrived and what we were already showing.
        // A phase that moves backwards is visible here and nowhere else.
        if latestHandoffState?.phase != handoffState.phase
            || latestHandoffState?.requestID != handoffState.requestID {
            KeyboardDiagnosticsLog.record("handoff.observed", [
                "phase": handoffState.phase.rawValue,
                "request": requestID.uuidString.prefix(8).lowercased(),
                "localPhase": dictationPhase.rawValue,
                "active": activeRequestID?.uuidString.prefix(8).lowercased() ?? "none",
                "inserted": insertedRequestIDs.contains(requestID) ? "yes" : "no"
            ])
        }

        if ![.startRequested, .stopRequested, .cancelRequested].contains(handoffState.phase) {
            commandAcknowledgementTask?.cancel()
            commandAcknowledgementTask = nil
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

        let resumablePhases: [KeyboardHandoffPhase] = [
            .startRequested,
            .startAcknowledged,
            .recordingStarted,
            .stopRequested,
            .cancelRequested,
            .stopAcknowledged,
            .audioSaved,
            .transcribingStarted,
            .resultReady,
            .recoveryRequested
        ]
        if activeRequestID == nil, resumablePhases.contains(handoffState.phase) {
            activeRequestID = requestID
        }

        guard activeRequestID == requestID else { return }

        if markHandoffForRecoveryIfStale(handoffState) {
            return
        }

        recoveryRequestID = handoffState.phase == .recoveryRequested ? requestID : nil

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
            dictationPhase = .finished
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
        let hasFreshRecordingLevel = runtimeStatus.map {
            $0.phase == .recording
                && $0.activeRequestID == activeRequestID
                && now.timeIntervalSince($0.updatedAt) < 2
        } ?? false
        inputLevel = hasFreshRecordingLevel ? (runtimeStatus?.inputLevel ?? 0) : 0
        canUseRuntimeStart = runtimeStatus?.canAcceptStartCommand == true

        guard activeRequestID == nil, canUseRuntimeStart else { return }
        guard let runtimeRequestID = runtimeStatus?.activeRequestID,
              !cancelledRequestIDs.contains(runtimeRequestID)
        else {
            return
        }

        activeRequestID = runtimeRequestID
        if runtimeStatus?.phase == .idle {
            statusText = runtimeStatus?.message ?? "Session ready"
        }
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
            statusText = status.message ?? "Transcribing"
        case .failed:
            recoveryRequestID = nil
            dictationPhase = .failed
            activeRequestID = nil
            liveTranscript = ""
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

        let action = handoffRecoveryPolicy.action(
            for: state,
            latestRuntimeStatus: latestRuntimeStatus,
            canUseRuntimeStart: canUseRuntimeStart
        )

        switch action {
        case .none:
            return false

        case let .retry(retryAction, retrying):
            try? store.saveCommand(.init(requestID: requestID, action: retryAction))
            try? store.saveKeyboardHandoffState(retrying)
            latestHandoffState = retrying
            dictationPhase = retrying.phase.dictationPhase
            statusText = retrying.message ?? "Retrying"
            return true

        case let .recover(recovery):
            try? store.saveKeyboardHandoffState(recovery)
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
        let shortID = result.requestID.uuidString.prefix(8).lowercased()

        // These two guards correctly prevent a double insertion, but they
        // return without reconciling dictationPhase or activeRequestID. If the
        // keyboard is stranded mid-session, this is the line it is stranded on
        // -- and until now it was completely silent.
        guard !insertedRequestIDs.contains(result.requestID) else {
            KeyboardDiagnosticsLog.record("insert.skipped", [
                "reason": "alreadyInserted",
                "request": String(shortID),
                "localPhase": dictationPhase.rawValue,
                "active": activeRequestID?.uuidString.prefix(8).lowercased() ?? "none"
            ])
            return
        }
        guard !cancelledRequestIDs.contains(result.requestID) else {
            KeyboardDiagnosticsLog.record("insert.skipped", [
                "reason": "cancelled",
                "request": String(shortID),
                "localPhase": dictationPhase.rawValue
            ])
            return
        }

        // Character count only -- never the text itself.
        KeyboardDiagnosticsLog.record("insert.performed", [
            "request": String(shortID),
            "characters": String(result.text.count)
        ])
        insertText(result.text)
        insertedRequestIDs.insert(result.requestID)
        latestResultID = result.id
        hasLatestDictation = true
        activeRequestID = nil
        liveTranscript = ""
        preparedRequest = nil
        recoveryRequestID = nil
        launchURL = nil
        dictationPhase = .idle
        statusText = "Latest ready"
        try? store.clearPendingRequest()
        try? store.clearPendingCommand()
        try? store.clearKeyboardLiveTranscript()
        try? store.saveKeyboardHandoffState(.init(
            requestID: result.requestID,
            phase: .inserted,
            message: "Inserted"
        ))
        try? store.saveStatus(.idle)
        prepareLaunchRequestIfNeeded()

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
            // The app consumes a command without posting any notification, so
            // the only way to detect a missed intent is to re-post and wait.
            KeyboardDiagnosticsLog.record("ack.retry", [
                "action": action.rawValue,
                "request": String(requestID.uuidString.prefix(8).lowercased()),
                "waited": "750ms"
            ])
            eventBus.post(.commandChanged)

            try? await Task.sleep(for: .milliseconds(1_250))
            guard !Task.isCancelled else { return }
            self.refreshLatestDictation()
            guard self.isAwaitingAcknowledgement(requestID: requestID, phase: requestedPhase) else { return }

            // Two sleeps elapsed with no state change: the app never serviced
            // this intent. Usually it is not running.
            KeyboardDiagnosticsLog.record("ack.timedOut", [
                "action": action.rawValue,
                "request": String(requestID.uuidString.prefix(8).lowercased()),
                "waited": "2000ms",
                "escalation": "recoveryRequested"
            ])

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
            let recovery = KeyboardHandoffState(
                requestID: requestID,
                phase: .recoveryRequested,
                message: message,
                recoveryAttemptCount: 1,
                recoveryAction: action
            )
            try? self.store.saveKeyboardHandoffState(recovery)
            self.latestHandoffState = recovery
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

enum KeyboardPrimaryButtonRole {
    case blocked
    case openMuesliRecovery
    case waitingForMuesli
    case openMuesliRequested
    case stop
    case transcribing
    case inserted
    case record
}
