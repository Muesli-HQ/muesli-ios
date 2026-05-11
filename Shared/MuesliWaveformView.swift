import SwiftUI

struct MuesliWaveformView: View {
    var isActive: Bool
    var color: Color
    var level: Double? = nil
    var barCount: Int = 9
    var spacing: CGFloat = 2

    @State private var pulse = false

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
            let normalizedLevel = CGFloat(min(max(level ?? 0.48, 0), 1))

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
        }
        .onAppear(perform: updatePulse)
        .onChange(of: isActive) { _, _ in updatePulse() }
    }

    private func barHeight(for index: Int, base: CGFloat, maxHeight: CGFloat, level: CGFloat) -> CGFloat {
        guard isActive else {
            return max(maxHeight * base, 3)
        }

        let phaseOffsets: [CGFloat] = [0.82, 1.0, 1.18, 1.08, 0.9, 1.12, 1.2, 1.0, 0.84, 1.04, 0.92, 1.12, 0.86]
        let phase = phaseOffsets[index % phaseOffsets.count]
        let pulseAmount: CGFloat = pulse ? 0.22 : -0.10
        let dynamicLevel = min(max((level * 0.70) + 0.24 + pulseAmount, 0.18), 1.0)
        return max(maxHeight * base * dynamicLevel * phase, 3)
    }

    private func updatePulse() {
        if isActive {
            withAnimation(.easeInOut(duration: 0.60).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            pulse = false
        }
    }
}
