import Foundation

struct LMStudioProvider: AIProviderService {
    let kind: AIProviderType = .lmstudio

    // MARK: – Connectivity
    func isAvailable(apiKey _: String?) async -> Bool {
        do {
            var request = URLRequest(url: URL(string: "http://localhost:1234/api/v0/models")!)
            request.timeoutInterval = 5.0
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse { return http.statusCode == 200 }
            return false
        } catch {
            print("[LMStudioProvider] Availability check failed: \(error)")
            return false
        }
    }

    func testConnection(apiKey _: String?) async -> Bool {
        await isAvailable(apiKey: nil)
    }

    // MARK: – Model catalogue
    func fetchModels(apiKey _: String?) async throws -> [RemoteAIModel] {
        struct Resp: Decodable { struct Model: Decodable { let id: String; let publisher: String?; let max_context_length: Int?; let state: String? }; let data: [Model] }
        var request = URLRequest(url: URL(string: "http://localhost:1234/api/v0/models")!)
        request.timeoutInterval = 10.0
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "LMStudioProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models"])
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return decoded.data.map { m in
            RemoteAIModel(
                id: m.id,
                name: m.id,
                ownedBy: m.publisher ?? "Local",
                contextWindow: m.max_context_length ?? 8192,
                maxCompletionTokens: 4096,
                active: (m.state ?? "loaded") != "not-loaded"
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
        guard !model.isEmpty else { throw NSError(domain: "LMStudioProvider", code: -4, userInfo: [NSLocalizedDescriptionKey: "No model selected"]) }

        let url = URL(string: "http://localhost:1234/api/v0/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0

        let userContent = (options.context != nil ? "<CONTEXT>\(options.context!)</CONTEXT>\n\n" : "") + "<RAW_TRANSCRIPTION>\(text)</RAW_TRANSCRIPTION>"

        let messages: [[String: Any]] = [
            ["role": "system", "content": options.prompt],
            ["role": "user", "content": userContent]
        ]

        let body: [String: Any] = [
            "messages": messages,
            "model": model,
            "temperature": max(0.1, min(1.0, options.temperature)),
            "max_tokens": max(100, min(8192, options.maxTokens)),
            "stream": false
        ]

        progress(0.2)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "LMStudioProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "LM Studio error: \(msg)"])
        }
        progress(0.8)
        struct Resp: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let content = decoded.choices.first?.message.content else { throw NSError(domain: "LMStudioProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response"])}
        progress(1.0)
        return cleanThinkingTags(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – Vision
    func analyzeImage(
        data imageData: Data,
        model: String,
        prompt: String,
        systemPrompt: String,
        apiKey _: String?,
        progress: @escaping (Double) -> Void
    ) async throws -> String {
        guard !imageData.isEmpty else { throw NSError(domain: "LMStudioProvider", code: -10, userInfo: [NSLocalizedDescriptionKey: "Empty image data"]) }
        progress(0.1)
        let isPNG = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let mime = isPNG ? "image/png" : "image/jpeg"
        let base64 = imageData.base64EncodedString()

        let url = URL(string: "http://localhost:1234/api/v0/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(base64)"]]
            ]]
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.2,
            "stream": false
        ]

        progress(0.2)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "LMStudioProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "LM Studio error: \(msg)"])
        }
        progress(0.8)
        struct Resp: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard let content = decoded.choices.first?.message.content else { throw NSError(domain: "LMStudioProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response"])}
        progress(1.0)
        return cleanThinkingTags(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}