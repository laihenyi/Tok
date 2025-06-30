//
//  AIEnhancementClient.swift
//  Hex
//
//  Created by Claude AI on 4/22/25.
//

import Dependencies
import DependenciesMacros
import Foundation

// Note: Future enhancement could use OllamaKit directly:
// import OllamaKit

/// A client that enhances transcribed text using local LLMs.
/// Supports both Ollama and other local options (future expansion).
@DependencyClient
struct AIEnhancementClient {
    /// Enhances the given text using the specified model.
    var enhance: @Sendable (String, String, EnhancementOptions, AIProviderType, String?, @escaping (Progress) -> Void) async throws -> String = { text, _, _, _, _, _ in text }
    
    /// Checks if LM Studio REST server is running and reachable
    var isLMStudioAvailable: @Sendable () async -> Bool = { false }
    
    /// Gets a list of available models from Ollama
    var getAvailableModels: @Sendable () async throws -> [String] = { [] }
    
    /// Gets a list of available models from a local provider (Ollama or LM Studio)
    var getLocalModels: @Sendable (AIProviderType) async throws -> [String] = { _ in [] }
    
    /// Gets a list of available models from a remote provider
    var getRemoteModels: @Sendable (AIProviderType, String) async throws -> [RemoteAIModel] = { _, _ in [] }
    
    /// Tests connection to a remote AI provider
    var testRemoteConnection: @Sendable (AIProviderType, String) async -> Bool = { _, _ in false }

    /// Checks availability/reachability of any provider (local or remote). For remote providers pass API key.
    var checkProviderAvailability: @Sendable (AIProviderType, String) async -> Bool = { _, _ in false }

    /// Analyzes a screenshot (PNG/JPEG data) with a VLM model and returns a short textual summary.
    /// - Parameters:
    ///   - imageData: The raw PNG/JPEG data to analyse.
    ///   - model: The name of the VLM model to use (e.g. "llava:latest").
    ///   - prompt: A natural-language instruction describing what the model should return.
    ///   - provider: The provider to route the request to (local Ollama or a remote service).
    ///   - apiKey: Optional API-key for remote providers.
    ///   - systemPrompt: The system prompt that defines how the AI should analyze images.
    ///   - progressCallback: Reports fractional completion (0–1).
    /// - Returns: The model's textual response, trimmed of whitespace.
    var analyzeImage: @Sendable (Data, String, String, AIProviderType, String?, String, @escaping (Progress) -> Void) async throws -> String = { _, _, _, _, _, _, _ in "" }
}

/// Enhancement options for AI processing
struct EnhancementOptions {
    /// The prompt to send to the AI model for text enhancement
    var prompt: String
    
    /// Temperature controls randomness: lower values (0.1-0.3) are more precise,
    /// higher values (0.7-1.0) give more creative/varied results
    var temperature: Double
    
    /// Maximum number of tokens to generate in the response
    var maxTokens: Int
    
    /// Optional context information (e.g., screenshot summary) to help the model
    var context: String?
    
    /// Default prompt for enhancing transcribed text with clear instructions
    static let defaultPrompt = """
    You are a professional editor improving transcribed text from speech-to-text.
    
    Your task is to:
    1. Fix grammar, punctuation, and capitalization
    2. Correct obvious transcription errors and typos
    3. Format the text to be more readable
    4. Preserve all meaning and information from the original
    5. Make the text flow naturally as written text
    6. DO NOT add any new information that wasn't in the original
    7. DO NOT remove any information from the original text
    
    Focus only on improving readability while preserving the exact meaning.

    Respond **only** with the edited text, no explanation, no preamble.
    """
    
    /// Default enhancement options for transcribed text
    static let `default` = EnhancementOptions(
        prompt: defaultPrompt,
        temperature: 0.3,
        maxTokens: 1000,
        context: nil
    )
    
    /// Custom initialization with sensible defaults
    init(prompt: String = defaultPrompt, temperature: Double = 0.3, maxTokens: Int = 1000, context: String? = nil) {
        self.prompt = prompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.context = context
    }
}

/// Remote AI Model information
struct RemoteAIModel: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let ownedBy: String
    let contextWindow: Int
    let maxCompletionTokens: Int
    let active: Bool
    
    var displayName: String {
        // Clean up model names for better display
        if name.contains("/") {
            return String(name.split(separator: "/").last ?? "")
        }
        return name
    }
}

/// Dependency Key for AIEnhancementClient
extension AIEnhancementClient: DependencyKey {
    static var liveValue: Self {
        let live = AIEnhancementClientLive()
        return Self(
            enhance: { try await live.enhance(text: $0, model: $1, options: $2, provider: $3, apiKey: $4, progressCallback: $5) },
            isLMStudioAvailable: { await live.isLMStudioAvailable() },
            getAvailableModels: { try await live.getAvailableModels() },
            getLocalModels: { try await live.getLocalModels(provider: $0) },
            getRemoteModels: { try await live.getRemoteModels(provider: $0, apiKey: $1) },
            testRemoteConnection: { await live.testRemoteConnection(provider: $0, apiKey: $1) },
            checkProviderAvailability: { await live.checkProviderAvailability(provider: $0, apiKey: $1) },
            analyzeImage: { try await live.analyzeImage(imageData: $0, model: $1, prompt: $2, provider: $3, apiKey: $4, systemPrompt: $5, progressCallback: $6) }
        )
    }
}

