import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Протокол API модели.
enum AIProtocol: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Anthropic Messages API.
    case anthropic
    /// OpenAI Chat Completions и всё совместимое: OpenAI, OpenRouter, DeepSeek, Mistral, Groq, vLLM, Ollama, LM Studio.
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "Совместимый с OpenAI"
        }
    }
}

/// Подключение к модели: облачный сервис или свой сервер (vLLM, Ollama, LM Studio).
/// Ключ хранится в Связке ключей под `keychainAccount`, здесь его нет.
struct AIConnection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: AIProtocol
    /// Адрес API: `https://api.anthropic.com`, `https://api.openai.com/v1`, `http://gpu-server:8000/v1`.
    var baseURL: String
    var model: String
    /// Маскировать адреса и телефоны перед отправкой. Для своих серверов можно выключить.
    var redact: Bool = true
    /// Максимум токенов ответа.
    var maxTokens: Int = 800

    var keychainAccount: String { "ai-key-\(id.uuidString)" }

    /// Свой сервер: localhost, адреса локальной сети, .local.
    var isLocal: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

/// Готовые настройки популярных сервисов и локальных серверов.
struct AIPreset: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: AIProtocol
    var baseURL: String
    var model: String
    /// Ключ не нужен (локальный сервер без авторизации).
    var keyOptional: Bool = false
    var hint: String = ""

    static let all: [AIPreset] = [
        AIPreset(id: "anthropic", name: "Anthropic (Claude)", kind: .anthropic,
                 baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-5",
                 hint: "Ключ — console.anthropic.com."),
        AIPreset(id: "openai", name: "OpenAI", kind: .openAI,
                 baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
                 hint: "Ключ — platform.openai.com."),
        AIPreset(id: "openrouter", name: "OpenRouter", kind: .openAI,
                 baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini",
                 hint: "Сотни моделей по одному ключу — openrouter.ai."),
        AIPreset(id: "deepseek", name: "DeepSeek", kind: .openAI,
                 baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        AIPreset(id: "mistral", name: "Mistral", kind: .openAI,
                 baseURL: "https://api.mistral.ai/v1", model: "mistral-small-latest"),
        AIPreset(id: "groq", name: "Groq", kind: .openAI,
                 baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
        AIPreset(id: "vllm", name: "vLLM (свой сервер)", kind: .openAI,
                 baseURL: "http://localhost:8000/v1", model: "", keyOptional: true,
                 hint: "Адрес сервера с `vllm serve …`; ключ — если запущен с --api-key. Модель подтянется кнопкой «Загрузить список»."),
        AIPreset(id: "ollama", name: "Ollama", kind: .openAI,
                 baseURL: "http://localhost:11434/v1", model: "", keyOptional: true,
                 hint: "Ollama на этом Mac или в сети. Ключ не нужен."),
        AIPreset(id: "lmstudio", name: "LM Studio", kind: .openAI,
                 baseURL: "http://localhost:1234/v1", model: "", keyOptional: true,
                 hint: "Включите сервер в LM Studio (Developer → Start Server)."),
        AIPreset(id: "custom", name: "Другой, совместимый с OpenAI", kind: .openAI,
                 baseURL: "https://", model: "", keyOptional: true,
                 hint: "Любой сервис с API /v1/chat/completions."),
    ]

    func makeConnection() -> AIConnection {
        var connection = AIConnection(name: name, kind: kind, baseURL: baseURL, model: model)
        connection.redact = !keyOptional
        return connection
    }
}

enum AIRequestError: LocalizedError, Equatable {
    case badURL
    case noKey
    case http(Int, String?)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badURL: "Неверный адрес API."
        case .noKey: "Не указан API-ключ."
        case .http(let code, let message): Self.describe(code: code, message: message)
        case .network(let text): "Нет связи с сервером модели: \(text)"
        case .badResponse: "Сервер модели вернул непонятный ответ."
        }
    }

    private static func describe(code: Int, message: String?) -> String {
        let base: String
        switch code {
        case 400: base = "Запрос отклонён (400). Проверьте название модели."
        case 401: base = "Неверный API-ключ (401)."
        case 403: base = "У ключа нет доступа к этой модели (403)."
        case 404: base = "Не найдено (404): проверьте адрес API (обычно оканчивается на /v1) и название модели."
        case 413: base = "Тред слишком длинный для модели (413)."
        case 429: base = "Слишком много запросов или исчерпан лимит (429). Попробуйте позже."
        case 500...599: base = "Сервер модели временно недоступен (\(code))."
        default: base = "Ошибка API (\(code))."
        }
        guard let message, !message.isEmpty else { return base }
        return "\(base)\n\(message)"
    }
}

