import Foundation
import Observation

/// Сводка треда и черновик ответа: Anthropic, любой сервис с API OpenAI (OpenAI, OpenRouter, DeepSeek…)
/// или своя модель на vLLM / Ollama / LM Studio.
///
/// Выключено по умолчанию (`aiEnabled`). Подключений может быть несколько, работает одно — активное.
/// Ключи — в Связке ключей. Перед отправкой адреса почты и номера телефонов заменяются на `[email]`
/// и `[телефон]` (для своих серверов это можно выключить).
@MainActor
@Observable
final class AIService {
    static let shared = AIService()

    /// Старый ключ Anthropic (до появления подключений) — переносится в первое подключение.
    static let keychainKey = "anthropic-api-key"
    private static let connectionsKey = "aiConnections"
    private static let activeKey = "aiActiveConnection"
    /// Ограничение на объём текста треда, который уходит в модель.
    private static let maxCharactersPerMessage = 6_000
    private static let maxCharactersTotal = 24_000

    enum AIError: LocalizedError {
        case disabled
        case noConnection
        case emptyThread

        var errorDescription: String? {
            switch self {
            case .disabled: "AI-функции выключены. Включите их в Настройках → Интеграции."
            case .noConnection: "Не выбрана модель. Добавьте подключение в Настройках → Интеграции."
            case .emptyThread: "В треде нет текста для обработки."
            }
        }
    }

