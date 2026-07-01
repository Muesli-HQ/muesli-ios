import SwiftUI

struct MuesliWaveformView: View {
    var isActive: Bool
    var color: Color
    var level: Double? = nil
    var barCount: Int = 9
    var spacing: CGFloat = 2

    private static let presets: [Int: [CGFloat]] = [
        5: [0.85, 1.0, 0.35, 1.0, 0.85],
        7: [0.45, 0.85, 1.0, 0.35, 1.0, 0.85, 0.45],
        9: [0.45, 0.65, 0.90, 1.0, 0.45, 1.0, 0.90, 0.65, 0.45],
        11: [0.25, 0.50, 0.80, 1.0, 0.65, 0.30, 0.65, 1.0, 0.80, 0.50, 0.25],
        13: [0.30, 0.50, 0.75, 0.95, 1.0, 0.65, 0.30, 0.65, 1.0, 0.95, 0.75, 0.50, 0.30]
    ]

    private var multipliers: [CGFloat] {
        Self.presets[barCount] ?? Self.presets[9]!
    }

    var body: some View {
        GeometryReader { geometry in
            let bars = multipliers
            let count = bars.count
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = max(2, (geometry.size.width - totalSpacing) / CGFloat(count))
            let maxHeight = geometry.size.height
            let normalizedLevel = CGFloat(min(max(level ?? 1, 0), 1))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(color)
                        .frame(
                            width: barWidth,
                            height: barHeight(
                                for: index,
                                base: bars[index],
                                maxHeight: maxHeight,
                                level: normalizedLevel
                            )
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
            .animation(.linear(duration: 0.08), value: level)
        }
    }

    private func barHeight(for index: Int, base: CGFloat, maxHeight: CGFloat, level: CGFloat) -> CGFloat {
        guard isActive else {
            return max(maxHeight * base, 3)
        }

        let dynamicLevel = 0.18 + (level * 0.82)
        return max(maxHeight * base * dynamicLevel, 3)
    }
}

enum MuesliFloatingWaveformMode: Equatable {
    case level
    case waiting
}

struct MuesliInlineWaveformView: View {
    var mode: MuesliFloatingWaveformMode
    var color: Color
    var level: Double? = nil
    var barCount: Int = 24
    var spacing: CGFloat = 3

    @State private var liveSamples: [CGFloat] = []
    @State private var sampleSequence = 0

    private let basePattern: [CGFloat] = [
        0.18, 0.26, 0.42, 0.58, 0.76, 0.92,
        0.72, 0.46, 0.28, 0.36, 0.62, 0.86,
        0.94, 0.68, 0.44, 0.30, 0.52, 0.80,
        0.66, 0.48, 0.34, 0.24, 0.18, 0.14
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            waveformBars(elapsed: elapsed)
        }
        .onAppear {
            seedLiveSamplesIfNeeded()
        }
        .onChange(of: level ?? 0) { _, newValue in
            appendLiveSample(newValue)
        }
        .onChange(of: mode) { _, _ in
            seedLiveSamplesIfNeeded(force: true)
        }
    }

    private func waveformBars(elapsed: TimeInterval) -> some View {
        GeometryReader { geometry in
            let count = max(48, barCount * 2)
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = max(2, min(5, (geometry.size.width - totalSpacing) / CGFloat(count)))
            let samples = samplesForRender(count: count, elapsed: elapsed)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let sample = samples[index]
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(color.opacity(mode == .waiting ? waitingOpacity(index: index, elapsed: elapsed) : 0.94))
                        .frame(
                            width: barWidth,
                            height: barHeight(
                                sample: sample,
                                maxHeight: geometry.size.height
                            )
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func barHeight(sample: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 1.5
        let maxBarHeight = max(minHeight, maxHeight)
        return min(maxBarHeight, max(minHeight, minHeight + (maxBarHeight - minHeight) * sample))
    }

    private func samplesForRender(count: Int, elapsed: TimeInterval) -> [CGFloat] {
        switch mode {
        case .level:
            let samples = paddedLiveSamples(count: count)
            return samples
        case .waiting:
            return waitingSamples(count: count, elapsed: elapsed)
        }
    }

    private func paddedLiveSamples(count: Int) -> [CGFloat] {
        guard !liveSamples.isEmpty else {
            return Array(repeating: 0.08, count: count)
        }

        let suffix = liveSamples.suffix(count)
        if suffix.count == count {
            return Array(suffix)
        }

        return Array(repeating: 0.08, count: count - suffix.count) + suffix
    }

    private func waitingSamples(count: Int, elapsed: TimeInterval) -> [CGFloat] {
        (0..<count).map { index in
            let base = basePattern[index % basePattern.count]
            let phase = CGFloat(elapsed) * 5.8 + CGFloat(index) * 0.72
            return min(0.86, 0.12 + (sin(phase) + 1) * 0.13 + base * 0.34)
        }
    }

    private func waitingOpacity(index: Int, elapsed: TimeInterval) -> Double {
        let phase = CGFloat(elapsed) * 5.8 + CGFloat(index) * 0.72
        return Double(0.48 + (sin(phase) + 1) * 0.16)
    }

    private func seedLiveSamplesIfNeeded(force: Bool = false) {
        guard force || liveSamples.isEmpty else { return }

        let count = max(48, barCount * 2)
        liveSamples = Array(repeating: 0, count: count)
    }

    private func appendLiveSample(_ rawLevel: Double) {
        guard mode == .level else { return }

        let normalized = CGFloat(min(max(rawLevel, 0), 1))
        let noiseFloor: CGFloat = 0.26
        let gatedLevel = max(0, (normalized - noiseFloor) / (1 - noiseFloor))
        let shaped = pow(gatedLevel, 0.72)
        let texture = CGFloat(0.90 + 0.16 * sin(Double(sampleSequence) * 1.73))
        let sample = gatedLevel <= 0.02 ? 0 : min(0.98, max(0.01, shaped * 0.92 * texture))
        let maxSamples = max(48, barCount * 2) * 3

        sampleSequence += 1
        liveSamples.append(sample)
        if liveSamples.count > maxSamples {
            liveSamples.removeFirst(liveSamples.count - maxSamples)
        }
    }

}
