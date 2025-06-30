import Foundation

struct GeminiProvider: AIProviderService {
    let kind: AIProviderType = .gemini

    // MARK: – Connectivity
    func isAvailable(apiKey: String?) async -> Bool {
        await testConnection(apiKey: apiKey)
    }

    func testConnection(apiKey: String?) async -> Bool {
        guard let key = apiKey, !key.isEmpty else { return false }
        do {
            _ = try await fetchModels(apiKey: key)
            return true
        } catch {
            print("[GeminiProvider] connection failed: \(error)")
            return false
        }
    }

    // MARK: – Model catalogue
    func fetchModels(apiKey: String?) async throws -> [RemoteAIModel] {
        guard let key = apiKey, !key.isEmpty else {
            throw NSError(domain: "GeminiProvider", code: -6, userInfo: [NSLocalizedDescriptionKey: "Gemini API key is required"])
        }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "GeminiProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models"])
        }
        struct Resp: Decodable { struct Model: Decodable { let name: String; let displayName: String?; let inputTokenLimit: Int?; let outputTokenLimit: Int? }; let models: [Model] }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return decoded.models.map { m in
            RemoteAIModel(
                id: m.name,
                name: m.displayName ?? m.name,
                ownedBy: "Google",
                contextWindow: m.inputTokenLimit ?? 131072,
                maxCompletionTokens: m.outputTokenLimit ?? 8192,
                active: true
            )
        }.sorted { $0.displayName < $1.displayName }
    }

    // MARK: – Text enhancement
    func enhance(_ text: String, model: String, options: EnhancementOptions, apiKey: String?, progress: @escaping (Double) -> Void) async throws -> String {
        progress(0.1)
        guard let key = apiKey, !key.isEmpty else { throw NSError(domain: "GeminiProvider", code: -6, userInfo: [NSLocalizedDescriptionKey: "Gemini API key required"]) }
        guard !model.isEmpty else { throw NSError(domain: "GeminiProvider", code: -4, userInfo: [NSLocalizedDescriptionKey: "No model selected"]) }
        // Ensure we don't duplicate the "models/" path component supplied by the API
        let cleanModel = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(cleanModel):generateContent?key=\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let temperature = max(0.1, min(1.0, options.temperature))
        let fullPrompt: String = {
            var p = ""
            if let ctx = options.context, !ctx.isEmpty {
                p += "\n\nCONTEXT:\n\(ctx)"
            }
            p += "\n\nTEXT TO IMPROVE:\n\(text)"
            return p
        }()
        let contentsPayload: [[String: Any]] = [["parts": [["text": fullPrompt]]]]
        let body: [String: Any] = [
            "system_instruction": [
                "parts": [
                    [
                        "text": options.prompt
                    ]
                ]
            ],
            "contents": contentsPayload,
            "generationConfig": ["temperature": temperature]
        ]
        progress(0.2)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)


        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "GeminiProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Gemini error: \(msg)"])
        }
        progress(0.8)
        struct Resp: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                    let text: String?
                }
                let content: Content?
                let output: String?
            }
            let candidates: [Candidate]
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        var textResponse: String? = {
            if let part = decoded.candidates.first?.content?.parts?.first(where: { $0.text != nil })?.text { return part }
            if let direct = decoded.candidates.first?.content?.text { return direct }
            return decoded.candidates.first?.output
        }()

        // Fallback to a looser JSON parse if strict decoding found nothing
        if textResponse == nil || textResponse?.isEmpty == true {
            textResponse = fallbackExtractText(from: data)
        }

        guard let content = textResponse, !content.isEmpty else { throw NSError(domain: "GeminiProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response"])}
        progress(1.0)
        return cleanThinkingTags(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – Vision
    func analyzeImage(data imageData: Data, model: String, prompt: String, systemPrompt: String, apiKey: String?, progress: @escaping (Double) -> Void) async throws -> String {
        progress(0.1)
        guard let key = apiKey, !key.isEmpty else { throw NSError(domain: "GeminiProvider", code: -6, userInfo: [NSLocalizedDescriptionKey: "Gemini API key required"]) }
        guard !imageData.isEmpty else { throw NSError(domain: "GeminiProvider", code: -10, userInfo: [NSLocalizedDescriptionKey: "Empty image data"]) }
        let isPNG = imageData.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let mime = isPNG ? "image/png" : "image/jpeg"
        let base64 = imageData.base64EncodedString()
        // Ensure we don't duplicate the "models/" path component supplied by the API
        let cleanModel = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(cleanModel):generateContent?key=\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let contentsPayload: [[String: Any]] = [["parts": [["inline_data": ["mime_type": mime, "data": base64]], ["text": prompt]]]]
        let body: [String: Any] = ["contents": contentsPayload, "generationConfig": ["temperature": 0.2]]
        progress(0.2)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw NSError(domain: "GeminiProvider", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Gemini error: \(msg)"])
        }
        progress(0.8)
        struct Resp: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                    let text: String?
                }
                let content: Content?
                let output: String?
            }
            let candidates: [Candidate]
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        var textResponse: String? = {
            if let part = decoded.candidates.first?.content?.parts?.first(where: { $0.text != nil })?.text { return part }
            if let direct = decoded.candidates.first?.content?.text { return direct }
            return decoded.candidates.first?.output
        }()

        // Fallback to a looser JSON parse if strict decoding found nothing
        if textResponse == nil || textResponse?.isEmpty == true {
            textResponse = fallbackExtractText(from: data)
        }

        guard let content = textResponse, !content.isEmpty else { throw NSError(domain: "GeminiProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "No response"])}
        progress(1.0)
        return cleanThinkingTags(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Extracts the first text content from a Gemini API response using a forgiving JSON walk. This is used as a fallback when strict Decodable parsing fails (Google occasionally tweaks response shapes).
    private func fallbackExtractText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else { return nil }

        // 1️⃣ candidate.content.parts[0].text
        if let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]],
           let txt = parts.first?["text"] as? String, !txt.isEmpty {
            return txt
        }

        // 2️⃣ candidate.content.text (rare)
        if let content = first["content"] as? [String: Any],
           let txt = content["text"] as? String, !txt.isEmpty {
            return txt
        }

        // 3️⃣ candidate.output (legacy)
        if let txt = first["output"] as? String, !txt.isEmpty {
            return txt
        }

        return nil
    }
} 