    /// Подключения к моделям и активное из них.
    var connections: [AIConnection] = [] {
        didSet { saveConnections() }
    }
    var activeID: UUID? {
        didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: Self.activeKey) }
    }

    var active: AIConnection? {
        connections.first { $0.id == activeID } ?? connections.first
    }

    /// Кэш сводок: подключение + тред + число писем → текст (чтобы не платить повторно при переключении тредов).
    private var summaryCache: [String: String] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }()

    private init() {
        loadConnections()
    }

    // MARK: Подключения

    private func loadConnections() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.connectionsKey),
           let saved = try? JSONDecoder().decode([AIConnection].self, from: data) {
            connections = saved
            activeID = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:)) ?? saved.first?.id
            return
        }
        // Первый запуск новой версии: прежняя настройка Anthropic становится первым подключением.
        var anthropic = AIPreset.all[0].makeConnection()
        anthropic.model = AppSettings.model
        if let oldKey = Keychain.get(Self.keychainKey), !oldKey.isEmpty {
            try? Keychain.set(oldKey, for: anthropic.keychainAccount)
        }
        connections = [anthropic]
        activeID = anthropic.id
    }

    private func saveConnections() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: Self.connectionsKey)
        }
    }

    @discardableResult
    func add(_ preset: AIPreset) -> AIConnection {
        let connection = preset.makeConnection()
        connections.append(connection)
        if connections.count == 1 { activeID = connection.id }
        return connection
    }

    func update(_ connection: AIConnection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        summaryCache.removeAll()
    }

    func remove(_ id: UUID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        Keychain.remove(connection.keychainAccount)
        connections.removeAll { $0.id == id }
        if activeID == id { activeID = connections.first?.id }
    }

    func activate(_ id: UUID) {
        activeID = id
        summaryCache.removeAll()
    }

    // MARK: Ключи

    var isEnabled: Bool { AppSettings.bool(AppSettings.aiEnabled) }
    /// Название модели активного подключения — для подписи в интерфейсе.
    var model: String { active?.model ?? "" }

    func key(for connection: AIConnection) -> String? {
        Keychain.get(connection.keychainAccount)
    }

    func saveKey(_ key: String, for connection: AIConnection) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.remove(connection.keychainAccount)
        } else {
            try Keychain.set(trimmed, for: connection.keychainAccount)
        }
    }

    /// Последние 4 символа сохранённого ключа — для подписи «Сохранён ••••abcd».
    func maskedKey(for connection: AIConnection) -> String? {
        guard let key = key(for: connection), key.count >= 4 else { return nil }
        return "••••" + key.suffix(4)
    }

    /// Список моделей сервера (`GET /v1/models`) — для vLLM, Ollama, LM Studio, OpenAI, Anthropic.
    func listModels(_ connection: AIConnection) async throws -> [String] {
        let request = try AIWire.modelsRequest(connection, key: key(for: connection))
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else { throw AIRequestError.http(status, AIWire.errorMessage(data)) }
        let ids = AIWire.modelIDs(data)
        guard !ids.isEmpty else { throw AIRequestError.badResponse }
        return ids
    }

    // MARK: Функции

    private func cacheKey(_ threadID: String, _ count: Int) -> String {
        "\(activeID?.uuidString ?? "")#\(threadID)#\(count)"
    }

    func cachedSummary(threadID: String, messageCount: Int) -> String? {
        summaryCache[cacheKey(threadID, messageCount)]
    }

    /// Сбросить сохранённую сводку (кнопка «Пересказать заново»).
    func forgetSummary(threadID: String, messageCount: Int) {
        summaryCache[cacheKey(threadID, messageCount)] = nil
    }

    /// Краткая сводка переписки на русском.
    func summarize(thread: [Message]) async throws -> String {
        let key = thread.first.map { cacheKey($0.threadID, thread.count) }
        if let key, let cached = summaryCache[key] { return cached }
        let transcript = Self.transcript(thread, redact: active?.redact ?? true)
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
        let transcript = Self.transcript(thread, redact: active?.redact ?? true)
        guard !transcript.isEmpty else { throw AIError.emptyThread }

        let system = """
        Ты — помощник в почтовом клиенте UniMail. Напиши черновик ответа от имени пользователя \
        на последнее письмо в переписке.
        Пиши на языке переписки (по умолчанию — по-русски), вежливо и по делу, в тоне собеседника.
        Выдай только текст письма: без темы, без подписи и без цитирования исходного письма.
        Не выдумывай факты, даты и обещания — если чего-то не хватает, оставь [уточнить].
        Персональные данные в тексте заменены на [email] и [телефон] — не пытайся их восстановить.
        """
        let rawWish = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let wish = (active?.redact ?? true) ? Self.redact(rawWish) : rawWish
        var user = "Переписка:\n\n\(transcript)"
        if !wish.isEmpty { user += "\n\nПожелание к ответу: \(wish)" }
        return try await complete(system: system, user: user)
    }

    /// Проверка подключения коротким запросом (по умолчанию — активного).
    func testConnection(_ connection: AIConnection? = nil) async throws -> String {
        try await complete(system: "Отвечай одним словом.", user: "Скажи «работает».",
                           maxTokens: 64, requireEnabled: false, connection: connection)
    }

    // MARK: Запрос

    private func complete(system: String, user: String, maxTokens: Int? = nil,
                          requireEnabled: Bool = true, connection: AIConnection? = nil) async throws -> String {
        if requireEnabled && !isEnabled { throw AIError.disabled }
        guard let connection = connection ?? active else { throw AIError.noConnection }
        let key = key(for: connection)
        if connection.kind == .anthropic && (key ?? "").isEmpty { throw AIRequestError.noKey }
        let request = try AIWire.completionRequest(connection, key: key, system: system, user: user, maxTokens: maxTokens)
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else { throw AIRequestError.http(status, AIWire.errorMessage(data)) }
        return try AIWire.completionText(data, kind: connection.kind)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw AIRequestError.network(error.localizedDescription)
        }
    }

    // MARK: Подготовка текста

    /// Тред в виде простого текста: отправитель (только имя), дата, текст письма. Адреса и телефоны замаскированы.
    static func transcript(_ thread: [Message], redact shouldRedact: Bool = true) -> String {
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
            parts.append(shouldRedact ? redact(block) : block)
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
