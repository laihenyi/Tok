//
//  EnhancementPromptTemplates.swift
//  Hex
//
//  Dynamic prompt templates for AI Enhancement, adapting to
//  output style, language, and structured output needs.
//

import Foundation

/// Output style inferred from the foreground application.
enum OutputStyle: String, Codable, CaseIterable, Equatable {
    case formal     // Mail, Pages, Word
    case casual     // Messages, Slack, Discord, LINE
    case technical  // Xcode, VS Code, Terminal
    case notes      // Notes, Notion, Obsidian
    case general    // Default / unknown
}

enum EnhancementPromptTemplates {

    // MARK: - Core System Prompt

    static let coreSystemPrompt = """
    You are a professional transcription editor. You receive raw speech-to-text output \
    and produce clean, natural written text.

    RULES:
    1. Fix grammar, punctuation, and capitalization errors from transcription.
    2. Remove any remaining filler words (嗯, 啊, um, uh, like, you know) that were not caught earlier.
    3. When the speaker corrects themselves mid-sentence, keep ONLY the final corrected version.
    4. Preserve ALL meaning and information exactly.
    5. Maintain the same language as the input — NEVER translate.
    6. For mixed Chinese-English text: keep the code-switching natural, do not unify into one language.
    7. Technical terms, proper nouns, and names must be preserved exactly as spoken.
    8. DO NOT add information not present in the original.
    9. DO NOT remove meaningful content.
    10. Respond ONLY with the cleaned text — no explanation, no preamble.
    """

    // MARK: - Language-Specific Rules

    static let chineseRules = """
    Additional rules for Chinese content:
    - Output in Traditional Chinese characters (繁體中文).
    - Use correct Chinese punctuation: 。、，；：「」（）.
    - Remove redundant 的、了、啊、呢 that are common in spoken Chinese but unnecessary in written form.
    - Preserve English technical terms within Chinese text (do not translate them).
    """

    static let mixedLanguageRules = """
    For mixed Chinese-English text:
    - Keep natural code-switching patterns intact.
    - Chinese punctuation for Chinese clauses: 。，、；：「」
    - English punctuation for English clauses: . , ; : " "
    - Technical English terms within Chinese sentences should remain in English.
    - Do NOT translate any part to unify language.
    """

    // MARK: - Structured Output

    static let structuredOutputRules = """
    If the content naturally suggests a structured format:
    - Lists should use bullet points (- item).
    - Steps should use numbered lists (1. 2. 3.).
    - Multiple distinct points should be separated into clear paragraphs.
    Only apply formatting if the content clearly calls for it. Short messages should remain as plain text.
    """

    // MARK: - Style Guidance

    static func styleGuidance(for style: OutputStyle) -> String? {
        switch style {
        case .formal:
            return "Tone: formal and professional. Suitable for business correspondence."
        case .casual:
            return "Tone: casual and friendly. Keep it concise and natural."
        case .technical:
            return "Preserve all technical terminology exactly. Code snippets and identifiers must remain unchanged."
        case .notes:
            return structuredOutputRules
        case .general:
            return nil
        }
    }

    // MARK: - Dynamic Prompt Builder

    /// Build a complete enhancement prompt from the given parameters.
    ///
    /// - Parameters:
    ///   - style: The inferred output style from the foreground app.
    ///   - language: The primary language of the transcription (e.g. "zh", "en", "mixed", or nil).
    ///   - includeStructuredOutput: Whether to include structured-output formatting rules.
    static func buildPrompt(
        style: OutputStyle = .general,
        language: String? = nil,
        includeStructuredOutput: Bool = false
    ) -> String {
        var parts: [String] = [coreSystemPrompt]

        // Language rules
        let lang = language ?? ""
        if lang.hasPrefix("zh") || lang == "mixed" {
            parts.append(chineseRules)
        }
        if lang == "mixed" {
            parts.append(mixedLanguageRules)
        }

        // Style guidance
        if let guidance = styleGuidance(for: style) {
            parts.append(guidance)
        }

        // Structured output (only add if not already added via .notes style)
        if includeStructuredOutput && style != .notes {
            parts.append(structuredOutputRules)
        }

        return parts.joined(separator: "\n\n")
    }
}
