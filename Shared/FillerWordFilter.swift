import Foundation

struct FillerWordFilter {
    private static let fillers: Set<String> = [
        "uh", "um", "uh,", "um,", "uhh", "umm",
        "er", "err", "ah", "ahh",
        "hmm", "hm", "mm", "mmm",
        "like,",
        "you know,"
    ]

    private static let fillerPhrases: [(pattern: String, replacement: String)] = [
        ("you know,", ""),
        ("i mean,", ""),
        ("sort of", ""),
        ("kind of", "")
    ]

    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        for phrase in fillerPhrases {
            while let range = result.range(of: phrase.pattern, options: [.caseInsensitive]) {
                result.replaceSubrange(range, with: phrase.replacement)
            }
        }

        let words = result.components(separatedBy: " ")
        result = words
            .filter { !fillers.contains($0.lowercased()) }
            .joined(separator: " ")

        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        result = result.trimmingCharacters(in: .whitespaces)

        if let first = result.first, first.isLowercase {
            result = result.prefix(1).uppercased() + result.dropFirst()
        }

        return result
    }
}