extension DependencyValues {
    var aiEnhancement: AIEnhancementClient {
        get { self[AIEnhancementClient.self] }
        set { self[AIEnhancementClient.self] = newValue }
    }
}

/// Live implementation of AIEnhancementClient
class AIEnhancementClientLive {
    // New provider registry for modular delegation
    private let providerServices: [AIProviderType: any AIProviderService] = [
        .ollama: OllamaProvider(),
        .lmstudio: LMStudioProvider(),
        .groq: GroqProvider(),
        .gemini: GeminiProvider()
    ]
    
    // MARK: - Public Methods
    
    /// Enhances text using either local or remote AI models
    func enhance(text: String, model: String, options: EnhancementOptions, provider: AIProviderType, apiKey: String?, progressCallback: @escaping (Progress) -> Void) async throws -> String {
        guard !text.isEmpty, text.count > 5, text != "[BLANK_AUDIO]" else { return text }
        guard let svc = providerServices[provider] else { return text }
        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)
        let result = try await svc.enhance(text, model: model, options: options, apiKey: apiKey) { fraction in
            progress.completedUnitCount = Int64(fraction * 100)
            progressCallback(progress)
        }
        progress.completedUnitCount = 100
        progressCallback(progress)
        return result
    }
    
    /// Checks if Ollama is available on the system
    func isOllamaAvailable() async -> Bool {
        await providerServices[.ollama]?.isAvailable(apiKey: nil) ?? false
    }
    
    /// Gets a list of available models from Ollama
    func getAvailableModels() async throws -> [String] {
        try await providerServices[.ollama]?.fetchModels(apiKey: nil).map { $0.id } ?? []
    }
    
    /// Gets a list of available models from a local provider (Ollama or LM Studio)
    func getLocalModels(provider: AIProviderType) async throws -> [String] {
        guard let svc = providerServices[provider] else { return [] }
        return try await svc.fetchModels(apiKey: nil).map { $0.id }
    }
    
    /// Gets a list of available models from a remote provider
    func getRemoteModels(provider: AIProviderType, apiKey: String) async throws -> [RemoteAIModel] {
        guard let svc = providerServices[provider] else { return [] }
        return try await svc.fetchModels(apiKey: apiKey)
    }
    
    /// Tests connection to a remote AI provider
    func testRemoteConnection(provider: AIProviderType, apiKey: String) async -> Bool {
        guard let svc = providerServices[provider] else { return false }
        return await svc.testConnection(apiKey: apiKey)
    }
    
    /// Checks availability/reachability of any provider (local or remote). For remote providers pass API key.
    func checkProviderAvailability(provider: AIProviderType, apiKey: String) async -> Bool {
        guard let svc = providerServices[provider] else { return false }
        return await svc.isAvailable(apiKey: apiKey)
    }
    
    /// Analyzes a screenshot (PNG/JPEG data) with a VLM model and returns a short textual summary.
    /// - Parameters:
    ///   - imageData: The raw PNG/JPEG data to analyse.
    ///   - model: The name of the VLM model to use (e.g. "llava:latest").
    ///   - prompt: A natural-language instruction describing what the model should return.
    ///   - provider: The provider to route the request to (local Ollama or a remote service).
    ///   - apiKey: Optional API-key for remote providers.
    ///   - systemPrompt: The system prompt that defines how the AI should analyze images.
    ///   - progressCallback: Reports fractional completion (0–1).
    /// - Returns: The model's textual response, trimmed of whitespace.
    func analyzeImage(imageData: Data, model: String, prompt: String, provider: AIProviderType, apiKey: String?, systemPrompt: String, progressCallback: @escaping (Progress) -> Void) async throws -> String {
        guard let svc = providerServices[provider] else {
            throw NSError(domain: "AIEnhancementClient", code: -999, userInfo: [NSLocalizedDescriptionKey: "Unsupported provider"])
        }
        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)
        let result = try await svc.analyzeImage(data: imageData, model: model, prompt: prompt, systemPrompt: systemPrompt, apiKey: apiKey) { fraction in
            progress.completedUnitCount = Int64(fraction * 100)
            progressCallback(progress)
        }
        progress.completedUnitCount = 100
        progressCallback(progress)
        return result
    }

    // MARK: - LM Studio Implementation

    /// Checks if LM Studio REST server is running on localhost:1234
    func isLMStudioAvailable() async -> Bool {
        await providerServices[.lmstudio]?.isAvailable(apiKey: nil) ?? false
    }
}
