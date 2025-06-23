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
    
    /// Checks if Ollama is installed and running on the system
    var isOllamaAvailable: @Sendable () async -> Bool = { false }
    
    /// Gets a list of available models from Ollama
    var getAvailableModels: @Sendable () async throws -> [String] = { [] }
    
    /// Gets a list of available models from a remote provider
    var getRemoteModels: @Sendable (AIProviderType, String) async throws -> [RemoteAIModel] = { _, _ in [] }
    
    /// Tests connection to a remote AI provider
    var testRemoteConnection: @Sendable (AIProviderType, String) async -> Bool = { _, _ in false }

    /// Analyzes a screenshot (PNG/JPEG data) with a VLM model and returns a short textual summary.
    /// - Parameters:
    ///   - imageData: The raw PNG/JPEG data to analyse.
    ///   - model: The name of the VLM model to use (e.g. "llava:latest").
    ///   - prompt: A natural-language instruction describing what the model should return.
    ///   - provider: The provider to route the request to (local Ollama or a remote service).
    ///   - apiKey: Optional API-key for remote providers.
    ///   - progressCallback: Reports fractional completion (0–1).
    /// - Returns: The model's textual response, trimmed of whitespace.
    var analyzeImage: @Sendable (Data, String, String, AIProviderType, String?, @escaping (Progress) -> Void) async throws -> String = { _, _, _, _, _, _ in "" }
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
            isOllamaAvailable: { await live.isOllamaAvailable() },
            getAvailableModels: { try await live.getAvailableModels() },
            getRemoteModels: { try await live.getRemoteModels(provider: $0, apiKey: $1) },
            testRemoteConnection: { await live.testRemoteConnection(provider: $0, apiKey: $1) },
            analyzeImage: { try await live.analyzeImage(imageData: $0, model: $1, prompt: $2, provider: $3, apiKey: $4, progressCallback: $5) }
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
    // MARK: - Public Methods
    
    /// Enhances text using either local or remote AI models
    func enhance(text: String, model: String, options: EnhancementOptions, provider: AIProviderType, apiKey: String?, progressCallback: @escaping (Progress) -> Void) async throws -> String {
        // Skip if the text is empty or too short
        guard !text.isEmpty, text.count > 5, text != "[BLANK_AUDIO]" else {
            print("[AIEnhancementClientLive] Text too short for enhancement, returning original")
            return text
        }
        
        let progress = Progress(totalUnitCount: 100)
        progressCallback(progress)
        
        print("[AIEnhancementClientLive] Starting text enhancement with \(provider.displayName), model: \(model)")
        print("[AIEnhancementClientLive] Text to enhance (\(text.count) chars): \"\(text.prefix(50))...\"")
        
        do {
            let enhancedText: String
            
            switch provider {
            case .ollama:
                // First verify Ollama is available
                let isAvailable = await isOllamaAvailable()
                if !isAvailable {
                    print("[AIEnhancementClientLive] Ollama not available, cannot enhance text")
                    throw NSError(domain: "AIEnhancementClient", code: -5, 
                                  userInfo: [NSLocalizedDescriptionKey: "Ollama is not available. Please ensure it's running."])
                }
                
                enhancedText = try await enhanceWithOllama(text: text, model: model, options: options) { fraction in
                    progress.completedUnitCount = Int64(fraction * 100)
                    progressCallback(progress)
                }
                
            case .groq:
                guard let apiKey = apiKey, !apiKey.isEmpty else {
                    throw NSError(domain: "AIEnhancementClient", code: -6,
                                  userInfo: [NSLocalizedDescriptionKey: "Groq API key is required"])
                }
                
                enhancedText = try await enhanceWithGroq(text: text, model: model, options: options, apiKey: apiKey) { fraction in
                    progress.completedUnitCount = Int64(fraction * 100)
                    progressCallback(progress)
                }
            }
            
            progress.completedUnitCount = 100
            progressCallback(progress)
            
            print("[AIEnhancementClientLive] Successfully enhanced text: \"\(enhancedText.prefix(50))...\"")
            return enhancedText
        } catch {
            print("[AIEnhancementClientLive] Error enhancing text: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Checks if Ollama is available on the system
    func isOllamaAvailable() async -> Bool {
        // Simple check - try to connect to Ollama's API endpoint
        do {
            var request = URLRequest(url: URL(string: "http://localhost:11434/api/version")!)
            request.timeoutInterval = 5.0 // Longer timeout for more reliability
            
            print("[AIEnhancementClientLive] Checking Ollama availability...")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                let isAvailable = httpResponse.statusCode == 200
                print("[AIEnhancementClientLive] Ollama availability check: \(isAvailable ? "Available" : "Unavailable") (status: \(httpResponse.statusCode))")
                if isAvailable, let dataString = String(data: data, encoding: .utf8) {
                    print("[AIEnhancementClientLive] Ollama version: \(dataString)")
                }
                return isAvailable
            }
            print("[AIEnhancementClientLive] Ollama unavailable: Invalid response type")
            return false
        } catch {
            print("[AIEnhancementClientLive] Ollama not available: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Gets a list of available models from Ollama
    func getAvailableModels() async throws -> [String] {
        // Our direct API implementation:
        struct ModelResponse: Decodable {
            struct Model: Decodable {
                let name: String
                let modifiedAt: String?
                let size: Int64?
                
                enum CodingKeys: String, CodingKey {
                    case name
                    case modifiedAt = "modified_at"
                    case size
                }
            }
            let models: [Model]
        }
        
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 5.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "AIEnhancementClient", code: -1, 
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response from Ollama"])
            }
            
            if httpResponse.statusCode != 200 {
                throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode, 
                              userInfo: [NSLocalizedDescriptionKey: "Ollama returned status code \(httpResponse.statusCode)"])
            }
            
            do {
                let modelResponse = try JSONDecoder().decode(ModelResponse.self, from: data)
                // Sort models alphabetically for better display
                return modelResponse.models.map { $0.name }.sorted()
            } catch let decodingError {
                print("[AIEnhancementClientLive] Failed to decode model list: \(decodingError)")
                throw NSError(domain: "AIEnhancementClient", code: -2, 
                            userInfo: [NSLocalizedDescriptionKey: "Failed to parse model list from Ollama. \(decodingError.localizedDescription)"])
            }
        } catch {
            print("[AIEnhancementClientLive] Error getting models: \(error.localizedDescription)")
            throw NSError(domain: "AIEnhancementClient", code: -3, 
                         userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Ollama. Ensure it's running."])
        }
    }
    
    /// Enhances text using Ollama's API
    private func enhanceWithOllama(text: String, model: String, options: EnhancementOptions, progressCallback: @escaping (Double) -> Void) async throws -> String {
        // Initial progress update
        progressCallback(0.1)
        
        // Validate inputs
        guard !model.isEmpty else {
            print("[AIEnhancementClientLive] Error: No model selected for enhancement")
            throw NSError(domain: "AIEnhancementClient", code: -4, 
                          userInfo: [NSLocalizedDescriptionKey: "No model selected for enhancement"])
        }
        
        let url = URL(string: "http://localhost:11434/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60.0 // Allow longer timeout for generation
        
        var fullPrompt = """
        \(options.prompt)
        """

        if let ctx = options.context, !ctx.isEmpty {
            fullPrompt += """

        CONTEXT:
        \(ctx)
        """
        }

        fullPrompt += """

        TEXT TO IMPROVE:
        \(text)

        IMPROVED TEXT:
        """
        
        // Build request parameters with appropriate defaults
        let temperature = max(0.1, min(1.0, options.temperature)) // Ensure valid range
        let maxTokens = max(100, min(2000, options.maxTokens))   // Reasonable limits
        
        let requestDict: [String: Any] = [
            "model": model,
            "prompt": fullPrompt,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
            "system": "You are an AI that improves transcribed text while preserving meaning."
        ]
        
        print("[AIEnhancementClientLive] Preparing request to Ollama with model: \(model), temp: \(temperature), max_tokens: \(maxTokens)")
        
        do {
            // Progress update - request prepared
            progressCallback(0.2)
            
            // Convert to JSON and send
            let requestData = try JSONSerialization.data(withJSONObject: requestDict)
            request.httpBody = requestData
            
            print("[AIEnhancementClientLive] Sending request to Ollama API...")
            
            // Make the request
            let (responseData, urlResponse): (Data, URLResponse)
            do {
                (responseData, urlResponse) = try await URLSession.shared.data(for: request)
            } catch {
                // Treat timeouts and connectivity issues as "Ollama unavailable"
                print("[AIEnhancementClientLive] Generation failed: \(error.localizedDescription)")
                throw NSError(domain: "AIEnhancementClient",
                            code: -1001, // NSURLErrorTimedOut or similar
                            userInfo: [NSLocalizedDescriptionKey: "Ollama is unresponsive. Please check if it's running."])
            }
            
            // Progress update - response received
            progressCallback(0.8)
            
            print("[AIEnhancementClientLive] Received response from Ollama API")
            
            // Validate response
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                print("[AIEnhancementClientLive] Error: Invalid response type from Ollama")
                throw NSError(domain: "AIEnhancementClient", code: -1, 
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response from Ollama"])
            }
            
            print("[AIEnhancementClientLive] Ollama response status: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode != 200 {
                // Try to extract error message if available
                if let errorDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let errorMessage = errorDict["error"] as? String {
                    print("[AIEnhancementClientLive] Ollama API error: \(errorMessage)")
                    throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode, 
                                  userInfo: [NSLocalizedDescriptionKey: "Ollama error: \(errorMessage)"])
                } else {
                    print("[AIEnhancementClientLive] Ollama error with status code: \(httpResponse.statusCode)")
                    throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode, 
                                  userInfo: [NSLocalizedDescriptionKey: "Ollama returned status code \(httpResponse.statusCode)"])
                }
            }
            
            // Try to log raw response for debugging
            if let responseString = String(data: responseData, encoding: .utf8) {
                print("[AIEnhancementClientLive] Raw response: \(responseString.prefix(100))...")
            }
            
            // Parse response
            if let responseDict = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let enhancedText = responseDict["response"] as? String {
                
                // Progress update - processing complete
                progressCallback(1.0)
                
                print("[AIEnhancementClientLive] Successfully parsed Ollama response")
                
                // Clean up the response - trim whitespace and ensure it's not empty
                let cleanedText = enhancedText.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanedText.isEmpty ? text : cleanedText
            } else {
                print("[AIEnhancementClientLive] Error: Failed to parse Ollama response")
                throw NSError(domain: "AIEnhancementClient", code: -2, 
                              userInfo: [NSLocalizedDescriptionKey: "Failed to parse Ollama response"])
            }
        } catch let error as NSError {
            // Log the error and rethrow
            print("[AIEnhancementClientLive] Error enhancing text: \(error.localizedDescription)")
            throw error
        } catch {
            // Handle unexpected errors
            print("[AIEnhancementClientLive] Unexpected error: \(error)")
            throw NSError(domain: "AIEnhancementClient", code: -3, 
                          userInfo: [NSLocalizedDescriptionKey: "Error communicating with Ollama: \(error.localizedDescription)"])
        }
    }
    
    /// Gets a list of available models from a remote provider
    func getRemoteModels(provider: AIProviderType, apiKey: String) async throws -> [RemoteAIModel] {
        switch provider {
        case .ollama:
            // For Ollama, convert local models to RemoteAIModel format
            let localModels = try await getAvailableModels()
            return localModels.map { modelName in
                RemoteAIModel(
                    id: modelName,
                    name: modelName,
                    ownedBy: "Local",
                    contextWindow: 8192, // Default context window
                    maxCompletionTokens: 4096, // Default max tokens
                    active: true
                )
            }
        case .groq:
            return try await getGroqModels(apiKey: apiKey)
        }
    }
    
    /// Tests connection to a remote AI provider
    func testRemoteConnection(provider: AIProviderType, apiKey: String) async -> Bool {
        switch provider {
        case .ollama:
            return await isOllamaAvailable()
        case .groq:
            return await testGroqConnection(apiKey: apiKey)
        }
    }
    
    // MARK: - Groq Implementation
    
    /// Gets available models from Groq API
    private func getGroqModels(apiKey: String) async throws -> [RemoteAIModel] {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "AIEnhancementClient", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "Groq API key is required"])
        }
        
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "AIEnhancementClient", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response from Groq API"])
            }
            
            if httpResponse.statusCode != 200 {
                throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Groq API returned status code \(httpResponse.statusCode)"])
            }
            
            struct GroqModelsResponse: Codable {
                let data: [GroqModel]
                
                struct GroqModel: Codable {
                    let id: String
                    let object: String
                    let created: Int
                    let ownedBy: String
                    let active: Bool
                    let contextWindow: Int
                    let maxCompletionTokens: Int
                    
                    enum CodingKeys: String, CodingKey {
                        case id, object, created, active
                        case ownedBy = "owned_by"
                        case contextWindow = "context_window"
                        case maxCompletionTokens = "max_completion_tokens"
                    }
                }
            }
            
            let modelsResponse = try JSONDecoder().decode(GroqModelsResponse.self, from: data)
            
            // Filter to only include chat completion models and exclude system models
            let chatModels = modelsResponse.data.filter { model in
                model.active && 
                !model.id.contains("whisper") && 
                !model.id.contains("tts") &&
                !model.id.contains("guard") &&
                !model.id.contains("prompt-guard")
            }
            
            return chatModels.map { groqModel in
                RemoteAIModel(
                    id: groqModel.id,
                    name: groqModel.id,
                    ownedBy: groqModel.ownedBy,
                    contextWindow: groqModel.contextWindow,
                    maxCompletionTokens: groqModel.maxCompletionTokens,
                    active: groqModel.active
                )
            }.sorted { $0.displayName < $1.displayName }
            
        } catch let decodingError as DecodingError {
            print("[AIEnhancementClientLive] Failed to decode Groq models: \(decodingError)")
            throw NSError(domain: "AIEnhancementClient", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to parse models from Groq API"])
        } catch {
            print("[AIEnhancementClientLive] Error getting Groq models: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Tests connection to Groq API
    private func testGroqConnection(apiKey: String) async -> Bool {
        guard !apiKey.isEmpty else { return false }
        
        do {
            _ = try await getGroqModels(apiKey: apiKey)
            return true
        } catch {
            print("[AIEnhancementClientLive] Groq connection test failed: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Enhances text using Groq's API
    private func enhanceWithGroq(text: String, model: String, options: EnhancementOptions, apiKey: String, progressCallback: @escaping (Double) -> Void) async throws -> String {
        // Initial progress update
        progressCallback(0.1)
        
        guard !model.isEmpty else {
            throw NSError(domain: "AIEnhancementClient", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "No model selected for enhancement"])
        }
        
        guard !apiKey.isEmpty else {
            throw NSError(domain: "AIEnhancementClient", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "Groq API key is required"])
        }
        
        let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        
        // Build the messages array for chat completion
        let messages = [
            [
                "role": "system",
                "content": options.prompt + (options.context != nil ? "\n\nCONTEXT: \(options.context!)" : "")
            ],
            [
                "role": "user",
                "content": text
            ]
        ]
        
        // Build request parameters
        let temperature = max(0.1, min(1.0, options.temperature))
        let maxTokens = max(100, min(8192, options.maxTokens))
        
        let requestDict: [String: Any] = [
            "messages": messages,
            "model": model,
            "temperature": temperature,
            "max_completion_tokens": maxTokens,
            "stream": false
        ]
        
        print("[AIEnhancementClientLive] Preparing request to Groq with model: \(model), temp: \(temperature), max_tokens: \(maxTokens)")
        
        do {
            // Progress update - request prepared
            progressCallback(0.2)
            
            let requestData = try JSONSerialization.data(withJSONObject: requestDict)
            request.httpBody = requestData
            
            print("[AIEnhancementClientLive] Sending request to Groq API...")
            
            let (responseData, urlResponse) = try await URLSession.shared.data(for: request)
            
            // Progress update - response received
            progressCallback(0.8)
            
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw NSError(domain: "AIEnhancementClient", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response from Groq API"])
            }
            
            print("[AIEnhancementClientLive] Groq response status: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode != 200 {
                // Try to extract error message
                if let errorDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let error = errorDict["error"] as? [String: Any],
                   let errorMessage = error["message"] as? String {
                    print("[AIEnhancementClientLive] Groq API error: \(errorMessage)")
                    throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "Groq error: \(errorMessage)"])
                } else {
                    throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "Groq API returned status code \(httpResponse.statusCode)"])
                }
            }
            
            // Parse the chat completion response
            struct GroqResponse: Codable {
                let choices: [Choice]
                
                struct Choice: Codable {
                    let message: Message
                    
                    struct Message: Codable {
                        let content: String
                    }
                }
            }
            
            let groqResponse = try JSONDecoder().decode(GroqResponse.self, from: responseData)
            
            guard let firstChoice = groqResponse.choices.first else {
                throw NSError(domain: "AIEnhancementClient", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "No response from Groq API"])
            }
            
            // Progress update - processing complete
            progressCallback(1.0)
            
            let enhancedText = firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[AIEnhancementClientLive] Successfully enhanced text with Groq")
            
            return enhancedText.isEmpty ? text : enhancedText
            
        } catch let decodingError as DecodingError {
            print("[AIEnhancementClientLive] Failed to decode Groq response: \(decodingError)")
            throw NSError(domain: "AIEnhancementClient", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to parse response from Groq API"])
        } catch let error as NSError {
            print("[AIEnhancementClientLive] Error enhancing text with Groq: \(error.localizedDescription)")
            throw error
        } catch {
            print("[AIEnhancementClientLive] Unexpected error with Groq: \(error)")
            throw NSError(domain: "AIEnhancementClient", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Error communicating with Groq API: \(error.localizedDescription)"])
        }
    }
    
    /// Analyzes a screenshot (PNG/JPEG data) with a VLM model and returns a short textual summary.
    /// - Parameters:
    ///   - imageData: The raw PNG/JPEG data to analyse.
    ///   - model: The name of the VLM model to use (e.g. "llava:latest").
    ///   - prompt: A natural-language instruction describing what the model should return.
    ///   - provider: The provider to route the request to (local Ollama or a remote service).
    ///   - apiKey: Optional API-key for remote providers.
    ///   - progressCallback: Reports fractional completion (0–1).
    /// - Returns: The model's textual response, trimmed of whitespace.
    func analyzeImage(imageData: Data, model: String, prompt: String, provider: AIProviderType, apiKey: String?, progressCallback: @escaping (Progress) -> Void) async throws -> String {
        print("[AIEnhancementClient] analyzeImage called. Provider: \(provider.displayName), Model: \(model), Prompt (first 60): \(prompt.prefix(60))…  Image bytes: \(imageData.count)")
        guard !imageData.isEmpty else {
            throw NSError(domain: "AIEnhancementClient", code: -10, userInfo: [NSLocalizedDescriptionKey: "Screenshot data is empty"])
        }

        // Create a Progress instance so callers can hook into it.
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 0
        progressCallback(progress)

        switch provider {
        case .ollama:
            // Verify Ollama availability first
            guard await isOllamaAvailable() else {
                throw NSError(domain: "AIEnhancementClient", code: -5, userInfo: [NSLocalizedDescriptionKey: "Ollama is not available. Please ensure it's running."])
            }

            // Detect image format (PNG vs JPEG) by header bytes
            let isPNG: Bool = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47])
            let mimeType = isPNG ? "image/png" : "image/jpeg"
            let base64Image = imageData.base64EncodedString()

            // Build request
            let url = URL(string: "http://localhost:11434/api/generate")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60.0

            let requestDict: [String: Any] = [
                "model": model,
                "prompt": prompt,
                "images": [
                    [
                        "type": mimeType,
                        "data": base64Image
                    ]
                ],
                "stream": false,
                "system": "You are an AI assistant that summarises what the user is currently working on based on a screenshot."
            ]

            do {
                progress.completedUnitCount = 10
                progressCallback(progress)

                let data = try JSONSerialization.data(withJSONObject: requestDict)
                request.httpBody = data

                let (responseData, urlResponse) = try await URLSession.shared.data(for: request)

                guard let httpResponse = urlResponse as? HTTPURLResponse else {
                    throw NSError(domain: "AIEnhancementClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from Ollama"])
                }

                if httpResponse.statusCode != 200 {
                    let msg = String(data: responseData, encoding: .utf8) ?? "Unknown error"
                    throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Ollama error: \(msg)"])
                }

                progress.completedUnitCount = 80
                progressCallback(progress)

                if let respDict = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let summary = respDict["response"] as? String {
                    progress.completedUnitCount = 100
                    progressCallback(progress)
                    print("[AIEnhancementClient] Analysis complete. Summary length: \(summary.count) chars")
                    return summary.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    throw NSError(domain: "AIEnhancementClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to parse Ollama response"])
                }
            } catch {
                print("[AIEnhancementClient] Error during image analysis: \(error)")
                throw error
            }

        case .groq:
            // Implement image analysis through Groq's OpenAI-compatible vision endpoint
            guard let apiKey = apiKey, !apiKey.isEmpty else {
                throw NSError(domain: "AIEnhancementClient", code: -6, userInfo: [NSLocalizedDescriptionKey: "Groq API key is required for image analysis"])
            }

            // Detect image format (PNG vs JPEG) by header bytes
            let isPNG: Bool = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47])
            let mimeType = isPNG ? "image/png" : "image/jpeg"
            let base64Image = imageData.base64EncodedString()

            // Prepare request to Groq's OpenAI-compatible endpoint
            let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 60.0

            // Build messages according to OpenAI vision format
            let messages: [[String: Any]] = [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:\(mimeType);base64,\(base64Image)"
                            ]
                        ]
                    ]
                ]
            ]

            // Build request body
            let requestDict: [String: Any] = [
                "model": model,
                "messages": messages,
                "max_completion_tokens": 512,
                "temperature": 0.2,
                "stream": false
            ]

            do {
                progress.completedUnitCount = 10
                progressCallback(progress)

                let data = try JSONSerialization.data(withJSONObject: requestDict)
                request.httpBody = data

                print("[AIEnhancementClient] Sending Groq vision request (model: \(model))…")

                let (responseData, urlResponse) = try await URLSession.shared.data(for: request)

                guard let httpResponse = urlResponse as? HTTPURLResponse else {
                    throw NSError(domain: "AIEnhancementClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from Groq API"])
                }

                if httpResponse.statusCode != 200 {
                    let msg = String(data: responseData, encoding: .utf8) ?? "Unknown error"
                    throw NSError(domain: "AIEnhancementClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Groq error: \(msg)"])
                }

                progress.completedUnitCount = 80
                progressCallback(progress)

                struct GroqVisionResponse: Decodable {
                    struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
                    let choices: [Choice]
                }

                let decoded = try JSONDecoder().decode(GroqVisionResponse.self, from: responseData)

                guard let content = decoded.choices.first?.message.content else {
                    throw NSError(domain: "AIEnhancementClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "No content in Groq response"])
                }

                progress.completedUnitCount = 100
                progressCallback(progress)
                print("[AIEnhancementClient] Groq vision analysis complete. Summary length: \(content.count) chars")
                return content.trimmingCharacters(in: .whitespacesAndNewlines)

            } catch {
                print("[AIEnhancementClient] Error during Groq image analysis: \(error)")
                throw error
            }
        }
    }
}