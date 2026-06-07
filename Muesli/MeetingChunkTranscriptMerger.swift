import Foundation

struct MeetingChunkTranscription: Sendable, Equatable {
    let chunk: MeetingAudioChunk
    let result: DetailedTranscriptionResult
}

enum MeetingChunkTranscriptMerger {
    static func merge(_ chunks: [MeetingChunkTranscription]) -> DetailedTranscriptionResult {
        let sorted = chunks.sorted {
            if $0.chunk.startTime == $1.chunk.startTime {
                return $0.chunk.index < $1.chunk.index
            }
            return $0.chunk.startTime < $1.chunk.startTime
        }

        var textParts: [String] = []
        var tokens: [TimedTranscriptToken] = []
        var duration: TimeInterval = 0

        for chunk in sorted {
            let text = chunk.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                textParts.append(text)
            }

            duration = max(duration, chunk.chunk.startTime + max(chunk.chunk.duration, chunk.result.duration))
            tokens.append(contentsOf: chunk.result.tokens.map {
                TimedTranscriptToken(
                    token: $0.token,
                    startTime: $0.startTime + chunk.chunk.startTime,
                    endTime: $0.endTime + chunk.chunk.startTime,
                    confidence: $0.confidence
                )
            })
        }

        return DetailedTranscriptionResult(
            text: textParts.joined(separator: " "),
            duration: duration,
            tokens: tokens
        )
    }
}
