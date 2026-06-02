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
    var spacing: CGFloat = 5

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
    }

    private func waveformBars(elapsed: TimeInterval) -> some View {
        GeometryReader { geometry in
            let count = max(12, barCount)
            let totalSpacing = spacing * CGFloat(count - 1)
            let barWidth = max(3, min(8, (geometry.size.width - totalSpacing) / CGFloat(count)))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(color.opacity(mode == .waiting ? waitingOpacity(index: index, elapsed: elapsed) : 0.92))
                        .frame(
                            width: barWidth,
                            height: barHeight(
                                index: index,
                                elapsed: elapsed,
                                maxHeight: geometry.size.height
                            )
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func barHeight(
        index: Int,
        elapsed: TimeInterval,
        maxHeight: CGFloat
    ) -> CGFloat {
        let minHeight: CGFloat = 4
        let maxBarHeight = max(minHeight, maxHeight)
        let base = basePattern[index % basePattern.count]
        let amplitude: CGFloat

        switch mode {
        case .level:
            let normalized = CGFloat(min(max(level ?? 0.28, 0), 1))
            amplitude = max(0.12, base * (0.24 + normalized * 0.88))
        case .waiting:
            let phase = CGFloat(elapsed) * 5.8 + CGFloat(index) * 0.72
            amplitude = 0.18 + (sin(phase) + 1) * 0.18 + base * 0.48
        }

        return min(maxBarHeight, max(minHeight, minHeight + (maxBarHeight - minHeight) * amplitude))
    }

    private func waitingOpacity(index: Int, elapsed: TimeInterval) -> Double {
        let phase = CGFloat(elapsed) * 5.8 + CGFloat(index) * 0.72
        return Double(0.48 + (sin(phase) + 1) * 0.16)
    }
}
