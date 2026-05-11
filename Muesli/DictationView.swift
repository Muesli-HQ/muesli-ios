import SwiftUI

struct DictationView: View {
    @Bindable var coordinator: DictationCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    header
                    recorderPanel
                    transcriptPanel
                    statusGrid
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.top, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing24)
            }
            .background(MuesliTheme.backgroundBase)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            HStack(spacing: MuesliTheme.spacing12) {
                Image("MuesliAppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                Text("muesli")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }

            Text("Local-first voice input for iOS")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var recorderPanel: some View {
        MuesliSurface(cornerRadius: MuesliTheme.cornerLarge) {
            VStack(spacing: MuesliTheme.spacing20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        Text("Dictation")
                            .font(MuesliTheme.title3())
                            .foregroundStyle(MuesliTheme.textPrimary)
                        Text(coordinator.statusText)
                            .font(MuesliTheme.callout())
                            .foregroundStyle(statusColor)
                    }

                    Spacer()

                    Image("MuesliMenuIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .padding(13)
                        .foregroundStyle(statusColor)
                        .background(statusColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }

                Button {
                    coordinator.toggleRecording()
                } label: {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Image(systemName: coordinator.isRecording ? "stop.fill" : "mic.fill")
                        Text(coordinator.isRecording ? "Stop Recording" : "Start Dictation")
                    }
                    .font(MuesliTheme.headline())
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(statusColor)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .padding()
        }
    }

    @ViewBuilder
    private var transcriptPanel: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack {
                    Text("Latest Transcript")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Text(coordinator.lastTranscript.isEmpty ? "Your next dictation will appear here." : coordinator.lastTranscript)
                    .font(MuesliTheme.body())
                    .foregroundStyle(coordinator.lastTranscript.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 72, alignment: .topLeading)
            }
            .padding(MuesliTheme.spacing16)
        }
    }

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: MuesliTheme.spacing12) {
            MiniStat(icon: "keyboard", value: "Keyboard", label: "handoff ready", color: MuesliTheme.accent)
            MiniStat(icon: "lock.shield", value: "Private", label: "local shell", color: MuesliTheme.success)
        }
    }

    private var statusColor: Color {
        if coordinator.isRecording {
            MuesliTheme.recording
        } else if coordinator.statusText == "Transcribing" {
            MuesliTheme.transcribing
        } else {
            MuesliTheme.accent
        }
    }
}

private struct MiniStat: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        MuesliSurface {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
            Text(value)
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                Text(label)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MuesliTheme.spacing16)
        }
    }
}
