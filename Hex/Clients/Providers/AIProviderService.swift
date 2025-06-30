import Foundation

/// Common interface every concrete AI provider (local or remote) must implement.
/// These methods are a distilled subset of the functionality the application needs.
///
/// All calls are `async` and *must* be Sendable / thread-safe because they are used
/// from Swift Concurrency contexts.
protocol AIProviderService: Sendable {
    /// Which provider this implementation represents.
    var kind: AIProviderType { get }

    // MARK: – Connectivity
    /// Returns true if the provider is reachable and usable.
    /// `apiKey` is optional; local providers ignore it.
    func isAvailable(apiKey: String?) async -> Bool

    /// Simple connectivity test (often just calls `isAvailable`).
    func testConnection(apiKey: String?) async -> Bool

    // MARK: – Model catalogue
    /// Fetch a list of models this provider can use.
    func fetchModels(apiKey: String?) async throws -> [RemoteAIModel]

    // MARK: – Text enhancement
    /// Enhance / improve the given text.
    func enhance(
        _ text: String,
        model: String,
        options: EnhancementOptions,
        apiKey: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> String

    // MARK: – Vision (optional)
    /// Analyse an image and return a textual summary.
    func analyzeImage(
        data: Data,
        model: String,
        prompt: String,
        systemPrompt: String,
        apiKey: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> String
}

extension AIProviderService {
    // Default implementation for providers that do not support vision.
    func analyzeImage(
        data _: Data,
        model _: String,
        prompt _: String,
        systemPrompt _: String,
        apiKey _: String?,
        progress _: @escaping (Double) -> Void
    ) async throws -> String {
        throw NSError(
            domain: "AIProviderService",
            code: -999,
            userInfo: [NSLocalizedDescriptionKey: "\(kind.displayName) does not support image analysis"]
        )
    }
} 