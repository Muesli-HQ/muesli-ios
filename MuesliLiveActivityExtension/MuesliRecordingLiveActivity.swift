import ActivityKit
import SwiftUI
import WidgetKit

struct MuesliRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MuesliLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(
                state: context.state,
                sessionID: context.attributes.sessionID,
                kind: context.attributes.kind,
                showsStopControl: context.attributes.showsStopControl,
                showsWaveform: context.attributes.showsDictationWaveform == true
            )
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        LiveActivityBrandMark(assetName: "MuesliLiveActivityLogoSmall")
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(context.state.phase)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(context.state.copyURL == nil ? "muesli" : "Saved on this iPhone")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if context.state.isCapturingAudio {
                            if context.attributes.showsDictationWaveform == true {
                                LiveActivityInputWaveform(samples: context.state.waveform)
                                    .frame(width: 30, height: 22)
                            }
                            Text(context.state.startedAt, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 46)
                            if context.attributes.showsStopControl {
                                StopMeetingButton(sessionID: context.attributes.sessionID, kind: context.attributes.kind, size: 36)
                            }
                        } else if let url = context.state.copyURL {
                            Link(destination: url) {
                                Label("Open to copy", systemImage: "doc.on.doc")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .background(.blue.opacity(0.25), in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                LiveActivityBrandMark(assetName: "MuesliLiveActivityLogoSmall")
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                if context.attributes.showsDictationWaveform == true && context.state.isCapturingAudio {
                    LiveActivityInputWaveform(samples: context.state.waveform)
                        .frame(width: 24, height: 20)
                } else {
                    Image(systemName: iconName(for: context.state.phase))
                        .foregroundStyle(color(for: context.state.accent))
                }
            } minimal: {
                if context.attributes.showsDictationWaveform == true && context.state.isCapturingAudio {
                    LiveActivityInputWaveform(samples: context.state.waveform)
                        .frame(width: 22, height: 18)
                } else {
                    LiveActivityBrandMark(assetName: "MuesliLiveActivityLogoSmall")
                        .frame(width: 22, height: 22)
                }
            }
            .keylineTint(color(for: context.state.accent))
            .widgetURL(context.state.copyURL)
        }
    }

    private func iconName(for phase: String) -> String {
        switch phase.lowercased() {
        case "listening", "recording":
            "mic.fill"
        case "transcribing":
            "waveform"
        case "ready to copy":
            "doc.on.doc"
        default:
            "checkmark"
        }
    }
}

private struct LockScreenLiveActivityView: View {
    let state: MuesliLiveActivityAttributes.ContentState
    let sessionID: String
    let kind: String
    let showsStopControl: Bool
    let showsWaveform: Bool

    var body: some View {
        HStack(spacing: 14) {
            LiveActivityBrandMark(assetName: "MuesliLiveActivityLogoLarge")
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text("muesli")
                    .font(LiveActivityTypography.wordmark)
                    .foregroundStyle(.white)
                Text(state.detail)
                    .font(LiveActivityTypography.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer()

            if showsWaveform && state.isCapturingAudio {
                LiveActivityInputWaveform(samples: state.waveform)
                    .frame(width: 28, height: 22)
            }

            if state.isCapturingAudio {
                Text(state.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 48)
            } else if let url = state.copyURL {
                Link("Open to copy", destination: url)
                    .font(.caption.weight(.semibold))
            }

            if showsStopControl && state.isCapturingAudio {
                StopMeetingButton(sessionID: sessionID, kind: kind, size: 46)
            }
        }
        .padding()
    }
}

private struct LiveActivityInputWaveform: View {
    let samples: [Double]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let bars = MuesliLiveActivityWaveform.bars(samples)
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(bars.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color(red: 0.40, green: 0.64, blue: 1))
                        .frame(height: 3 + (geometry.size.height - 3) * bars[index])
                }
            }
            .frame(height: geometry.size.height)
            .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.3), value: bars)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone input")
        .accessibilityValue((bars.max() ?? 0) > 0 ? "Sound detected" : "Quiet")
    }
}

private struct StopMeetingButton: View {
    let sessionID: String
    /// The control is shared by every capture kind, so the spoken label has to
    /// name what is actually being stopped. It used to always say "meeting".
    let kind: String
    let size: CGFloat

    var body: some View {
        Button(intent: StopMeetingRecordingIntent(sessionID: sessionID)) {
            Label("Stop", systemImage: "stop.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: size)
                .background(.red.opacity(0.88), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop \(kind.lowercased()) recording")
    }
}

private struct LiveActivityBrandMark: View {
    let assetName: String

    var body: some View {
        GeometryReader { geometry in
            brandImage
                .scaledToFit()
                .clipShape(RoundedRectangle(
                    cornerRadius: geometry.size.width * 0.24,
                    style: .continuous
                ))
        }
        .privacySensitive(false)
        .unredacted()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var brandImage: some View {
        if #available(iOS 18.0, *) {
            Image(assetName)
                .renderingMode(.original)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
        } else {
            Image(assetName)
                .renderingMode(.original)
                .resizable()
        }
    }
}

private enum LiveActivityTypography {
    // The extension is a separate target and cannot import the app-only MuesliTheme definitions.
    static let wordmark = Font.system(.callout, design: .default, weight: .semibold)
    static let body = Font.system(.subheadline, design: .default, weight: .regular)
    static let caption = Font.system(.caption, design: .default, weight: .regular)
}

private func color(for accent: String) -> Color {
    switch accent {
    case "red":
        .red
    case "orange":
        .orange
    case "green":
        .green
    default:
        .blue
    }
}