/// Запросы и разбор ответов для обоих протоколов. Без состояния — проверяется на Linux.
enum AIWire {
    /// `https://api.anthropic.com` или `…/v1` → `…/v1/messages`.
    static func anthropicURL(_ base: String, path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.hasSuffix("/v1") { trimmed += "/v1" }
        return URL(string: trimmed + "/" + path)
    }

    /// `http://host:8000/v1` → `…/v1/chat/completions`. Адрес без /v1 тоже принимается.
    static func openAIURL(_ base: String, path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") { trimmed.removeLast("/chat/completions".count) }
        let hasVersion = trimmed.range(of: #"/v\d+(beta)?$"#, options: .regularExpression) != nil
            || trimmed.hasSuffix("/openai") || trimmed.contains("/api/v")
        if !hasVersion { trimmed += "/v1" }
        return URL(string: trimmed + "/" + path)
    }

    static func completionRequest(_ connection: AIConnection, key: String?, system: String, user: String,
                                  maxTokens: Int? = nil) throws -> URLRequest {
        let tokens = maxTokens ?? connection.maxTokens
        let url: URL?
        var body: [String: Any]
        switch connection.kind {
        case .anthropic:
            url = anthropicURL(connection.baseURL, path: "messages")
            body = ["model": connection.model, "max_tokens": tokens, "system": system,
                    "messages": [["role": "user", "content": user]]]
        case .openAI:
            url = openAIURL(connection.baseURL, path: "chat/completions")
            body = ["model": connection.model, "max_tokens": tokens, "temperature": 0.3, "stream": false,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        guard let url else { throw AIRequestError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = connection.isLocal ? 300 : 90
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        applyAuth(&request, connection: connection, key: key)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func modelsRequest(_ connection: AIConnection, key: String?) throws -> URLRequest {
        let url = connection.kind == .anthropic
            ? anthropicURL(connection.baseURL, path: "models")
            : openAIURL(connection.baseURL, path: "models")
        guard let url else { throw AIRequestError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        applyAuth(&request, connection: connection, key: key)
        return request
    }

    private static func applyAuth(_ request: inout URLRequest, connection: AIConnection, key: String?) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch connection.kind {
        case .anthropic:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            if connection.baseURL.contains("openrouter.ai") {
                request.setValue("UniMail", forHTTPHeaderField: "X-Title")
            }
        }
    }

    /// Текст ответа модели. Рассуждения моделей вроде Qwen/DeepSeek-R1 (`<think>…</think>`) отбрасываются.
    static func completionText(_ data: Data, kind: AIProtocol) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIRequestError.badResponse
        }
        var text: String?
        switch kind {
        case .anthropic:
            let blocks = json["content"] as? [[String: Any]] ?? []
            text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .openAI:
            let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            if let content = message?["content"] as? String {
                text = content
            } else if let parts = message?["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
        }
        let cleaned = stripThinking(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw AIRequestError.badResponse }
        return cleaned
    }

    static func stripThinking(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?s)<think>.*?(</think>|$)"#) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Сообщение об ошибке из тела ответа: `{"error":{"message":…}}`, `{"error":"…"}`, `{"detail":…}`, `{"message":…}`.
    static func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        if let detail = json["detail"] as? String { return detail }
        if let message = json["message"] as? String { return message }
        return nil
    }

    /// Идентификаторы моделей из `GET /models` (OpenAI, vLLM, Ollama, LM Studio, Anthropic).
    static func modelIDs(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let items = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        return items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
    }
}
