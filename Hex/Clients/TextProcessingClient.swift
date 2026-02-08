//
//  TextProcessingClient.swift
//  Hex
//
//  Smart text processing for cleaning up speech-to-text output.
//  Handles filler word removal and self-correction resolution
//  without requiring an LLM.
//

import Dependencies
import DependenciesMacros
import Foundation

/// Options controlling which text processing steps to apply.
struct TextProcessingOptions: Equatable {
    var removeFillers: Bool = true
    var resolveSelfCorrections: Bool = true
    /// Hint for primary language; nil = auto-detect from content.
    var detectedLanguage: String? = nil
}

/// A client that performs local text cleanup on raw transcription output.
@DependencyClient
struct TextProcessingClient {
    /// Run the full processing pipeline (filler removal + self-correction).
    var processText: @Sendable (String, TextProcessingOptions) -> String = { text, _ in text }
}

// MARK: - Live Implementation

extension TextProcessingClient: DependencyKey {
    static var liveValue: Self {
        let processor = TextProcessor()
        return Self(
            processText: { processor.process($0, options: $1) }
        )
    }
}

extension DependencyValues {
    var textProcessing: TextProcessingClient {
        get { self[TextProcessingClient.self] }
        set { self[TextProcessingClient.self] = newValue }
    }
}

// MARK: - TextProcessor

/// Pure-function text processor. Thread-safe (no mutable state).
struct TextProcessor: Sendable {

    func process(_ text: String, options: TextProcessingOptions) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        // Step 1: Resolve self-corrections first (before filler removal)
        // so that "嗯 那個 我去了台北 不對 我去了台南" → "我去了台南"
        if options.resolveSelfCorrections {
            result = resolveSelfCorrections(result)
        }

        // Step 2: Remove filler words
        if options.removeFillers {
            let lang = options.detectedLanguage ?? detectLanguage(result)
            result = removeFillerWords(result, language: lang)
        }

        // Clean up residual whitespace
        result = collapseWhitespace(result)

        return result
    }

    // MARK: - Self-Correction Resolution

    /// Detects correction signal phrases and keeps only the final intended content.
    ///
    /// Examples:
    /// - "我去了台北 不對 我去了台南" → "我去了台南"
    /// - "I went to Tokyo, sorry I meant Osaka" → "I went to Osaka"
    /// - "五百塊 不是 三百塊" → "三百塊"
    func resolveSelfCorrections(_ text: String) -> String {
        var result = text

        // Chinese correction signals – each pattern captures:
        //   (preceding clause)(signal word)(corrected clause)
        // We keep everything before the preceding clause + the corrected clause.
        let zhSignals = [
            "不對[，、,\\s]*",
            "不是[，、,\\s]*",
            "我是說[，、,\\s]*",
            "我的意思是[，、,\\s]*",
            "應該是[，、,\\s]*",
            "更正[，、,\\s]*",
        ]

        for signal in zhSignals {
            // Match: a Chinese clause (non-greedy) + signal + rest
            // The "clause" is bounded by sentence-level punctuation or start of string
            let pattern = "(?<=[。；！？\\n]|^)([^。；！？\\n]*?)" + signal + "([^。；！？\\n]+)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$2")
            }
        }

        // English correction signals
        let enSignals = [
            "[,，\\s]+(?:sorry\\s+)?I\\s+mean[t]?[,，\\s]+",
            "[,，\\s]+(?:no|nah)[,，\\s]+(?:I\\s+mean[t]?[,，\\s]+)?",
            "[,，\\s]+(?:sorry|wait)[,，\\s]+(?:I\\s+mean[t]?[,，\\s]+)?",
            "[,，\\s]+(?:actually|correction)[,，\\s]+",
        ]

        for signal in enSignals {
            // Match: a clause before the signal + the signal + corrected clause
            let pattern = "([^.!?;\\n]*?)" + signal + "([^.!?;\\n]+)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$2")
            }
        }

        return result
    }

    // MARK: - Filler Word Removal

    /// Removes spoken filler words that carry no semantic meaning.
    /// Only removes fillers that appear as standalone tokens or at clause boundaries,
    /// preserving them when they have actual meaning in context.
    func removeFillerWords(_ text: String, language: String) -> String {
        var result = text

        if language.hasPrefix("zh") || language == "mixed" {
            result = removeChineseFillers(result)
        }

        if !language.hasPrefix("zh") || language == "mixed" {
            result = removeEnglishFillers(result)
        }

        return result
    }

    /// Removes Chinese filler words that appear as standalone items at clause boundaries.
    private func removeChineseFillers(_ text: String) -> String {
        var result = text

        // Fillers that are safe to remove when standalone (at sentence start, or
        // between punctuation). We use lookaround to ensure we only strip them
        // as standalone or sentence-leading tokens.
        //
        // "就是" is tricky: "就是這個" should keep it, but "就是，" or "，就是，" is filler.
        // Strategy: remove when followed by punctuation/whitespace/end, or preceded by same.
        let standaloneFillers = [
            "嗯+",           // 嗯, 嗯嗯
            "啊[，、。\\s]",  // 啊 as filler (followed by punctuation/space)
            "呃+",           // 呃, 呃呃
            "那個[，、\\s]+", // 那個 as filler (followed by punctuation/space)
            "就是說[，、\\s]+",
            "怎麼說[，、\\s]+",
            "基本上[，、\\s]+",
            "然後[，、\\s]+(?=然後|嗯|啊|就是)", // "然後" only when chained with more fillers
        ]

        for filler in standaloneFillers {
            let pattern = "(?:^|(?<=[，、。；！？\\s]))" + filler
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }

        return result
    }

    /// Removes English filler words when they are standalone clause-level tokens.
    private func removeEnglishFillers(_ text: String) -> String {
        var result = text

        // Word-boundary-safe patterns for English fillers.
        // These are only removed when they appear at clause boundaries (preceded/followed by
        // punctuation or whitespace), never mid-phrase.
        let fillerPatterns = [
            "\\bum+\\b[,;\\s]*",
            "\\buh+\\b[,;\\s]*",
            "\\byou know[,;\\s]+",
            "\\bbasically[,;\\s]+",
            "\\bI mean[,;\\s]+",
            "\\bsort of[,;\\s]+",
            "\\bkind of[,;\\s]+",
            "(?:^|(?<=[.!?,;\\s]))like[,;\\s]+(?=[a-z])", // "like" only at clause start
        ]

        for filler in fillerPatterns {
            if let regex = try? NSRegularExpression(pattern: filler, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }

        return result
    }

    // MARK: - Language Detection

    /// Simple heuristic: ratio of CJK characters to total characters.
    func detectLanguage(_ text: String) -> String {
        guard !text.isEmpty else { return "en" }

        let total = text.count
        let chineseCount = text.filter { $0.isChineseCharacter }.count
        let ratio = Double(chineseCount) / Double(total)

        if ratio > 0.3 { return "zh" }
        if ratio > 0.05 { return "mixed" }
        return "en"
    }

    // MARK: - Helpers

    /// Collapse multiple spaces/newlines into a single space, trim edges.
    private func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Character Extension

private extension Character {
    var isChineseCharacter: Bool {
        let scalar = unicodeScalars.first?.value ?? 0
        return (0x4E00...0x9FFF).contains(scalar) ||   // CJK Unified Ideographs
               (0x3400...0x4DBF).contains(scalar) ||   // CJK Extension A
               (0x20000...0x2A6DF).contains(scalar)    // CJK Extension B
    }
}
