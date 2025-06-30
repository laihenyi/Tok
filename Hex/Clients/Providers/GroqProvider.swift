import Foundation

struct GroqProvider: AIProviderService {
    let kind: AIProviderType = .groq

    // MARK: Connectivity
    func isAvailable(apiKey: String?) async -> Bool {
        await testConnection(apiKey: apiKey)
    }

    func testConnection(apiKey: String?) async -> Bool {
        guard let key = apiKey, !key.isEmpty else { return false }
        do {
            _ = try await fetchModels(apiKey: key)
            return true
        } catch {
            print("[GroqProvider] connection failed: \(error)")
            return false
        }
    }

    // MARK: Models
    func fetchModels(apiKey: String?) async throws -> [RemoteAIModel] {
        guard let key = apiKey, !key.isEmpty else {
            throw NSError(domain: "GroqProvider", code: -6, userInfo: [NSLocalizedDescriptionKey: "Groq API key is required"])
        }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "GroqProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Groq API error"])
        }
        struct Resp: Decodable {
            struct M: Decodable {
                let id: String; let owned_by: String; let active: Bool; let context_window: Int; let max_completion_tokens: Int
            }
            let data: [M]
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return decoded.data.filter { $0.active && !$0.id.contains("whisper") && !$0.id.contains("tts") }.map { m in
            RemoteAIModel(id: m.id, name: m.id, ownedBy: m.owned_by, contextWindow: m.context_window, maxCompletionTokens: m.max_completion_tokens, active: m.active)
        }.sorted { $0.displayName < $1.displayName }
    }

    // MARK: Enhance
    func enhance(_ text: String, model: String, options: EnhancementOptions, apiKey: String?, progress: @escaping (Double) -> Void) async throws -> String {
        progress(0.1)
        guard let key = apiKey, !key.isEmpty else { throw NSError(domain: "GroqProvider", code: -6, userInfo: [NSLocalizedDescriptionKey: "Groq API key required"]) }
        let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let messages: [[String: Any]] = [
            ["role": "system", "content": options.prompt],
            ["role": "user", "content": (options.context != nil ? "<CONTEXT>\(options.context!)</CONTEXT>\n\n" : "") + "<RAW_TRANSCRIPTION>\(text)</RAW_TRANSCRIPTION>"]
        ]
        let body: [String: Any] = [
            "messages": messages,
            "model": model,
            "temperature": max(0.1, min(1.0, options.temperature)),
            "stream": false
        ]
        progress(0.2)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "GroqProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        progress(0.8)
        struct Resp: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let content = decoded.choices.first?.message.content else { throw NSError(domain: "GroqProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response"])}
        progress(1.0)
        return cleanThinkingTags(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Vision
    func analyzeImage(data imageData: Data, model: String, prompt: String, systemPrompt: String, apiKey: String?, progress: @escaping (Double) -> Void) async throws -> String {
        guard let key = apiKey, !key.isEmpty else { throw NSError(domain: "GroqProvider", code: -6, userInfo: [NSLocalizedDescriptionKey: "Groq API key required"])}
        guard !imageData.isEmpty else { throw NSError(domain: "GroqProvider", code: -10, userInfo: [NSLocalizedDescriptionKey: "Empty image data"])}
        progress(0.1)
        let isPNG = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let mime = isPNG ? "image/png" : "image/jpeg"
        let base64 = imageData.base64EncodedString()
        let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(base64)"]]
            ]]
        ]
        let body: [String: Any] = ["model": model, "messages": messages, "temperature": 0.2, "stream": false]
        progress(0.2)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "GroqProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        progress(0.8)
        struct Resp: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let content = decoded.choices.first?.message.content else { throw NSError(domain: "GroqProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response"])}
        progress(1.0)
        return cleanThinkingTags(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }
} 