import SwiftUI

struct KeyboardRootView: View {
    @Bindable var controller: KeyboardController

    var body: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            VStack(spacing: MuesliTheme.spacing12) {
                HStack(spacing: MuesliTheme.spacing12) {
                    MuesliWaveformView(
                        isActive: false,
                        color: .white,
                        barCount: 9,
                        spacing: 1.4
                    )
                        .frame(width: 22, height: 20)
                        .frame(width: 44, height: 44)
                        .background(buttonColor)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("muesli")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(controller.statusText)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }

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
                        Label("Insert Latest", systemImage: "text.insert")
                            .font(MuesliTheme.captionMedium())
                            .foregroundStyle(MuesliTheme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(MuesliTheme.accentSubtle)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
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
        Label(
            controller.primaryButtonTitle,
            systemImage: controller.primaryButtonIcon
        )
        .font(MuesliTheme.headline())
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(buttonColor)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
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
