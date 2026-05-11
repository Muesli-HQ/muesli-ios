import ActivityKit
import SwiftUI
import WidgetKit

struct MuesliRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MuesliLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityWaveform(accent: context.state.accent)
                        .frame(width: 48, height: 30)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("muesli")
                            .font(.headline)
                        Text(context.state.phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                LiveActivityWaveform(accent: context.state.accent)
                    .frame(width: 24, height: 16)
            } compactTrailing: {
                Image(systemName: iconName(for: context.state.phase))
                    .foregroundStyle(color(for: context.state.accent))
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(color(for: context.state.accent))
            }
            .keylineTint(color(for: context.state.accent))
        }
    }

    private func iconName(for phase: String) -> String {
        switch phase.lowercased() {
        case "listening", "recording":
            "mic.fill"
        case "transcribing":
            "waveform"
        default:
            "checkmark"
        }
    }
}

private struct LockScreenLiveActivityView: View {
    let state: MuesliLiveActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            LiveActivityWaveform(accent: state.accent)
                .frame(width: 54, height: 34)
                .padding(10)
                .background(color(for: state.accent).opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("muesli")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(state.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }

            Spacer()

            Text(state.startedAt, style: .timer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding()
    }
}

private struct LiveActivityWaveform: View {
    let accent: String

    private let bars: [CGFloat] = [0.35, 0.65, 0.9, 0.45, 1.0, 0.72, 0.38]

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let width = max(2, (geometry.size.width - spacing * CGFloat(bars.count - 1)) / CGFloat(bars.count))
            HStack(spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                        .fill(color(for: accent))
                        .frame(width: width, height: max(4, geometry.size.height * bar))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private func color(for accent: String) -> Color {
    switch accent {
    case "red":
        .red
    case "orange":
        .orange
    default:
        .blue
    }
}
