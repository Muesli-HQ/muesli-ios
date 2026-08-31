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
    case idle
    case level
    case waiting
}

enum MuesliInlineWaveformRefreshDriver: Equatable {
    /// Redraw only when a new metered input level arrives.
    case inputLevel
    /// Animate independently of level publication, used by the keyboard where
    /// cross-process meter values are intentionally throttled.
    case timeline

    func usesTimeline(for mode: MuesliFloatingWaveformMode) -> Bool {
        mode == .waiting || mode == .level && self == .timeline
    }
}

enum MuesliInlineWaveformStyle: Equatable {
    case monochrome
    case electricSpectrum
}

enum MuesliKeyboardWaveformPresentation {
    static func mode(for phase: DictationPhase) -> MuesliFloatingWaveformMode {
        phase == .recording ? .level : .waiting
    }

    static func level(for phase: DictationPhase, inputLevel: Double) -> Double? {
        phase == .recording ? min(max(inputLevel, 0), 1) : nil
    }
}

struct MuesliWaveformLevelThrottle {
    static let minimumPublishInterval: TimeInterval = 0.16
    static let heartbeatInterval: TimeInterval = 0.75

    private var lastPublishedAt = Date.distantPast
    private var lastPublishedLevel = 0.0

    mutating func valueToPublish(_ rawLevel: Double, at now: Date = .now) -> Double? {
        let elapsed = now.timeIntervalSince(lastPublishedAt)
        let normalized = min(max(rawLevel, 0), 1)
        let quantized = (normalized * 40).rounded() / 40
        let changed = quantized != lastPublishedLevel

        guard elapsed >= Self.minimumPublishInterval,
              changed || elapsed >= Self.heartbeatInterval
        else { return nil }

        lastPublishedAt = now
        lastPublishedLevel = quantized
        return quantized
    }
}

struct MuesliInlineWaveformView: View {
    var mode: MuesliFloatingWaveformMode
    var color: Color
    var level: Double? = nil
    var style: MuesliInlineWaveformStyle = .monochrome
    var isActive: Bool = true
    var barCount: Int = 24
    var spacing: CGFloat = 3
    var framesPerSecond: Double = 24
    var refreshDriver: MuesliInlineWaveformRefreshDriver = .inputLevel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let basePattern: [CGFloat] = [
        0.18, 0.26, 0.42, 0.58, 0.76, 0.92,
        0.72, 0.46, 0.28, 0.36, 0.62, 0.86,
        0.94, 0.68, 0.44, 0.30, 0.52, 0.80,
        0.66, 0.48, 0.34, 0.24, 0.18, 0.14
    ]

