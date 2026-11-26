import Foundation

/// Splits long audio into pieces short enough for a model's single-pass path,
/// cutting at the quietest moment near each limit so words aren't cut in half.
///
/// Parakeet-style models transcribe up to 15 s in one pass. Longer audio goes
/// through FluidAudio's chunked decoder, which needs far more memory than the
/// keyboard has, and iOS then ends the keyboard with nothing pasted.
enum QuietSplit {
    static let sampleRate = 16_000
    /// Below FluidAudio's 15 s single-pass limit (240 000 samples).
    static let maxPieceSamples = 14 * sampleRate
    /// How far back from the limit to look for a pause.
    static let searchSamples = 4 * sampleRate
    /// Loudness is compared over 100 ms windows.
    static let windowSamples = sampleRate / 10

    static func ranges(
        for samples: [Float],
        maxPieceSamples: Int = maxPieceSamples,
        searchSamples: Int = searchSamples,
        windowSamples: Int = windowSamples
    ) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxPieceSamples {
            let limit = start + maxPieceSamples
            let searchStart = max(start + windowSamples, limit - searchSamples)
            var cut = limit
            var quietest = Float.greatestFiniteMagnitude
            var windowStart = searchStart
            while windowStart + windowSamples <= limit {
                var energy: Float = 0
                for index in windowStart..<(windowStart + windowSamples) {
                    energy += samples[index] * samples[index]
                }
                if energy < quietest {
                    quietest = energy
                    cut = windowStart + windowSamples / 2
                }
                windowStart += windowSamples / 2
            }
            pieces.append(start..<cut)
            start = cut
        }
        if start < samples.count { pieces.append(start..<samples.count) }
        return pieces
    }
}
