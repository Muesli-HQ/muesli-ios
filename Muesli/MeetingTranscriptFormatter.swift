import Foundation

enum MeetingTranscriptFormatter {
    static func speakerTranscript(
        transcription: DetailedTranscriptionResult,
        diarizationSegments: [SpeakerDiarizationSegment],
        meetingStart: Date
    ) -> String {
        let speechSegments = speechSegments(from: transcription)
        guard !speechSegments.isEmpty else {
            return transcription.text
        }
        guard !diarizationSegments.isEmpty else {
            return format([
                SpeakerTextSegment(
                    speaker: "Speaker 1",
                    startTime: speechSegments.first?.startTime ?? 0,
                    endTime: speechSegments.last?.endTime ?? transcription.duration,
                    text: transcription.text
                )
            ], meetingStart: meetingStart)
        }

        let labelMap = speakerLabelMap(for: diarizationSegments)
        let tagged = speechSegments.map { segment in
            SpeakerTextSegment(
                speaker: speaker(for: segment, diarizationSegments: diarizationSegments, labelMap: labelMap),
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text
            )
        }
        return format(consolidate(tagged), meetingStart: meetingStart)
    }

    private static func speechSegments(from transcription: DetailedTranscriptionResult) -> [TimedTextSegment] {
        let words = wordTimings(from: transcription.tokens)
        guard !words.isEmpty else {
            let trimmed = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [
                TimedTextSegment(
                    startTime: 0,
                    endTime: max(transcription.duration, 0.1),
                    text: trimmed
                )
            ]
        }

        var segments: [TimedTextSegment] = []
        var currentWords: [TimedTextSegment] = []

        for word in words {
            if let last = currentWords.last {
                let gap = max(0, word.startTime - last.endTime)
                let duration = max(0, last.endTime - currentWords[0].startTime)
                let shouldBreak = gap > 1.2 || duration > 12 || last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!")
                if shouldBreak {
                    segments.append(join(currentWords))
                    currentWords = []
                }
            }
            currentWords.append(word)
        }
        if !currentWords.isEmpty {
            segments.append(join(currentWords))
        }
        return segments
    }

    private static func wordTimings(from tokens: [TimedTranscriptToken]) -> [TimedTextSegment] {
        var words: [TimedTextSegment] = []
        var current = ""
        var start: TimeInterval?
        var end: TimeInterval = 0

        for token in tokens {
            let normalized = normalizedToken(token.token)
            guard !normalized.isEmpty else { continue }
            let startsNewWord = normalized.first?.isWhitespace == true
            let piece = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }

            if startsNewWord, !current.isEmpty, let wordStart = start {
                words.append(TimedTextSegment(startTime: wordStart, endTime: end, text: current))
                current = ""
                start = token.startTime
            }

            if start == nil {
                start = token.startTime
            }
            current += piece
            end = max(end, token.endTime)
        }

        if !current.isEmpty, let start {
            words.append(TimedTextSegment(startTime: start, endTime: end, text: current))
        }
        return words
    }

    private static func normalizedToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "▁", with: " ")
            .replacingOccurrences(of: "Ġ", with: " ")
            .replacingOccurrences(of: "<unk>", with: "")
    }

    private static func join(_ words: [TimedTextSegment]) -> TimedTextSegment {
        TimedTextSegment(
            startTime: words.first?.startTime ?? 0,
            endTime: words.last?.endTime ?? 0,
            text: words.map(\.text).joined(separator: " ")
        )
    }

    private static func speakerLabelMap(for diarizationSegments: [SpeakerDiarizationSegment]) -> [String: String] {
        var labels: [String: String] = [:]
        var nextIndex = 1
        for segment in diarizationSegments.sorted(by: { $0.startTime < $1.startTime }) {
            if labels[segment.speakerID] == nil {
                labels[segment.speakerID] = "Speaker \(nextIndex)"
                nextIndex += 1
            }
        }
        return labels
    }

    private static func speaker(
        for textSegment: TimedTextSegment,
        diarizationSegments: [SpeakerDiarizationSegment],
        labelMap: [String: String]
    ) -> String {
        var bestOverlap: TimeInterval = 0
        var bestSpeakerID: String?

        for diarizationSegment in diarizationSegments {
            let overlap = max(0, min(textSegment.endTime, diarizationSegment.endTime) - max(textSegment.startTime, diarizationSegment.startTime))
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerID = diarizationSegment.speakerID
            }
        }

        if let bestSpeakerID, bestOverlap > 0 {
            return labelMap[bestSpeakerID] ?? "Speaker"
        }

        let midpoint = (textSegment.startTime + textSegment.endTime) / 2
        let nearest = diarizationSegments.min { lhs, rhs in
            distance(from: midpoint, to: lhs) < distance(from: midpoint, to: rhs)
        }
        if let nearest, distance(from: midpoint, to: nearest) <= 2 {
            return labelMap[nearest.speakerID] ?? "Speaker"
        }
        return "Speaker"
    }

    private static func distance(from time: TimeInterval, to segment: SpeakerDiarizationSegment) -> TimeInterval {
        if time < segment.startTime {
            return segment.startTime - time
        }
        if time > segment.endTime {
            return time - segment.endTime
        }
        return 0
    }

    private static func consolidate(_ segments: [SpeakerTextSegment]) -> [SpeakerTextSegment] {
        guard var current = segments.first else { return [] }
        var result: [SpeakerTextSegment] = []

        for segment in segments.dropFirst() {
            let gap = max(0, segment.startTime - current.endTime)
            if segment.speaker == current.speaker && gap <= 2 {
                current = SpeakerTextSegment(
                    speaker: current.speaker,
                    startTime: current.startTime,
                    endTime: max(current.endTime, segment.endTime),
                    text: append(current.text, segment.text)
                )
            } else {
                result.append(current)
                current = segment
            }
        }
        result.append(current)
        return result
    }

    private static func append(_ lhs: String, _ rhs: String) -> String {
        let trimmedLeft = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRight = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLeft.isEmpty else { return trimmedRight }
        guard !trimmedRight.isEmpty else { return trimmedLeft }
        return "\(trimmedLeft) \(trimmedRight)"
    }

    private static func format(_ segments: [SpeakerTextSegment], meetingStart: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"

        return segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { segment in
                let timestamp = meetingStart.addingTimeInterval(segment.startTime)
                return "[\(formatter.string(from: timestamp))] \(segment.speaker): \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            .joined(separator: "\n")
    }
}

private struct TimedTextSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

private struct SpeakerTextSegment {
    let speaker: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}
