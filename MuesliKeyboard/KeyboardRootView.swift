import SwiftUI

struct KeyboardRootView: View {
    @Bindable var controller: KeyboardController

    var body: some View {
        VStack(spacing: MuesliTheme.spacing12) {
            VStack(spacing: MuesliTheme.spacing12) {
                HStack(spacing: MuesliTheme.spacing12) {
                    Image("MuesliMenuIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(controller.isWaitingForResult ? MuesliTheme.transcribing : MuesliTheme.accent)
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
                    controller.beginDictation()
                } label: {
                    Label(
                        controller.isWaitingForResult ? "Dictating..." : "Start Dictation",
                        systemImage: controller.isWaitingForResult ? "waveform" : "mic.fill"
                    )
                    .font(MuesliTheme.headline())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(controller.isWaitingForResult ? MuesliTheme.transcribing : MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(controller.isWaitingForResult)
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
