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

                Button {
                    controller.insertLatestDictation()
                } label: {
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
                .buttonStyle(.plain)
                .disabled(controller.isPrimaryButtonDisabled)
            }
            .padding(MuesliTheme.spacing12)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )

            HStack(spacing: MuesliTheme.spacing8) {
                KeyboardKey(title: "space") {
                    controller.insertSpace()
                }
                KeyboardKey(title: "return") {
                    controller.insertReturn()
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundDeep)
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

private struct KeyboardKey: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
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
}
