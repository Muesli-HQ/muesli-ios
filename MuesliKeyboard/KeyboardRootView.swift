import SwiftUI

struct KeyboardRootView: View {
    @Bindable var controller: KeyboardController

    var body: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            VStack(spacing: MuesliTheme.spacing8) {
                if controller.opensMuesliFromPrimaryButton, let launchURL = controller.launchURL {
                    Link(destination: launchURL) {
                        primaryButtonLabel
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        controller.primaryLaunchAction()
                    })
                    .buttonStyle(.plain)
                } else {
                    Button {
                        controller.primaryAction()
                    } label: {
                        primaryButtonLabel
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isPrimaryButtonDisabled)
                }

                if controller.showsLiveTranscript {
                    KeyboardLiveTranscriptPreview(text: controller.liveTranscript)
                }

                if controller.canInsertLatest {
                    Button {
                        controller.insertLatestDictation()
                    } label: {
                        KeyboardActionChip(title: "Insert Latest", systemImage: "text.insert")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(MuesliTheme.spacing12)
            .muesliGlassSurface(
                cornerRadius: MuesliTheme.cornerLarge,
                tint: buttonColor,
                isInteractive: true
            )

            HStack(spacing: MuesliTheme.spacing8) {
                KeyboardKey(title: "clear", systemImage: "delete.left") {
                    controller.clearInsertedText()
                }
                KeyboardKey(title: "return") {
                    controller.insertReturn()
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundDeep)
        .onAppear {
            controller.prepareLaunchRequestIfNeeded()
        }
    }

    private var primaryButtonLabel: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                HStack(spacing: MuesliTheme.spacing4) {
                    MuesliWaveformView(
                        isActive: false,
                        color: buttonColor,
                        barCount: 9,
                        spacing: 1.2
                    )
                    .frame(width: 24, height: 18)

                    Text("muesli keyboard")
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textPrimary)
                }

                Text(keyboardHint)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: MuesliTheme.spacing8)

            VStack(spacing: MuesliTheme.spacing4) {
                ZStack {
                    Circle()
                        .fill(primaryButtonCircleFill)
                        .frame(width: 62, height: 62)
                        .overlay(
                            Circle()
                                .strokeBorder(primaryButtonCircleBorder, lineWidth: 1)
                        )

                    Image(systemName: controller.primaryButtonIcon)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(primaryButtonIconColor)
                }

                Text(controller.primaryButtonTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(primaryButtonTitleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 82)
        }
        .frame(maxWidth: .infinity)
        .padding(MuesliTheme.spacing12)
        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
    }

    private var isPrimaryStopButton: Bool {
        controller.stylesPrimaryButtonAsStop
    }

    private var primaryButtonCircleFill: Color {
        if controller.isPrimaryButtonDisabled {
            MuesliTheme.surfacePrimary
        } else if isPrimaryStopButton {
            MuesliTheme.destructive.opacity(0.32)
        } else {
            buttonColor
        }
    }

    private var primaryButtonCircleBorder: Color {
        if controller.isPrimaryButtonDisabled {
            MuesliTheme.surfaceBorder
        } else if isPrimaryStopButton {
            MuesliTheme.destructive.opacity(0.38)
        } else {
            .clear
        }
    }

    private var primaryButtonIconColor: Color {
        if controller.isPrimaryButtonDisabled {
            MuesliTheme.textTertiary
        } else if isPrimaryStopButton {
            .white
        } else {
            .white
        }
    }

    private var primaryButtonTitleColor: Color {
        if controller.isPrimaryButtonDisabled {
            MuesliTheme.textTertiary
        } else if isPrimaryStopButton {
            MuesliTheme.destructive
        } else {
            MuesliTheme.textPrimary
        }
    }

    private var keyboardHint: String {
        if controller.isRecoveryRequested {
            return "Tap Open Muesli to resume your voice note."
        }

        if controller.opensMuesliFromPrimaryButton {
            return "Tap mic to open Muesli, then return here to stop and insert."
        }

        switch controller.dictationPhase {
        case .requested:
            return "Starting. Muesli is preparing to record."
        case .recording:
            return "Listening. Tap stop when you are ready to insert."
        case .transcribing:
            return "Preparing text for this field."
        case .finished:
            return "Inserted into the focused field."
        case .failed:
            return controller.statusText
        default:
            return controller.canInsertLatest ? "Record, or insert your latest voice note." : "Tap mic to record into this text field."
        }
    }

    private var buttonColor: Color {
        switch controller.primaryButtonColor {
        case .accent:
            MuesliTheme.accent
        case .recording:
            MuesliTheme.recording
        case .transcribing:
            MuesliTheme.transcribing
        }
    }
}

private struct KeyboardLiveTranscriptPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: "text.bubble")
                Text("Live Transcript")
            }
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.accent)

            Text(text)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MuesliTheme.spacing12)
        .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: MuesliTheme.accent)
    }
}

private struct KeyboardActionChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(MuesliTheme.accentSubtle)
            .clipShape(Capsule())
            .contentShape(Capsule())
    }
}

private struct KeyboardKey: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.plain)
        .muesliGlassButton(cornerRadius: MuesliTheme.cornerMedium)
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        } else {
            Text(title)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }
}
