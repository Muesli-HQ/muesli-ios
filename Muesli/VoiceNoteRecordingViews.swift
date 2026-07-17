import SwiftUI

struct VoiceNoteWaveformLeaf: View {
    let liveState: VoiceNoteLiveState
    let mode: MuesliFloatingWaveformMode
    let color: Color
    let isActive: Bool
    var barCount = 32
    var usesPreviewSignal = false

    @State private var previewInputLevel = 0.0

    var body: some View {
        MuesliInlineWaveformView(
            mode: mode,
            color: color,
            level: displayedLevel,
            isActive: isActive,
            barCount: barCount,
            refreshDriver: .inputLevel
        )
        .task(id: previewTaskIsActive) {
            guard previewTaskIsActive else { return }
            await runPreviewWaveform()
        }
    }

    private var displayedLevel: Double? {
        guard isActive, mode == .level else { return nil }
        return usesPreviewSignal ? previewInputLevel : liveState.inputLevel
    }

    private var previewTaskIsActive: Bool {
        usesPreviewSignal && isActive
    }

    private func runPreviewWaveform() async {
        var tick = 0.0
        while !Task.isCancelled {
            let phrase = (sin(tick * 0.82) + 1) * 0.28
            let syllable = (sin(tick * 2.7) + 1) * 0.18
            let transient = (sin(tick * 7.1) + 1) * 0.08
            if sin(tick * 0.31) > 0.72 {
                previewInputLevel = 0.02
            } else {
                previewInputLevel = min(0.95, max(0.02, 0.08 + phrase + syllable + transient))
            }
            tick += 0.18
            try? await Task.sleep(for: .milliseconds(55))
        }
    }
}

struct VoiceNoteElapsedBadge: View {
    let liveState: VoiceNoteLiveState
    let color: Color
    var isActive = true

    @ViewBuilder
    var body: some View {
        if isActive {
            let value = VoiceNoteDurationFormatter.standard(liveState.elapsedSeconds)
            Text(value)
                .font(MuesliTheme.captionMedium())
                .monospacedDigit()
                .foregroundStyle(color)
                .padding(.horizontal, MuesliTheme.spacing8)
                .padding(.vertical, MuesliTheme.spacing4)
                .background(color.opacity(0.13))
                .clipShape(Capsule())
                .accessibilityLabel("Recording elapsed time")
                .accessibilityValue(value)
        }
    }
}

struct LongVoiceNoteElapsedText: View {
    let liveState: VoiceNoteLiveState

    var body: some View {
        Text(VoiceNoteDurationFormatter.padded(liveState.elapsedSeconds))
            .font(.system(.title3, design: .monospaced, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.top, MuesliTheme.spacing4)
            .accessibilityLabel("Recording elapsed time")
    }
}

struct VoiceNoteLiveTranscriptRegion: View {
    let liveState: VoiceNoteLiveState

    var body: some View {
        let preview = VoiceNoteTranscriptPreview.text(from: liveState.transcript)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: "text.bubble")
                Text("Live Transcript")
            }
            .font(MuesliTheme.captionMedium())
            .foregroundStyle(MuesliTheme.accent)

            Text(preview.isEmpty ? "Listening for speech…" : preview)
                .font(MuesliTheme.body())
                .foregroundStyle(preview.isEmpty ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
                .lineLimit(4, reservesSpace: true)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentTransition(.identity)
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .muesliGlassSurface(cornerRadius: MuesliTheme.cornerMedium, tint: MuesliTheme.accent)
        .accessibilityElement(children: .combine)
        .accessibilityValue(liveState.transcript)
    }
}

enum VoiceNoteDurationFormatter {
    static func standard(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func padded(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

enum VoiceNoteTranscriptPreview {
    static let maximumCharacters = 600

    static func text(from transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }

        let start = trimmed.index(trimmed.endIndex, offsetBy: -maximumCharacters)
        let suffix = trimmed[start...]
        let wordBoundary = suffix.firstIndex(where: { $0.isWhitespace })
        let bounded = wordBoundary.map { suffix[suffix.index(after: $0)...] } ?? suffix[...]
        return "…" + bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
