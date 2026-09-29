import Foundation

/// Сводка треда и черновик ответа через Anthropic Messages API на ключе пользователя.
///
/// Выключено по умолчанию (`aiEnabled`). Ключ хранится в Keychain под именем `anthropic-api-key`.
/// Перед отправкой адреса почты и номера телефонов в тексте заменяются на `[email]` и `[телефон]`.
@MainActor
final class AIService {
    static let shared = AIService()

    static let keychainKey = "anthropic-api-key"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    private static let maxTokens = 600
    /// Ограничение на объём текста треда, который уходит в модель.
    private static let maxCharactersPerMessage = 6_000
    private static let maxCharactersTotal = 24_000

    enum AIError: LocalizedError {
        case disabled
        case noKey
        case emptyThread
        case http(Int, String?)
        case network(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .disabled:
                "AI-функции выключены. Включите их в Настройках → Интеграции."
            case .noKey:
                "Не указан API-ключ Anthropic. Добавьте его в Настройках → Интеграции."
            case .emptyThread:
                "В треде нет текста для обработки."
            case .http(let code, let message):
                Self.describe(code: code, message: message)
            case .network(let text):
                "Нет связи с Anthropic API: \(text)"
            case .badResponse:
                "Anthropic API вернул непонятный ответ."
            }
        }

