import AppKit
import Foundation

/// Письмо-запрос на отписку (List-Unsubscribe: <mailto:…>), которое нужно отправить от имени ящика.
struct UnsubscribeMail: Hashable, Sendable {
    var to: Address
    var subject: String
    var body: String

    /// Готовый черновик для `MailStore.send(_:requestID:)`.
    func outgoingMessage(accountID: UUID, fromAddress: String) -> OutgoingMessage {
        OutgoingMessage(
            accountID: accountID,
            fromAddress: fromAddress,
            to: [to],
            cc: [],
            bcc: [],
            subject: subject,
            body: body
        )
    }
}

/// Способы отписки, найденные в заголовках письма.
struct UnsubscribeOptions: Hashable, Sendable {
    /// https-ссылка для RFC 8058 one-click (есть List-Unsubscribe-Post).
    var oneClick: URL?
    var mailto: URL?
    var web: URL?

    var isEmpty: Bool { oneClick == nil && mailto == nil && web == nil }
}

/// Отписка от рассылки: RFC 8058 one-click POST, письмо на mailto: или ссылка в браузере.
@MainActor
final class UnsubscribeService {
    static let shared = UnsubscribeService()

    enum Outcome: Equatable {
        /// Сервер принял one-click запрос.
        case unsubscribed
        /// Нужно отправить письмо: интегратор отправляет `mail.outgoingMessage(...)` через `MailStore.send`.
        case sendEmail(UnsubscribeMail)
        /// Открыта страница отписки в браузере.
        case openedInBrowser(URL)
    }

    enum UnsubscribeError: LocalizedError {
        case notAvailable
        case server(Int)
        case network(String)
        case cannotOpen

        var errorDescription: String? {
            switch self {
            case .notAvailable: "В письме нет ссылки для отписки."
            case .server(let code): "Сервер рассылки ответил ошибкой \(code). Попробуйте отписаться по ссылке в письме."
            case .network(let text): "Не удалось связаться с сервером рассылки: \(text)"
            case .cannotOpen: "Не удалось открыть ссылку для отписки."
            }
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // RFC 8058: запрос не должен нести cookies и прочий контекст пользователя.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: Разбор заголовков

    func canUnsubscribe(_ message: Message) -> Bool {
        !options(for: message).isEmpty
    }

    /// `List-Unsubscribe: <mailto:u@list.ru?subject=unsubscribe>, <https://list.ru/u?id=1>`
    func options(for message: Message) -> UnsubscribeOptions {
        guard let header = message.listUnsubscribe, !header.isEmpty else { return UnsubscribeOptions() }
        var result = UnsubscribeOptions()
        for url in Self.parseURLs(header) {
            switch url.scheme?.lowercased() {
            case "mailto":
                if result.mailto == nil { result.mailto = url }
            case "https":
                if message.listUnsubscribePost == true, result.oneClick == nil { result.oneClick = url }
                if result.web == nil { result.web = url }
            case "http":
                if result.web == nil { result.web = url }
            default:
                break
            }
        }
        return result
    }

    static func parseURLs(_ header: String) -> [URL] {
        var raw: [String] = []
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<"),
              let close = rest[open...].firstIndex(of: ">") {
            raw.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        if raw.isEmpty {
            raw = header.split(separator: ",").map(String.init)
        }
        return raw.compactMap { item in
            let cleaned = item
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            return URL(string: cleaned)
        }
    }

    // MARK: Отписка

    /// Отписывается лучшим доступным способом: one-click POST → mailto → браузер.
    /// При ошибке one-click пробует mailto или браузер.
    func unsubscribe(_ message: Message) async throws -> Outcome {
        let options = self.options(for: message)
        guard !options.isEmpty else { throw UnsubscribeError.notAvailable }

        if let url = options.oneClick {
            do {
                try await oneClick(url)
                return .unsubscribed
            } catch {
                if options.mailto == nil && options.web == nil { throw error }
            }
        }
        if let mailto = options.mailto, let mail = Self.mail(from: mailto) {
            return .sendEmail(mail)
        }
        if let web = options.web {
            guard NSWorkspace.shared.open(web) else { throw UnsubscribeError.cannotOpen }
            return .openedInBrowser(web)
        }
        throw UnsubscribeError.notAvailable
    }

    /// То же, но письмо-отписка сразу уходит через `MailStore.send` (с окном «Отменить»).
    func unsubscribe(_ message: Message, store: MailStore) async throws -> Outcome {
        let outcome = try await unsubscribe(message)
        if case .sendEmail(let mail) = outcome, let account = store.account(message.accountID) {
            let draft = mail.outgoingMessage(accountID: account.id, fromAddress: account.email)
            store.send(draft, requestID: UUID(), undoTitle: "Запрос на отписку отправляется…")
        }
        return outcome
    }

    /// RFC 8058: POST на https-адрес с телом `List-Unsubscribe=One-Click`.
    func oneClick(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)

        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            response = result.1
        } catch {
            throw UnsubscribeError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UnsubscribeError.server(0) }
        guard (200..<400).contains(http.statusCode) else { throw UnsubscribeError.server(http.statusCode) }
    }

    /// mailto:list@host?subject=unsubscribe&body=… → письмо.
    static func mail(from url: URL) -> UnsubscribeMail? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let address = components.path.removingPercentEncoding ?? components.path
        guard !address.isEmpty else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }
        let subject = value("subject").flatMap { $0.isEmpty ? nil : $0 } ?? "unsubscribe"
        let body = value("body") ?? "unsubscribe"
        return UnsubscribeMail(to: Address(name: nil, email: address), subject: subject, body: body)
    }
}
