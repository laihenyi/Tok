import Foundation

struct OllamaProvider: AIProviderService {
    let kind: AIProviderType = .ollama

    // MARK: – Connectivity
    func isAvailable(apiKey _: String?) async -> Bool {
        do {
            var request = URLRequest(url: URL(string: "http://localhost:11434/api/version")!)
            request.timeoutInterval = 5.0
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse { return http.statusCode == 200 }
            return false
        } catch {
            print("[OllamaProvider] Availability check failed: \(error)")
            return false
        }
    }

    func testConnection(apiKey _: String?) async -> Bool {
        await isAvailable(apiKey: nil)
    }

    // MARK: – Model catalogue
    func fetchModels(apiKey _: String?) async throws -> [RemoteAIModel] {
        struct TagList: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 5.0
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "OllamaProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch tags"])
        }
        let decoded = try JSONDecoder().decode(TagList.self, from: data)
        return decoded.models.map { m in
            RemoteAIModel(
                id: m.name,
                name: m.name,
                ownedBy: "Local",
                contextWindow: 8192,
                maxCompletionTokens: 4096,
                active: true
            )
        }.sorted { $0.displayName < $1.displayName }
    }

    // MARK: – Enhancement
    func enhance(
        _ text: String,
        model: String,
        options: EnhancementOptions,
        apiKey _: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> String {
        progress(0.1)

        guard !model.isEmpty else {
            throw NSError(domain: "OllamaProvider", code: -4, userInfo: [NSLocalizedDescriptionKey: "No model selected"])
        }

        var fullPrompt = """
        \(options.prompt)
        """
        if let ctx = options.context, !ctx.isEmpty {
            fullPrompt += "\n\nCONTEXT:\n\(ctx)"
        }
        fullPrompt += "\n\nTEXT TO IMPROVE:\n\(text)\n\nIMPROVED TEXT:"

        let temperature = max(0.1, min(1.0, options.temperature))
        let maxTokens = max(100, min(2000, options.maxTokens))

        let body: [String: Any] = [
            "model": model,
            "prompt": fullPrompt,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
            "system": "You are an AI that improves transcribed text while preserving meaning."
        ]

        let url = URL(string: "http://localhost:11434/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        progress(0.2)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "OllamaProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        progress(0.8)
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any], let resp = dict["response"] as? String {
            progress(1.0)
            return cleanThinkingTags(from: resp).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw NSError(domain: "OllamaProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "Malformed response"])
    }

    // MARK: – Vision
    func analyzeImage(
        data imageData: Data,
        model: String,
        prompt: String,
        systemPrompt _: String,
        apiKey _: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> String {
        guard !imageData.isEmpty else {
            throw NSError(domain: "OllamaProvider", code: -10, userInfo: [NSLocalizedDescriptionKey: "Empty image data"])
        }

        progress(0.1)
        let base64 = imageData.base64EncodedString()
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "images": [base64],
            "stream": false
        ]
        let url = URL(string: "http://localhost:11434/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        progress(0.2)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "OllamaProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        progress(0.8)
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any], let resp = dict["response"] as? String {
            progress(1.0)
            return cleanThinkingTags(from: resp).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw NSError(domain: "OllamaProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "Malformed response"])
    }
} 