    var body: some View {
        Group {
            if isActive && !reduceMotion && refreshDriver.usesTimeline(for: mode) {
                TimelineView(.animation(minimumInterval: 1.0 / max(framesPerSecond, 1.0))) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    waveformCanvas(elapsed: elapsed)
                }
            } else {
                waveformCanvas(
                    elapsed: isActive ? Date.now.timeIntervalSinceReferenceDate : 0
                )
            }
        }
    }

    private func waveformCanvas(elapsed: TimeInterval) -> some View {
        GeometryReader { geometry in
            let count = sampleCount
            let samples = samplesForRender(count: count, elapsed: elapsed)
            Canvas { context, size in
                let totalSpacing = spacing * CGFloat(count - 1)
                let barWidth = max(2, min(5, (size.width - totalSpacing) / CGFloat(count)))
                let xOffset = max((size.width - (barWidth * CGFloat(count) + totalSpacing)) / 2, 0)
                let centerY = size.height / 2

                var barPaths: [Path] = []
                barPaths.reserveCapacity(count)
                var combinedPath = Path()

                for index in 0..<count {
                    let sample = samples[index]
                    let height = barHeight(sample: sample, maxHeight: size.height)
                    let rect = CGRect(
                        x: xOffset + CGFloat(index) * (barWidth + spacing),
                        y: centerY - height / 2,
                        width: barWidth,
                        height: height
                    )
                    let path = Path(
                        roundedRect: rect,
                        cornerRadius: barWidth / 2,
                        style: .continuous
                    )
                    barPaths.append(path)
                    combinedPath.addPath(path)
                }

                switch style {
                case .monochrome:
                    for (index, path) in barPaths.enumerated() {
                        context.fill(
                            path,
                            with: .color(
                                color.opacity(
                                    mode == .waiting
                                        ? waitingOpacity(index: index, elapsed: elapsed)
                                        : 0.94
                                )
                            )
                        )
                    }
                case .electricSpectrum:
                    let gradient = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: Self.electricSpectrumColors),
                        startPoint: CGPoint(x: 0, y: centerY),
                        endPoint: CGPoint(x: size.width, y: centerY)
                    )
                    let restingOpacity = mode == .waiting ? 0.82 : 1.0

                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: 5))
                        glow.opacity = 0.58 * restingOpacity
                        glow.fill(combinedPath, with: gradient)
                    }
                    context.drawLayer { bloom in
                        bloom.addFilter(.blur(radius: 1.5))
                        bloom.opacity = 0.88 * restingOpacity
                        bloom.fill(combinedPath, with: gradient)
                    }
                    context.opacity = restingOpacity
                    context.fill(combinedPath, with: gradient)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var sampleCount: Int {
        max(12, barCount)
    }

    private func barHeight(sample: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 1.5
        let maxBarHeight = max(minHeight, maxHeight)
        return min(maxBarHeight, max(minHeight, minHeight + (maxBarHeight - minHeight) * sample))
    }

    private func samplesForRender(count: Int, elapsed: TimeInterval) -> [CGFloat] {
        switch mode {
        case .idle:
            return idleSamples(count: count)
        case .level:
            return liveLevelSamples(count: count, elapsed: elapsed)
        case .waiting:
            return waitingSamples(count: count, elapsed: elapsed)
        }
    }

    private func idleSamples(count: Int) -> [CGFloat] {
        (0..<count).map { index in
            let normalizedIndex = CGFloat(index) / CGFloat(max(count - 1, 1))
            return 0.035 + 0.025 * sin(normalizedIndex * .pi * 4)
        }
    }

    private func liveLevelSamples(count: Int, elapsed: TimeInterval) -> [CGFloat] {
        var samples = Array(repeating: CGFloat.zero, count: count)
        guard let level else { return samples }

        let normalized = CGFloat(min(max(level, 0), 1))
        let gatedLevel = gatedLevel(for: normalized)
        guard gatedLevel > 0.02 else {
            return samples
        }

        let shaped = pow(gatedLevel, 0.72)

        for index in 0..<count {
            let base = basePattern[index % basePattern.count]
            let localPhase = CGFloat(elapsed) * 8.6 + CGFloat(index) * 0.58
            let broadPhase = CGFloat(elapsed) * 2.1 + CGFloat(index) * 0.13
            let motion = 0.48 + 0.30 * sin(localPhase) + 0.16 * sin(broadPhase) + base * 0.35
            let texture = 0.90 + 0.12 * sin(localPhase * 1.47)
            let sample = shaped * motion * texture
            samples[index] = min(0.98, max(0.01, sample))
        }

        return samples
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

    private func gatedLevel(for normalized: CGFloat) -> CGFloat {
        let noiseFloor: CGFloat = 0.26
        return max(0, (normalized - noiseFloor) / (1 - noiseFloor))
    }

    private static let electricSpectrumColors: [Color] = [
        Color(hex: 0x18C8FF),
        Color(hex: 0x3F7CFF),
        Color(hex: 0x855CFF),
        Color(hex: 0xFF3FD1),
        Color(hex: 0xFF5B77),
        Color(hex: 0xFFB52E),
        Color(hex: 0xD7F63A),
        Color(hex: 0x58F08A),
    ]

}
