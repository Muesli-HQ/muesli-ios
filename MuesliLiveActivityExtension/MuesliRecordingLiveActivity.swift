import ActivityKit
import SwiftUI
import WidgetKit

struct MuesliRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MuesliLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(
                state: context.state,
                sessionID: context.attributes.sessionID
            )
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityBrandMark(assetName: "MuesliLiveActivityLogoLarge")
                        .frame(width: 38, height: 38)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("muesli")
                            .font(LiveActivityTypography.wordmark)
                        Text(context.state.phase)
                            .font(LiveActivityTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(spacing: 4) {
                        Text(context.state.startedAt, style: .timer)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        StopMeetingButton(
                            sessionID: context.attributes.sessionID,
                            size: 34
                        )
                    }
                }
            } compactLeading: {
                LiveActivityBrandMark(assetName: "MuesliLiveActivityLogoSmall")
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                Image(systemName: iconName(for: context.state.phase))
                    .foregroundStyle(color(for: context.state.accent))
            } minimal: {
                LiveActivityBrandMark(assetName: "MuesliLiveActivityLogoSmall")
                    .frame(width: 22, height: 22)
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
    let sessionID: String

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

            Text(state.startedAt, style: .timer)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))

            StopMeetingButton(sessionID: sessionID, size: 46)
        }
        .padding()
    }
}

private struct StopMeetingButton: View {
    let sessionID: String
    let size: CGFloat

    var body: some View {
        Button(intent: StopMeetingRecordingIntent(sessionID: sessionID)) {
            Image(systemName: "stop.fill")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.red.opacity(0.88), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop meeting recording")
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
