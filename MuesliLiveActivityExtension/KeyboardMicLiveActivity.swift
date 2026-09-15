import ActivityKit
import SwiftUI
import WidgetKit

struct KeyboardMicLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KeyboardMicActivityAttributes.self) { context in
            controls(context)
                .padding()
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { controls(context) }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(LiveActivityInputWaveform.tint)
                    .accessibilityLabel("Muesli microphone on")
            } compactTrailing: {
                if context.state.isRecording {
                    LiveActivityInputWaveform(samples: context.state.waveform)
                        .frame(width: 24, height: 20)
                } else {
                    Image(systemName: context.state.isReady ? "checkmark" : "pause.fill")
                        .accessibilityLabel(context.state.title)
                }
            } minimal: {
                if context.state.isRecording {
                    LiveActivityInputWaveform(samples: context.state.waveform)
                        .frame(width: 24, height: 20)
                } else {
                    Image(systemName: "mic.fill").foregroundStyle(LiveActivityInputWaveform.tint)
                        .accessibilityLabel(context.state.title)
                }
            }
        }
    }

    private func controls(_ context: ActivityViewContext<KeyboardMicActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill").foregroundStyle(LiveActivityInputWaveform.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.title).font(.headline)
                Text("Muesli keyboard").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if context.state.isRecording {
                LiveActivityInputWaveform(samples: context.state.waveform)
                        .frame(width: 24, height: 20)
            }
            Button(intent: TurnOffKeyboardMicIntent(sessionID: context.attributes.sessionID)) {
                Label("Turn mic off", systemImage: "mic.slash.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(.red.opacity(0.25), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }
}
