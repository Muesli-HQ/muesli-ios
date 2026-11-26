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
    private let setupVerificationStore: SetupVerificationStore
    private let handoffRecoveryPolicy = KeyboardHandoffRecoveryPolicy.keyboardDefaults
    private var eventObservationTask: Task<Void, Never>?
    private var commandAcknowledgementTask: Task<Void, Never>?
    private var visibilityHeartbeatTask: Task<Void, Never>?
    var currentFullAccess: (() -> Bool)?
    private var latestResultID: UUID?
    private var preparedRequest: DictationRequest?
    private var activeRequestID: UUID?
    private var recoveryRequestID: UUID?
    private var latestHandoffState: KeyboardHandoffState?
    private var latestRuntimeStatus: KeyboardRuntimeStatus?
    private var insertedRequestIDs = Set<UUID>()
    private var completedClipboardRequestIDs = Set<UUID>()
    private var cancelledRequestIDs = Set<UUID>()
    private var pendingCancellationIDs = Set<UUID>()
    private var isBlockedByAppVoiceNote = false
    /// Tracked separately from `latestHandoffState`, which `refreshLatestDictation`
    /// overwrites before `apply(handoffState:)` runs -- comparing against it
    /// there always says "unchanged".
    private var lastRecordedHandoff: (requestID: UUID, phase: KeyboardHandoffPhase)?
    private var lastLevelFreshness: Bool?
    private var pendingModelRawValue: String?
    private var hasOpenAccessForSetup = false

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
    var modelCatalog: KeyboardTranscriptionModelCatalog?
    var setupVerificationChallenge: KeyboardSetupVerificationChallenge?
    private var lastInsertedCharacterCount = 0
    private var canUseRuntimeStart = false
    /// Records and transcribes inside the keyboard (opt-in). Nil in tests that
    /// exercise only the Muesli handoff.
    var inKeyboardDictation: (any InKeyboardDictating)?
    private(set) var isInKeyboardCaptureActive = false
    private(set) var canUseInKeyboardDictation = false
    private(set) var needsForegroundStart = false
    private var inKeyboardRequestID: UUID?
    /// A recording whose keyboard was dismissed while the model still held
    /// its audio; its transcript is saved to history instead of inserted.
    private var dismissedInKeyboardRequestID: UUID?
    /// Reads the "live transcript instead of waveform" setting when capture starts.
    var inKeyboardLiveTranscriptPreference: () -> Bool = { InKeyboardDictationPreferences.showsLiveTranscript() }
    /// The recording ended and its transcript is waiting for the keyboard
    /// model to finish loading.
    var isPreparingInKeyboardModel: Bool {
        isInKeyboardCaptureActive && dictationPhase == .transcribing && statusText.hasPrefix("Preparing ")
    }
    /// Whether this capture shows its live transcript in place of the waveform.
    private(set) var showsInKeyboardLiveTranscript = false
    private var inKeyboardPartialTranscript = ""

    init(
        store: SharedStore? = nil,
        eventBus: any CrossProcessEventStreaming = DarwinCrossProcessEventBus.shared,
        setupVerificationStore: SetupVerificationStore = SetupVerificationStore()
    ) {
        self.eventBus = eventBus
        self.store = store ?? SharedStore(eventPoster: eventBus)
        self.setupVerificationStore = setupVerificationStore
    }

    var hasPendingSetupVerification: Bool {
        setupVerificationChallenge?.isActive() == true
    }

    var setupVerificationDetail: String {
        hasOpenAccessForSetup
            ? "Proves Keyboard and Full Access"
            : "Proves Keyboard • Full Access still off"
    }

    var showsLiveTranscript: Bool {
        (activeRequestID != nil || isInKeyboardCaptureActive)
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

    /// The mic is not yet delivering audio: before `onListening`, or while
    /// the app is being asked to start.
    var isStartingCapture: Bool {
        dictationPhase == .requested || (dictationPhase == .recording && statusText == "Starting mic")
    }

    var waveformMode: MuesliFloatingWaveformMode {
        MuesliKeyboardWaveformPresentation.mode(for: dictationPhase)
    }

    var waveformLevel: Double? {
        MuesliKeyboardWaveformPresentation.level(for: dictationPhase, inputLevel: inputLevel)
    }

    var canCancelActiveDictation: Bool {
        [.requested, .recording, .transcribing].contains(dictationPhase)
            && !(activeRequestID.map { pendingCancellationIDs.contains($0) } ?? false)
    }

    var selectedTranscriptionModel: KeyboardTranscriptionModelOption? {
        modelCatalog?.selectedModel
    }

    /// Model IDs this keyboard can transcribe with itself. Set by the keyboard
    /// when it dictates in-keyboard. Nil means every model the app has ready
    /// is offered (the Muesli handoff runs any of them).
    var keyboardRunnableModelIDs: (() -> Set<String>)?
    static let appleSpeechRawValue = "apple-speech"

    /// The model menu offers only models this keyboard can actually use, so
    /// picking one never quietly falls back to another engine.
    var readyTranscriptionModels: [KeyboardTranscriptionModelOption] {
        let ready = modelCatalog?.readyModels ?? []
        guard let runnable = keyboardRunnableModelIDs?() else { return ready }
        return ready.filter { $0.rawValue == Self.appleSpeechRawValue || runnable.contains($0.rawValue) }
    }

    var canSelectTranscriptionModel: Bool {
        modelCatalog?.canSelectModels == true
            && !showsActiveWaveform
            && pendingModelRawValue == nil
    }

    /// Names the engine the keyboard will actually use: if the selected model
    /// can't run here, in-keyboard dictation uses Apple Speech.
    var modelChipTitle: String {
        guard let selected = selectedTranscriptionModel else { return "Model" }
        if let runnable = keyboardRunnableModelIDs?(),
           selected.rawValue != Self.appleSpeechRawValue,
           !runnable.contains(selected.rawValue) {
            return "Apple Speech"
        }
        return selected.shortName
    }

    var isModelSelectionPending: Bool {
        pendingModelRawValue != nil
    }

    var settingsURL: URL? {
        var components = URLComponents()
        components.scheme = MuesliAppConstants.urlScheme
        components.host = MuesliAppConstants.settingsHost
        return components.url
    }

    var opensMuesliFromPrimaryButton: Bool {
        !isBlockedByAppVoiceNote
            && !isInKeyboardCaptureActive
            && (recoveryRequestID != nil
                || (needsForegroundStart || !canUseRuntimeStart && !canUseInKeyboardDictation)
                && (
                    dictationPhase == .idle
                        || dictationPhase == .finished
                        || dictationPhase == .failed
                        || (dictationPhase == .requested && activeRequestID == nil)
                ))
    }

    func primaryLaunchAction() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote, !isInKeyboardCaptureActive else { return }
        if recoveryRequestID != nil {
            statusText = "Opening Muesli"
            return
        }

        // A mounted Link opens Muesli as part of the tap. Its callback must
        // prepare the foreground handoff even if inline readiness has changed.
        if !needsForegroundStart, !canUseRuntimeStart {
            logInKeyboardFallbackIfUnavailable(inKeyboardAvailability())
        }
        startHandoffDictation(viaRuntime: false)
    }

    func primaryAction() {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote else { return }
        switch dictationPhase {
        case .requested, .recording:
            stopActiveDictation()
        case .transcribing:
            break
        default:
            startDictation(allowForegroundHandoff: false)
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

            guard textInserter != nil else { return }
            insertText(result.text)
            insertedRequestIDs.insert(result.requestID)
            try store.acknowledgeKeyboardDelivery(for: result.requestID)
            latestResultID = result.id
            hasLatestDictation = true
            statusText = "Inserted"
        } catch {
            statusText = "Enable Full Access"
        }
    }

    /// Fires after the keyboard switches models, so its in-keyboard engine
    /// can load the new one.
    var onTranscriptionModelChanged: (@MainActor () -> Void)?

    /// Switches at once: the keyboard dictates without the app, so it can't
    /// wait for the app to apply the change. The app adopts the pick the next
    /// time it runs.
    func selectTranscriptionModel(_ model: KeyboardTranscriptionModelOption) {
        guard model.isReady,
              let catalog = modelCatalog,
              model.rawValue != catalog.selectedRawValue,
              canSelectTranscriptionModel
        else { return }

        do {
            let updated = KeyboardTranscriptionModelCatalog(
                selectedRawValue: model.rawValue,
                models: catalog.models,
                canSelectModels: catalog.canSelectModels
            )
            try store.saveKeyboardModelSelectionRequest(.init(modelRawValue: model.rawValue))
            try store.saveKeyboardModelCatalog(updated)
            modelCatalog = updated
            statusText = "\(model.shortName) selected"
            KeyboardDiagnosticsLog.record("model.select", ["model": model.rawValue])
            onTranscriptionModelChanged?()
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func prepareLaunchRequestIfNeeded() {
        guard preparedRequest == nil, activeRequestID == nil, recoveryRequestID == nil else { return }
        let request = DictationRequest()
        preparedRequest = request
        launchURL = makeLaunchURL(for: request)
    }

    func startDictation(allowForegroundHandoff: Bool = true) {
        refreshLatestDictation()
        guard !isBlockedByAppVoiceNote, !isInKeyboardCaptureActive,
              !needsForegroundStart || allowForegroundHandoff else { return }
        if startInKeyboardDictationIfAvailable() { return }

        guard canUseRuntimeStart || allowForegroundHandoff else {
            // A Button cannot open Muesli. Let the next tap use the Link and
            // leave request ownership untouched until that tap happens.
            needsForegroundStart = true
            prepareLaunchRequestIfNeeded()
            statusText = "Open Muesli"
            return
        }
        startHandoffDictation(viaRuntime: canUseRuntimeStart)
    }

    private func startHandoffDictation(viaRuntime: Bool) {
        needsForegroundStart = false
        MuesliHaptics.dictationStart()
        KeyboardDiagnosticsLog.record("intent.start", [
            "canUseRuntimeStart": viaRuntime ? "yes" : "no",
            "appPhase": latestRuntimeStatus?.phase.rawValue ?? "unknown",
            "appSeenAt": latestRuntimeStatus.map {
                String(format: "%.1fs", Date.now.timeIntervalSince($0.updatedAt))
            } ?? "never"
        ])
        let request = preparedRequest ?? DictationRequest()
        do {
            try store.claimRequest(request)
        } catch SharedStoreError.requestInProgress {
            refreshLatestDictation()
            statusText = "Finish the current dictation"
            return
        } catch {
            statusText = "Enable Full Access"
            return
        }
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
            try store.saveKeyboardHandoffState(.init(
                requestID: request.id,
                phase: .startRequested,
                message: viaRuntime ? "Starting" : "Opening Muesli"
            ))
            if viaRuntime {
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

        statusText = viaRuntime ? "Starting" : "Recording in Muesli"
    }

    private func stopActiveDictation() {
        if isInKeyboardCaptureActive {
            finishInKeyboardDictation()
            return
        }
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
        if isInKeyboardCaptureActive {
            cancelInKeyboardDictation()
            return
        }
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
            pendingCancellationIDs.insert(activeRequestID)
            latestHandoffState = .init(requestID: activeRequestID, phase: .cancelRequested, message: "Cancelling")
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
        refreshSetupVerificationChallenge()
        refreshLatestDictation()
        prepareLaunchRequestIfNeeded()
    }

    func startObservingSharedState(hasOpenAccess: Bool = true) {
        hasOpenAccessForSetup = hasOpenAccess
        refreshSetupVerificationChallenge()
        KeyboardDiagnosticsLog.record("keyboard.appeared")
        markKeyboardVisible(hasOpenAccess: hasOpenAccess)
        visibilityHeartbeatTask?.cancel()
        visibilityHeartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.publishVisibilityHeartbeat()
            }
        }
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
                case .modelCatalogChanged:
                    self.refreshModelCatalog()
                case .liveTranscriptChanged:
                    self.refreshLiveTranscript()
                case .handoffStatusChanged, .resultChanged, .ownershipChanged:
                    self.refreshLatestDictation()
                case .commandChanged, .modelSelectionRequested:
                    break
                }
            }
        }
    }

    func publishVisibilityHeartbeat() {
        let access = currentFullAccess?() ?? hasOpenAccessForSetup
        hasOpenAccessForSetup = access
        refreshSetupVerificationChallenge()
        // Heartbeats must not replace recording or setup messages on failure.
        try? store.saveKeyboardExtensionStatus(.init(
            lastSeenAt: .now, hasOpenAccess: access, isVisible: true
        ))
    }

    func markKeyboardVisible(hasOpenAccess: Bool = true) {
        hasOpenAccessForSetup = hasOpenAccess
        refreshSetupVerificationChallenge()
        do {
            try store.saveKeyboardExtensionStatus(.init(
                lastSeenAt: .now,
                hasOpenAccess: hasOpenAccess,
                isVisible: true
            ))
        } catch {
            statusText = "Enable Full Access"
        }
    }

    func stopObservingSharedState() {
        abandonInKeyboardDictationForDisappearance()
        needsForegroundStart = false
        // The waveform renders live microphone input. Off screen there is none,
        // so holding the last level is wrong -- and the controller outlives a
        // dismissal, so that stale level gets baked into the launch snapshot
        // and replayed for a moment on the way back in. Settle it now; the
        // refresh in prepareInitialPresentationState repopulates it from the
        // app's published status if a recording is still running.
        inputLevel = 0
        liveTranscript = ""

        KeyboardDiagnosticsLog.record("keyboard.disappeared", [
            "localPhase": dictationPhase.rawValue,
            "active": activeRequestID?.uuidString.prefix(8).lowercased() ?? "none"
        ])
        eventObservationTask?.cancel()
        eventObservationTask = nil
        commandAcknowledgementTask?.cancel()
        commandAcknowledgementTask = nil
        visibilityHeartbeatTask?.cancel()
        visibilityHeartbeatTask = nil
        if let status = try? store.keyboardExtensionStatus() {
            try? store.saveKeyboardExtensionStatus(.init(
                lastSeenAt: .now,
                hasOpenAccess: status.hasOpenAccess,
                isVisible: false
            ))
        }
    }

    func verifyKeyboardSetup() {
        refreshSetupVerificationChallenge()
        guard let challenge = setupVerificationChallenge, challenge.isActive() else {
            statusText = "Return to Muesli and restart the test"
            return
        }

        // Inserting the nonce response through UITextDocumentProxy proves that
        // this keyboard is both installed and active. It deliberately bypasses
        // insertText(_:), whose character count belongs to transcript replacement.
        textInserter?(challenge.responseToken)
        if hasOpenAccessForSetup {
            setupVerificationStore.saveKeyboardReceipt(
                for: challenge,
                hasFullAccess: true
            )
            statusText = "Setup verified"
        } else {
            statusText = "Keyboard verified • Enable Full Access"
        }
    }

    private func refreshSetupVerificationChallenge() {
        setupVerificationChallenge = setupVerificationStore.activeKeyboardChallenge()
    }

    private func refreshLatestDictation() {
        refreshInKeyboardAvailability()
        // The app's shared status describes handoff requests only; applying it
        // mid-capture could adopt an older request and overwrite local phase.
        guard !isInKeyboardCaptureActive else {
            refreshModelCatalog()
            return
        }
        do {
            refreshModelCatalog()
            let runtimeStatus = try store.keyboardRuntimeStatus()
            latestRuntimeStatus = runtimeStatus
            let status = try store.status()
            let handoffState = try store.keyboardHandoffState()
            if handoffState.phase == .copyRequired, let requestID = handoffState.requestID {
                completedClipboardRequestIDs.insert(requestID)
            }
            if handoffState.phase == .cancelled, let requestID = handoffState.requestID {
                cancelledRequestIDs.insert(requestID)
                pendingCancellationIDs.remove(requestID)
            }
            if handoffState.phase == .inserted, let requestID = handoffState.requestID {
                insertedRequestIDs.insert(requestID)
            }
            apply(runtimeStatus: runtimeStatus)
            if let command = try store.pendingCommand(), command.action == .cancel {
                pendingCancellationIDs.insert(command.requestID)
            }
            latestHandoffState = handoffState
            apply(handoffState: handoffState)
            apply(liveTranscript: try store.keyboardLiveTranscript())

            let statusBelongsToAppVoiceNote = applyAppVoiceNoteOwnership(status: status)
            if !statusBelongsToAppVoiceNote,
               (handoffState.requestID == nil || status.requestID == handoffState.requestID),
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
            // Delivery is independent of whichever request now owns capture.
            for pending in try store.pendingKeyboardDeliveries() {
                insertCompletedResult(pending)
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

    private func refreshModelCatalog() {
        guard let catalog = try? store.keyboardModelCatalog() else { return }
        modelCatalog = catalog
        guard let pendingModelRawValue else { return }

        if catalog.selectedRawValue == pendingModelRawValue {
            self.pendingModelRawValue = nil
            if !isInKeyboardCaptureActive {
                statusText = "\(catalog.selectedModel?.shortName ?? "Model") ready"
            }
        } else if (try? store.keyboardModelSelectionRequest()) == nil {
            self.pendingModelRawValue = nil
            if !isInKeyboardCaptureActive {
                statusText = catalog.canSelectModels ? "Model unchanged" : "Finish recording to switch"
            }
        }
    }

    private func refreshRuntimeStatus() {
        guard !isInKeyboardCaptureActive else { return }
        do {
            let runtimeStatus = try store.keyboardRuntimeStatus()
            latestRuntimeStatus = runtimeStatus
            apply(runtimeStatus: runtimeStatus)
        } catch {
            statusText = "Waiting for Full Access"
        }
    }

    private func refreshLiveTranscript() {
        guard !isInKeyboardCaptureActive else { return }
        do {
            apply(liveTranscript: try store.keyboardLiveTranscript())
        } catch {
            statusText = "Waiting for Full Access"
        }
    }

    private func apply(handoffState: KeyboardHandoffState) {
        guard let requestID = handoffState.requestID else { return }

        if let activeRequestID, activeRequestID != requestID {
            // A resumed extension must follow the durable owner, even if the
            // previous request completed while this keyboard was off screen.
            self.activeRequestID = nil
            recoveryRequestID = nil
            preparedRequest = nil
            liveTranscript = ""
            inputLevel = 0
            dictationPhase = .idle
        }

        // The handoff record is written by both processes with no ordering
        // guarantee, so record what arrived and what we were already showing.
        // A phase that moves backwards is visible here and nowhere else.
        if lastRecordedHandoff?.phase != handoffState.phase
            || lastRecordedHandoff?.requestID != requestID {
            lastRecordedHandoff = (requestID, handoffState.phase)
            KeyboardDiagnosticsLog.record("handoff.observed", [
                "phase": handoffState.phase.rawValue,
                "request": requestID.uuidString.prefix(8).lowercased(),
                "localPhase": dictationPhase.rawValue,
                "active": activeRequestID?.uuidString.prefix(8).lowercased() ?? "none",
                "inserted": insertedRequestIDs.contains(requestID) ? "yes" : "no"
            ])
        }

        if insertedRequestIDs.contains(requestID) {
            reconcileInsertedRequest(requestID)
            return
        }

        // A late recorder/transcriber update must not reverse the user's Cancel.
        if pendingCancellationIDs.contains(requestID) {
            if [.cancelled, .failed, .idle].contains(handoffState.phase) {
                pendingCancellationIDs.remove(requestID)
                cancelledRequestIDs.insert(requestID)
            } else if !(handoffState.phase == .recoveryRequested && handoffState.recoveryAction == .cancel) {
                activeRequestID = requestID
                recoveryRequestID = nil
                latestHandoffState = .init(requestID: requestID, phase: .cancelRequested, message: "Cancelling")
                dictationPhase = .recording
                inputLevel = 0
                liveTranscript = ""
                statusText = "Cancelling"
                return
            }
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

        if completedClipboardRequestIDs.contains(requestID) {
            activeRequestID = nil
            recoveryRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            dictationPhase = .finished
            statusText = handoffState.phase == .copyRequired
                ? "Saved — open Muesli to copy" : "Saved to Voice Notes"
            return
        }

        activeRequestID = requestID

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
        case .copyRequired:
            dictationPhase = .finished
            activeRequestID = nil
            liveTranscript = ""
            inputLevel = 0
            statusText = "Saved — open Muesli to copy"
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
        // The waveform draws live microphone input. It needs two facts and no
        // bookkeeping: the app is recording, and a level arrived recently.
        //
        // This used to also require the level to name the request this keyboard
        // had adopted. That match was added when the waveform was first switched
        // on, not in response to any bug, and it caused one: iOS destroys and
        // rebuilds the keyboard constantly, and a rebuilt one has adopted
        // nothing, so levels milliseconds old were thrown away and every bar
        // collapsed to zero while the pill still said "Listening".
        //
        // It is not what stops the keyboard rendering an in-app voice note's
        // audio either. A recording the keyboard does not own blocks it
        // outright and hides the waveform card -- see applyAppVoiceNoteOwnership.
        //
        // The freshness rule stays: when levels stop arriving the bars settle
        // rather than freezing on the last sample.
        let hasFreshRecordingLevel = runtimeStatus.map {
            $0.phase == .recording && now.timeIntervalSince($0.updatedAt) < 2
        } ?? false
        // A recording whose levels have gone stale collapses every waveform bar
        // to zero, so the strip looks empty while the pill still says
        // "Listening". Record the transition, not every sample.
        if runtimeStatus?.phase == .recording, hasFreshRecordingLevel != lastLevelFreshness {
            lastLevelFreshness = hasFreshRecordingLevel
            KeyboardDiagnosticsLog.record("level.freshness", [
                "fresh": hasFreshRecordingLevel ? "yes" : "no",
                "age": runtimeStatus.map { String(format: "%.1fs", now.timeIntervalSince($0.updatedAt)) } ?? "none",
                "appPhase": runtimeStatus?.phase.rawValue ?? "none",
                "matchesActive": runtimeStatus?.activeRequestID == activeRequestID ? "yes" : "no"
            ])
        }
        inputLevel = hasFreshRecordingLevel ? (runtimeStatus?.inputLevel ?? 0) : 0
        canUseRuntimeStart = runtimeStatus.map {
            $0.canAcceptStartCommand && now.timeIntervalSince($0.updatedAt) < handoffRecoveryPolicy.runtimeFreshnessInterval
        } ?? false

        guard activeRequestID == nil, canUseRuntimeStart else { return }
        guard let runtimeRequestID = runtimeStatus?.activeRequestID,
              !insertedRequestIDs.contains(runtimeRequestID),
              !cancelledRequestIDs.contains(runtimeRequestID),
              !completedClipboardRequestIDs.contains(runtimeRequestID)
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

        if insertedRequestIDs.contains(requestID) {
            reconcileInsertedRequest(requestID)
            return
        }
        if cancelledRequestIDs.contains(requestID) || completedClipboardRequestIDs.contains(requestID) {
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
            launchURL = makeLaunchURL(for: requestID, action: urlAction(for: recovery.recoveryAction ?? .start))
            dictationPhase = .failed
            activeRequestID = nil
            liveTranscript = ""
            statusText = recovery.message ?? "Open Muesli to finish"
            return true
        }
    }

    private func reconcileInsertedRequest(_ requestID: UUID) {
        // A delayed completion for A must not reset a newer dictation B.
        guard activeRequestID == nil || activeRequestID == requestID else { return }
        activeRequestID = nil
        recoveryRequestID = nil
        liveTranscript = ""
        inputLevel = 0
        dictationPhase = .idle
        statusText = "Latest ready"
    }

    private func insertCompletedResult(_ result: DictationResult) {
        guard textInserter != nil, !pendingCancellationIDs.contains(result.requestID) else { return }
        // Only an explicit resultReady handoff queues automatic insertion.
        // Capture source does not determine whether the keyboard may deliver it.
        let shortID = result.requestID.uuidString.prefix(8).lowercased()

        guard !insertedRequestIDs.contains(result.requestID) else {
            try? store.acknowledgeKeyboardDelivery(for: result.requestID)
            reconcileInsertedRequest(result.requestID)
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
        try? store.acknowledgeKeyboardDelivery(for: result.requestID)
        // Acknowledging A must not clear B's command, transcript, or UI.
        guard activeRequestID == result.requestID else { return }
        activeRequestID = nil
        liveTranscript = ""
        preparedRequest = nil
        recoveryRequestID = nil
        launchURL = nil
        dictationPhase = .idle
        statusText = "Latest ready"
        try? store.clearPendingRequest(matching: result.requestID)
        try? store.clearPendingCommand(matching: result.requestID)
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
        if phase == .cancelRequested, pendingCancellationIDs.contains(requestID) {
            return state.requestID == requestID && ![.cancelled, .failed, .idle].contains(state.phase)
        }
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

// MARK: - In-keyboard dictation

extension KeyboardController {
    /// Re-evaluates whether Record should capture in the keyboard. Called on
    /// refresh and when the capture web view becomes ready.
    func refreshInKeyboardAvailability() {
        let availability = inKeyboardAvailability()
        canUseInKeyboardDictation = availability == .available
    }

    /// Releases the microphone when the keyboard goes away. Speech heard so far
    /// is kept in history rather than inserted into a field that is gone.
    func abandonInKeyboardDictationForDisappearance() {
        guard isInKeyboardCaptureActive else { return }
        if let requestID = inKeyboardRequestID, inKeyboardDictation?.holdsModelAudio == true {
            // The keyboard model holds the only copy of this audio, and Apple
            // Speech's partial may be empty or missing. Stop the mic, but let
            // the model finish; its text goes to history, not the gone field.
            dismissedInKeyboardRequestID = requestID
            if dictationPhase == .recording {
                inKeyboardDictation?.finish()
                dictationPhase = .transcribing
            }
            KeyboardDiagnosticsLog.record("inline.dismissedWithModelAudio")
            return
        }
        let partial = inKeyboardPartialTranscript
        inKeyboardDictation?.cancel()
        if let requestID = inKeyboardRequestID {
            let customWords = (try? store.customWords()) ?? []
            let text = InKeyboardDictationPreferences.postProcess(partial, customWords: customWords)
            saveInKeyboardResult(text: text, requestID: requestID)
        }
        resetInKeyboardState(status: hasLatestDictation ? "Latest ready" : "Ready")
        KeyboardDiagnosticsLog.record("inline.abandoned", ["characters": String(partial.count)])
    }

    private func inKeyboardAvailability() -> InKeyboardDictationAvailability {
        guard let inKeyboardDictation else { return .disabled }
        return inKeyboardDictation.availability(hasFullAccess: currentFullAccess?() ?? false)
    }

    private func logInKeyboardFallbackIfUnavailable(_ availability: InKeyboardDictationAvailability) {
        guard availability != .available, availability != .disabled else { return }
        KeyboardDiagnosticsLog.record("inline.fallback", ["reason": availability.fallbackReason])
    }

    /// When Muesli's own mic session is already running, the runtime handoff
    /// starts without leaving the host app and uses Muesli's local models, so
    /// it wins. In-keyboard capture covers the case that would otherwise open
    /// Muesli. Any unavailability falls back to the handoff.
    fileprivate func startInKeyboardDictationIfAvailable() -> Bool {
        guard !isInKeyboardCaptureActive,
              recoveryRequestID == nil,
              activeRequestID == nil,
              !canUseRuntimeStart else { return false }
        let availability = inKeyboardAvailability()
        canUseInKeyboardDictation = availability == .available
        guard availability == .available, let inKeyboardDictation else {
            logInKeyboardFallbackIfUnavailable(availability)
            return false
        }

        let requestID = UUID()
        let handlers = InKeyboardDictationHandlers(
            onListening: { [weak self] in
                guard let self, self.inKeyboardRequestID == requestID else { return }
                self.statusText = "Listening on device"
            },
            onPartial: { [weak self] text in
                guard let self, self.inKeyboardRequestID == requestID else { return }
                self.inKeyboardPartialTranscript = text
                self.liveTranscript = text
            },
            onLevel: { [weak self] level in
                guard let self, self.inKeyboardRequestID == requestID else { return }
                self.inputLevel = level
            },
            onPreparingModel: { [weak self] name in
                guard let self, self.inKeyboardRequestID == requestID else { return }
                self.statusText = "Preparing \(name)…"
            },
            onReachedLimit: { [weak self] in
                guard let self, self.inKeyboardRequestID == requestID else { return }
                self.finishInKeyboardDictation()
            },
            onCompleted: { [weak self] text, engine in
                self?.completeInKeyboardDictation(requestID: requestID, rawText: text, engine: engine)
            },
            onFailed: { [weak self] message in
                self?.failInKeyboardDictation(requestID: requestID, message: message)
            }
        )
        guard inKeyboardDictation.start(handlers: handlers) else {
            KeyboardDiagnosticsLog.record("inline.fallback", ["reason": "startRejected"])
            return false
        }

        MuesliHaptics.dictationStart()
        KeyboardDiagnosticsLog.record("inline.start")
        inKeyboardRequestID = requestID
        inKeyboardPartialTranscript = ""
        showsInKeyboardLiveTranscript = inKeyboardLiveTranscriptPreference()
        isInKeyboardCaptureActive = true
        liveTranscript = ""
        inputLevel = 0
        dictationPhase = .recording
        statusText = "Starting mic"
        return true
    }

    fileprivate func finishInKeyboardDictation() {
        guard isInKeyboardCaptureActive, dictationPhase == .recording else { return }
        MuesliHaptics.dictationStop()
        dictationPhase = .transcribing
        inputLevel = 0
        statusText = "Transcribing"
        inKeyboardDictation?.finish()
    }

    fileprivate func cancelInKeyboardDictation() {
        guard isInKeyboardCaptureActive else { return }
        MuesliHaptics.dictationStop()
        inKeyboardDictation?.cancel()
        KeyboardDiagnosticsLog.record("inline.cancelled")
        resetInKeyboardState(status: "Cancelled")
    }

    private func completeInKeyboardDictation(requestID: UUID, rawText: String, engine: String) {
        guard inKeyboardRequestID == requestID else { return }
        let customWords = (try? store.customWords()) ?? []
        let text = InKeyboardDictationPreferences.postProcess(rawText, customWords: customWords)
        KeyboardDiagnosticsLog.record("inline.completed", ["characters": String(text.count), "engine": engine])
        if dismissedInKeyboardRequestID == requestID {
            // Finished after the keyboard was dismissed: keep it in history
            // only; the field it was meant for is gone.
            saveInKeyboardResult(text: text, requestID: requestID, engine: engine)
            resetInKeyboardState(status: hasLatestDictation ? "Latest ready" : "Ready")
            return
        }
        guard !text.isEmpty else {
            resetInKeyboardState(status: "No speech heard")
            return
        }
        insertText(text)
        saveInKeyboardResult(text: text, requestID: requestID, engine: engine)
        resetInKeyboardState(status: "Inserted")
    }

    private func failInKeyboardDictation(requestID: UUID, message: String) {
        guard inKeyboardRequestID == requestID else { return }
        KeyboardDiagnosticsLog.record("inline.failed", ["reason": String(message.prefix(48))])
        resetInKeyboardState(status: "Dictation failed")
        dictationPhase = .failed
    }

    private func saveInKeyboardResult(
        text: String,
        requestID: UUID,
        engine: String = InKeyboardDictationSession.engineIdentifier
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = DictationResult(
            requestID: requestID,
            text: trimmed,
            engineIdentifier: engine,
            source: "keyboard_inline"
        )
        // Never auto-delivered later: this keyboard already inserted it.
        insertedRequestIDs.insert(requestID)
        guard (try? store.saveKeyboardInlineResult(result)) != nil else { return }
        latestResultID = result.id
        hasLatestDictation = true
    }

    private func resetInKeyboardState(status: String) {
        dismissedInKeyboardRequestID = nil
        isInKeyboardCaptureActive = false
        inKeyboardRequestID = nil
        inKeyboardPartialTranscript = ""
        showsInKeyboardLiveTranscript = false
        liveTranscript = ""
        inputLevel = 0
        dictationPhase = .idle
        statusText = status
        refreshInKeyboardAvailability()
        prepareLaunchRequestIfNeeded()
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
