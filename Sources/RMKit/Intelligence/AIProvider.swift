import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI backends shared with the web app's `intelligence/provider.py`: Google Gemini, OpenAI, or any
/// OpenAI-compatible endpoint such as a local Ollama server.
public enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gemini, openai, ollama, apple
    public var id: String { rawValue }

    /// Providers offered in Settings. Apple Intelligence needs macOS 26.
    public static var available: [AIProviderKind] {
        if #available(macOS 26.0, *) { return allCases }
        return allCases.filter { $0 != .apple }
    }

    public var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama (local)"
        case .apple: return "Apple Intelligence (on-device)"
        }
    }

    public var defaultModel: String {
        switch self {
        case .gemini: return "gemini-flash-lite-latest"
        case .openai: return "gpt-4o-mini"
        case .ollama: return "llama3.2-vision"
        case .apple: return "default"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .openai: return "https://api.openai.com"
        case .ollama: return "http://localhost:11434"
        case .apple: return ""
        }
    }

    public var needsAPIKey: Bool { self == .gemini || self == .openai }
    public var supportsImages: Bool { self != .apple }
    public var usesNetworkSettings: Bool { self != .apple }

    /// Roughly how many characters of prompt the provider handles well. Longer meetings are summarised
    /// in chunks first. Ollama's OpenAI endpoint defaults to a small context window.
    public var promptBudget: Int {
        switch self {
        case .gemini: return 400_000
        case .openai: return 300_000
        case .ollama: return 12_000
        case .apple: return 6_000  // 4,096-token context shared with the schema and the answer
        }
    }
}

public struct AISettings: Codable, Equatable, Sendable {
    public var provider: AIProviderKind = .gemini
    public var model: String = AIProviderKind.gemini.defaultModel
    public var baseURL: String = ""
    public init() {}

    static let keychainPrefix = "ai-api-key-"
    public static func apiKey(for kind: AIProviderKind) -> String { Secrets.get(keychainPrefix + kind.rawValue) ?? "" }
    public static func setAPIKey(_ key: String, for kind: AIProviderKind) { Secrets.set(key, for: keychainPrefix + kind.rawValue) }
}

public struct AIProvider: Sendable {
    public let settings: AISettings
    public let apiKey: String
    private let session: URLSession

    public init(settings: AISettings, apiKey: String? = nil, session: URLSession = .shared) {
        self.settings = settings
        self.apiKey = (apiKey ?? AISettings.apiKey(for: settings.provider)).trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    var model: String {
        let m = settings.model.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? settings.provider.defaultModel : m
    }

    var base: String {
        let b = settings.baseURL.trimmingCharacters(in: .whitespaces)
        return (b.isEmpty ? settings.provider.defaultBaseURL : b).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Sends a prompt (optionally with a PNG image) and returns the model's text reply.
    public func complete(prompt: String, system: String = "", imagePNG: Data? = nil, timeout: TimeInterval = 60) async throws -> String {
        try await complete(prompt: prompt, system: system, images: imagePNG.map { [$0] } ?? [], timeout: timeout)
    }

    /// Sends a prompt with any number of PNG images (ignored by text-only providers).
    public func complete(prompt: String, system: String = "", images: [Data], timeout: TimeInterval = 60) async throws -> String {
        if settings.provider.needsAPIKey, apiKey.isEmpty {
            throw RMError.auth("Add an API key for \(settings.provider.displayName) in Settings › AI.")
        }
        switch settings.provider {
        case .gemini: return try await gemini(prompt: prompt, system: system, images: images, timeout: timeout)
        case .openai, .ollama: return try await openAICompatible(prompt: prompt, system: system, images: images, timeout: timeout)
        case .apple: return try await appleOnDevice(prompt: prompt, system: system)
        }
    }

    private func appleOnDevice(prompt: String, system: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                throw RMError.auth("Apple Intelligence isn't available: turn it on in System Settings › Apple Intelligence & Siri.")
            }
            let session = system.isEmpty ? LanguageModelSession(model: model) : LanguageModelSession(model: model, instructions: system)
            // The 4,096-token window holds the prompt and the answer; cap the answer so it can't overflow.
            let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 700)
            return try await session.respond(to: prompt, options: options).content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw RMError.auth("Apple Intelligence needs macOS 26.")
    }

    /// Minimal round trip used by the Settings "Test" button. Returns latency in seconds.
    public func testConnection() async throws -> (reply: String, latency: TimeInterval) {
        let t0 = Date()
        let reply = try await complete(prompt: "Respond with only the single word: OK", timeout: 20)
        return (reply.isEmpty ? "OK" : reply, Date().timeIntervalSince(t0))
    }

    private func gemini(prompt: String, system: String, images: [Data], timeout: TimeInterval) async throws -> String {
        let modelName = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        var req = URLRequest(url: URL(string: "\(base)/v1beta/models/\(modelName):generateContent")!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var parts: [[String: Any]] = [["text": system.isEmpty ? prompt : "\(system)\n\n\(prompt)"]]
        for image in images { parts.append(["inline_data": ["mime_type": "image/png", "data": image.base64EncodedString()]]) }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["parts": parts]]])

        let obj = try await post(req, label: "Gemini")
        let cand = (obj["candidates"] as? [[String: Any]])?.first
        let outParts = ((cand?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        return outParts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openAICompatible(prompt: String, system: String, images: [Data], timeout: TimeInterval) async throws -> String {
        var req = URLRequest(url: URL(string: "\(base)/v1/chat/completions")!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var messages: [[String: Any]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for image in images {
            content.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(image.base64EncodedString())"]])
        }
        messages.append(["role": "user", "content": content])
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages])

        let obj = try await post(req, label: settings.provider.displayName)
        let msg = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return (msg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func post(_ req: URLRequest, label: String) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = ((jsonObject(data)?["error"] as? [String: Any])?["message"] as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw RMError.http(status, "\(label): \(detail)")
        }
        return jsonObject(data) ?? [:]
    }
}
