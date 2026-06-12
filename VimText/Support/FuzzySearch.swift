import Foundation

/// Greedy subsequence matcher in the fzf / Sublime Text ⌘P family: every query
/// character must appear in the candidate in order (gaps allowed), and the
/// score rewards matches that start words, hug each other, and begin early —
/// so "sgs" finds "Shreya Gifting Strategy" and ranks it above incidental
/// scattered matches. Kept AppKit-free so the smoke tests can exercise it.
public enum FuzzySearch {
    public struct Match {
        public let score: Int
        /// Character offsets (into the candidate) of the matched characters,
        /// so callers can highlight exactly what matched.
        public let matchedOffsets: [Int]
    }

    /// Tuned so that: substring ≫ tight subsequence ≫ scattered subsequence,
    /// and word-prefix matches beat mid-word ones.
    private static let firstCharBonus = 15
    private static let boundaryBonus = 12
    private static let consecutiveBonus = 8
    private static let maxGapPenalty = 10

    public static func match(_ query: String, in candidate: String) -> Match? {
        if query.isEmpty { return Match(score: 0, matchedOffsets: []) }
        // Per-character folded comparison (not a whole-string lowercase) so
        // offsets always line up with the original candidate's characters.
        // searchFolded makes straight and typographic quotes/dashes match.
        let queryChars = query.map { String($0).searchFolded.lowercased() }
        let candidateChars = Array(candidate)
        guard queryChars.count <= candidateChars.count else { return nil }
        let candidateLower = candidateChars.map { String($0).searchFolded.lowercased() }

        var score = 0
        var matchedOffsets: [Int] = []
        var queryIndex = 0
        var previousMatch = -2
        for i in 0..<candidateChars.count where queryIndex < queryChars.count {
            guard candidateLower[i] == queryChars[queryIndex] else { continue }
            var charScore = 1
            if i == 0 {
                charScore += firstCharBonus
            } else if isWordBoundary(previous: candidateChars[i - 1], current: candidateChars[i]) {
                charScore += boundaryBonus
            }
            if previousMatch == i - 1 {
                charScore += consecutiveBonus
            } else if !matchedOffsets.isEmpty {
                charScore -= min(i - previousMatch - 1, maxGapPenalty)
            }
            score += charScore
            matchedOffsets.append(i)
            previousMatch = i
            queryIndex += 1
        }
        guard queryIndex == queryChars.count else { return nil }
        return Match(score: score, matchedOffsets: matchedOffsets)
    }

    private static func isWordBoundary(previous: Character, current: Character) -> Bool {
        if previous.isWhitespace || previous.isPunctuation || previous == "/" { return true }
        return previous.isLowercase && current.isUppercase
    }
}
