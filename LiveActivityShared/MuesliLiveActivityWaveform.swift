import Foundation

/// Small amplitude envelopes, not raw microphone audio, cross into ActivityKit.
/// Keep the system update rate independent of the app's 20 Hz microphone meter.
struct MuesliLiveActivityWaveformSampler {
    static let barCount = 5
    static let publishInterval: TimeInterval = 0.5
    private static let sampleInterval: TimeInterval = 0.1

    private var samples = Array(repeating: 0.0, count: barCount)
    private var peak = 0.0
    private var sampleTime: TimeInterval?
    private var publishTime: TimeInterval?
    private var lastPublished: [Double]?

    mutating func sample(_ level: Double, at time: TimeInterval) -> [Double]? {
        let normalized = level.isFinite ? min(max(level, 0), 1) : 0
        // Match the noise gate used by Muesli's in-app waveform.
        let gated = max(0, (normalized - 0.26) / 0.74)
        peak = max(peak, (gated * 20).rounded() / 20)
        guard let sampleTime, let publishTime else {
            self.sampleTime = time
            self.publishTime = time
            return nil
        }
        if time - sampleTime >= Self.sampleInterval - 0.000001 {
            if time - sampleTime > Self.publishInterval {
                samples = Array(repeating: 0, count: Self.barCount)
            }
            samples.removeFirst()
            samples.append(peak)
            peak = 0
            self.sampleTime = time
        }
        guard time - publishTime >= Self.publishInterval - 0.000001 else { return nil }
        self.publishTime = time
        guard samples != lastPublished else { return nil }
        lastPublished = samples
        return samples
    }
}

enum MuesliLiveActivityWaveform {
    static func bars(_ samples: [Double]?) -> [Double] {
        let values = Array((samples ?? []).suffix(MuesliLiveActivityWaveformSampler.barCount))
            .map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        return Array(repeating: 0, count: MuesliLiveActivityWaveformSampler.barCount - values.count) + values
    }
}
