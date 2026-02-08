import Foundation

// MARK: - Word Diff Result

/// Represents a single word/phrase correction
struct WordCorrection: Codable, Equatable, Hashable {
    let original: String
    let corrected: String

    var isValid: Bool {
        !original.isEmpty && !corrected.isEmpty && original != corrected
    }
}

// MARK: - Diff Tracker

/// Tracks differences between original transcription and user-edited text
/// Uses character-level diff for Chinese text (no word boundaries)
final class DiffTracker {

    // MARK: - Public Methods

    /// Find all corrections between original and edited text
    func findCorrections(original: String, edited: String) -> [WordCorrection] {
        guard original != edited else { return [] }

        // For Chinese text, we need character-level or phrase-level comparison
        // since there are no clear word boundaries

        var corrections: [WordCorrection] = []

        // Use Longest Common Subsequence (LCS) based diff
        let diffs = computeDiff(original: original, edited: edited)

        // Group consecutive changes into corrections
        corrections = groupDiffsIntoCorrections(diffs, original: original, edited: edited)

        return corrections.filter { $0.isValid }
    }

    // MARK: - LCS-based Diff Algorithm

    private enum DiffOp {
        case equal(Character)
        case delete(Character)
        case insert(Character)
    }

    private func computeDiff(original: String, edited: String) -> [DiffOp] {
        let origChars = Array(original)
        let editChars = Array(edited)

        let m = origChars.count
        let n = editChars.count

        // Build LCS table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if origChars[i - 1] == editChars[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find diff operations
        var ops: [DiffOp] = []
        var i = m
        var j = n

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && origChars[i - 1] == editChars[j - 1] {
                ops.append(.equal(origChars[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                ops.append(.insert(editChars[j - 1]))
                j -= 1
            } else {
                ops.append(.delete(origChars[i - 1]))
                i -= 1
            }
        }

        return ops.reversed()
    }

    private func groupDiffsIntoCorrections(_ ops: [DiffOp], original: String, edited: String) -> [WordCorrection] {
        var corrections: [WordCorrection] = []
        var deletedChars: [Character] = []
        var insertedChars: [Character] = []

        for op in ops {
            switch op {
            case .equal:
                // When we hit equal, flush any accumulated changes
                if !deletedChars.isEmpty || !insertedChars.isEmpty {
                    let correction = WordCorrection(
                        original: String(deletedChars),
                        corrected: String(insertedChars)
                    )
                    if correction.isValid {
                        corrections.append(correction)
                    }
                    deletedChars = []
                    insertedChars = []
                }

            case .delete(let char):
                deletedChars.append(char)

            case .insert(let char):
                insertedChars.append(char)
            }
        }

        // Flush remaining changes
        if !deletedChars.isEmpty || !insertedChars.isEmpty {
            let correction = WordCorrection(
                original: String(deletedChars),
                corrected: String(insertedChars)
            )
            if correction.isValid {
                corrections.append(correction)
            }
        }

        return corrections
    }

    // MARK: - Phrase Extraction

    /// Extract meaningful Chinese phrases from corrections
    /// This helps identify multi-character corrections like "大度" -> "大肚"
    func extractPhrases(from corrections: [WordCorrection], context: (original: String, edited: String)) -> [WordCorrection] {
        // For short corrections (1-4 chars), try to expand to full phrase
        var expandedCorrections: [WordCorrection] = []

        for correction in corrections {
            // If the correction is very short, try to find the full phrase context
            if correction.original.count <= 2 && correction.corrected.count <= 2 {
                if let expanded = expandToPhrase(correction, in: context) {
                    expandedCorrections.append(expanded)
                } else {
                    expandedCorrections.append(correction)
                }
            } else {
                expandedCorrections.append(correction)
            }
        }

        return expandedCorrections
    }

    private func expandToPhrase(_ correction: WordCorrection, in context: (original: String, edited: String)) -> WordCorrection? {
        // Find the correction position in original text
        guard let origRange = context.original.range(of: correction.original) else {
            return nil
        }

        // Try to expand by looking at surrounding characters
        // For Chinese, a "phrase" is typically 2-4 characters

        let origStartIndex = context.original.startIndex
        let origEndIndex = context.original.endIndex

        // Expand backwards (up to 2 chars)
        var expandStart = origRange.lowerBound
        for _ in 0..<2 {
            if expandStart > origStartIndex {
                expandStart = context.original.index(before: expandStart)
            }
        }

        // Expand forwards (up to 2 chars)
        var expandEnd = origRange.upperBound
        for _ in 0..<2 {
            if expandEnd < origEndIndex {
                expandEnd = context.original.index(after: expandEnd)
            }
        }

        let expandedOriginal = String(context.original[expandStart..<expandEnd])

        // Find corresponding expanded text in edited version
        // This is a heuristic - find where the corrected text appears and expand similarly
        if let editRange = context.edited.range(of: correction.corrected) {
            let editStartIndex = context.edited.startIndex
            let editEndIndex = context.edited.endIndex

            var editExpandStart = editRange.lowerBound
            for _ in 0..<2 {
                if editExpandStart > editStartIndex {
                    editExpandStart = context.edited.index(before: editExpandStart)
                }
            }

            var editExpandEnd = editRange.upperBound
            for _ in 0..<2 {
                if editExpandEnd < editEndIndex {
                    editExpandEnd = context.edited.index(after: editExpandEnd)
                }
            }

            let expandedEdited = String(context.edited[editExpandStart..<editExpandEnd])

            // Only return if expanded versions are different and meaningful
            if expandedOriginal != expandedEdited &&
               expandedOriginal.count >= 2 &&
               expandedEdited.count >= 2 {
                return WordCorrection(original: expandedOriginal, corrected: expandedEdited)
            }
        }

        return nil
    }
}

// MARK: - Convenience Extension

extension DiffTracker {

    /// Analyze a correction and return both the direct correction and any expanded phrases
    func analyzeCorrection(original: String, edited: String) -> (corrections: [WordCorrection], phrases: [WordCorrection]) {
        let corrections = findCorrections(original: original, edited: edited)
        let phrases = extractPhrases(from: corrections, context: (original, edited))

        // Deduplicate
        let uniquePhrases = phrases.filter { phrase in
            !corrections.contains(phrase)
        }

        return (corrections, uniquePhrases)
    }

    /// Analyze AI enhancement corrections — only high-confidence word corrections (2~10 chars).
    /// Filters out pure punctuation/whitespace changes that AI commonly makes.
    func analyzeAICorrection(original: String, enhanced: String) -> [WordCorrection] {
        let (corrections, phrases) = analyzeCorrection(original: original, edited: enhanced)
        let all = corrections + phrases

        return all.filter { correction in
            // Skip pure punctuation/whitespace changes
            let origStripped = correction.original.filter { !$0.isPunctuation && !$0.isWhitespace }
            let corrStripped = correction.corrected.filter { !$0.isPunctuation && !$0.isWhitespace }
            guard origStripped != corrStripped else { return false }

            // Only learn corrections in the 2~10 character range (high confidence)
            let origLen = correction.original.count
            let corrLen = correction.corrected.count
            guard origLen >= 2 && origLen <= 10 && corrLen >= 2 && corrLen <= 10 else { return false }

            return true
        }
    }
}
