import Foundation

/// Cleans AI responses by stripping internal "thinking" tags often included by models.
/// - Parameter text: The raw response string from the model.
/// - Returns: A cleaned string with thinking annotations removed and superfluous blank lines collapsed.
@inline(__always)
func cleanThinkingTags(from text: String) -> String {
    var cleaned = text
    let patterns = [
        "<think>[\\s\\S]*?</think>",
        "<thinking>[\\s\\S]*?</thinking>",
        "\\[thinking\\][\\s\\S]*?\\[/thinking\\]",
        "\\*thinking\\*[\\s\\S]*?\\*/thinking\\*"
    ]
    for pattern in patterns {
        cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    cleaned = cleaned.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n", with: "\n\n", options: .regularExpression)
    return cleaned
} 