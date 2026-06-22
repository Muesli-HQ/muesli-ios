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
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
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
                        .fill(controller.isPrimaryButtonDisabled ? MuesliTheme.surfacePrimary : buttonColor)
                        .frame(width: 62, height: 62)
                        .overlay(
                            Circle()
                                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: controller.isPrimaryButtonDisabled ? 1 : 0)
                        )

                    Image(systemName: controller.primaryButtonIcon)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(controller.isPrimaryButtonDisabled ? MuesliTheme.textTertiary : .white)
                }

                Text(controller.primaryButtonTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(controller.isPrimaryButtonDisabled ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 82)
        }
        .frame(maxWidth: .infinity)
        .padding(MuesliTheme.spacing12)
        .contentShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
    }

    private var keyboardHint: String {
        if controller.opensMuesliFromPrimaryButton {
            return "Tap mic to open Muesli, then return here to stop and insert."
        }

        switch controller.dictationPhase {
        case .requested, .recording:
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
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
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
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
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