        private static func describe(code: Int, message: String?) -> String {
            let base: String
            switch code {
            case 400: base = "Запрос отклонён (400). Проверьте название модели."
            case 401: base = "Неверный API-ключ (401)."
            case 403: base = "У ключа нет доступа к этой модели (403)."
            case 404: base = "Модель не найдена (404). Проверьте название модели."
            case 413: base = "Тред слишком длинный для модели (413)."
            case 429: base = "Слишком много запросов или исчерпан лимит (429). Попробуйте позже."
            case 500...599: base = "Сервис Anthropic временно недоступен (\(code)). Попробуйте позже."
            default: base = "Ошибка Anthropic API (\(code))."
            }
            guard let message, !message.isEmpty else { return base }
            return "\(base)\n\(message)"
        }
    }

    /// Кэш сводок: тред + число писем → текст (чтобы не платить повторно при переключении тредов).
    private var summaryCache: [String: String] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: Настройки

    var isEnabled: Bool { AppSettings.bool(AppSettings.aiEnabled) }
    var model: String { AppSettings.model }
    var hasAPIKey: Bool { !(Keychain.get(Self.keychainKey) ?? "").isEmpty }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.remove(Self.keychainKey)
        } else {
            try Keychain.set(trimmed, for: Self.keychainKey)
        }
    }

    func removeAPIKey() {
        Keychain.remove(Self.keychainKey)
    }

    /// Последние 4 символа сохранённого ключа — для подписи «Сохранён ••••abcd».
    var maskedKey: String? {
        guard let key = Keychain.get(Self.keychainKey), key.count >= 4 else { return nil }
        return "••••" + key.suffix(4)
    }

    // MARK: Функции

    func cachedSummary(threadID: String, messageCount: Int) -> String? {
        summaryCache["\(threadID)#\(messageCount)"]
    }

    /// Сбросить сохранённую сводку (кнопка «Пересказать заново»).
    func forgetSummary(threadID: String, messageCount: Int) {
        summaryCache["\(threadID)#\(messageCount)"] = nil
    }

    /// Краткая сводка переписки на русском.
    func summarize(thread: [Message]) async throws -> String {
        let key = thread.first.map { "\($0.threadID)#\(thread.count)" }
        if let key, let cached = summaryCache[key] { return cached }
        let transcript = Self.transcript(thread)
        guard !transcript.isEmpty else { throw AIError.emptyThread }

        let system = """
        Ты — помощник в почтовом клиенте UniMail. Тебе дают переписку (тред) по электронной почте.
        Кратко перескажи её на русском языке: 2–4 пункта по сути, без приветствий и воды.
        Если из переписки следует, что от пользователя чего-то ждут (ответ, решение, срок), \
        добавь в конце строку «Что нужно сделать: …». Сроки и суммы сохраняй точно.
        Персональные данные в тексте заменены на [email] и [телефон] — не пытайся их восстановить.
        Отвечай простым текстом без Markdown-заголовков.
        """
        let result = try await complete(system: system, user: "Переписка:\n\n\(transcript)")
        if let key { summaryCache[key] = result }
        return result
    }

    /// Черновик ответа на последнее письмо треда.
    /// - Parameter instruction: пожелание пользователя («вежливо отказать», «согласиться на вторник»); может быть пустым.
    func draftReply(thread: [Message], instruction: String) async throws -> String {
        let transcript = Self.transcript(thread)
        guard !transcript.isEmpty else { throw AIError.emptyThread }

        let system = """
        Ты — помощник в почтовом клиенте UniMail. Напиши черновик ответа от имени пользователя \
        на последнее письмо в переписке.
        Пиши на языке переписки (по умолчанию — по-русски), вежливо и по делу, в тоне собеседника.
        Выдай только текст письма: без темы, без подписи и без цитирования исходного письма.
        Не выдумывай факты, даты и обещания — если чего-то не хватает, оставь [уточнить].
        Персональные данные в тексте заменены на [email] и [телефон] — не пытайся их восстановить.
        """
        let wish = Self.redact(instruction.trimmingCharacters(in: .whitespacesAndNewlines))
        var user = "Переписка:\n\n\(transcript)"
        if !wish.isEmpty { user += "\n\nПожелание к ответу: \(wish)" }
        return try await complete(system: system, user: user)
    }

    /// Проверка ключа и модели коротким запросом.
    func testConnection() async throws -> String {
        let reply = try await complete(
            system: "Отвечай одним словом.",
            user: "Скажи «работает».",
            maxTokens: 16,
            requireEnabled: false
        )
        return reply
    }

    // MARK: Запрос

    private struct RequestBody: Encodable {
        struct Item: Encodable {
            var role: String
            var content: String
        }
        var model: String
        var max_tokens: Int
        var system: String
        var messages: [Item]
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            var type: String?
            var message: String?
        }
        var error: Detail?
    }

    private func complete(system: String, user: String, maxTokens: Int? = nil,
                          requireEnabled: Bool = true) async throws -> String {
        if requireEnabled && !isEnabled { throw AIError.disabled }
        guard let apiKey = Keychain.get(Self.keychainKey), !apiKey.isEmpty else { throw AIError.noKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            max_tokens: maxTokens ?? Self.maxTokens,
            system: system,
            messages: [.init(role: "user", content: user)]
        ))

        let data: Data
        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            data = result.0
            response = result.1
        } catch {
            throw AIError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
            throw AIError.http(http.statusCode, message)
        }
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else { throw AIError.badResponse }
        let text = body.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.badResponse }
        return text
    }

    // MARK: Подготовка текста

    /// Тред в виде простого текста: отправитель (только имя), дата, текст письма. Адреса и телефоны замаскированы.
    static func transcript(_ thread: [Message]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"

        var parts: [String] = []
        var total = 0
        // Свежие письма важнее: идём с конца и отбрасываем самые старые, если не помещается.
        for message in thread.sorted(by: { $0.date > $1.date }) {
            var text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, let html = message.htmlBody { text = plainText(fromHTML: html) }
            text = stripQuotes(text)
            if text.count > maxCharactersPerMessage { text = String(text.prefix(maxCharactersPerMessage)) + "…" }
            let sender = message.from.name?.isEmpty == false ? message.from.name! : "[email]"
            let block = "От: \(sender)\nДата: \(formatter.string(from: message.date))\nТема: \(message.subject)\n\n\(text)"
            if total + block.count > maxCharactersTotal && !parts.isEmpty { break }
            total += block.count
            parts.append(redact(block))
        }
        return parts.reversed().joined(separator: "\n\n———\n\n")
    }

    /// Убирает процитированные строки «> …» — они дублируют предыдущие письма треда.
    private static func stripQuotes(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            (#"(?is)<(script|style|head)\b.*?</\1>"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(p|div|tr|li|h[1-6])>"#, "\n"),
            (#"(?s)<[^>]+>"#, ""),
            (#"\n{3,}"#, "\n\n"),
        ]
        for (pattern, template) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let emailRegex = try? NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    )
    private static let phoneRegex = try? NSRegularExpression(
        pattern: #"(?<![\w+])\+?\d[\d\s\-().]{7,}\d(?!\w)"#
    )

    /// Маскирует адреса почты и номера телефонов (10–15 цифр; даты и короткие коды не трогает).
    static func redact(_ text: String) -> String {
        var result = text
        if let emailRegex {
            result = emailRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[email]"
            )
        }
        guard let phoneRegex else { return result }
        let ns = result as NSString
        let matches = phoneRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
        let mutable = NSMutableString(string: result)
        for match in matches.reversed() {
            let candidate = ns.substring(with: match.range)
            let digits = candidate.filter(\.isNumber).count
            guard (10...15).contains(digits) else { continue }
            mutable.replaceCharacters(in: match.range, with: "[телефон]")
        }
        return mutable as String
    }
}
