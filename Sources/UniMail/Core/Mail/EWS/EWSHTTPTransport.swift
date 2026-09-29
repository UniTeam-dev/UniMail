import Foundation

/// Адрес EWS по имени сервера: `mail.example.com` → `https://mail.example.com/EWS/Exchange.asmx`.
enum EWSEndpoint {
    static func url(for server: String) -> URL? {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http") { return URL(string: trimmed) }
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        return URL(string: "https://\(host)/EWS/Exchange.asmx")
    }
}

#if canImport(Darwin)
/// HTTPS до EWS.
///
/// Вход: сначала Basic с заголовком в самом запросе (работает и по HTTP/2, где NTLM у IIS ломается),
/// если сервер его не принял — NTLM через URLSession. Kerberos не пробуем: паролем он почти никогда
/// не проходит, а лишняя неудачная попытка приближает блокировку учётки в AD.
/// Сработавший способ запоминается; при отказе обоих — ошибка с отчётом, что пробовали.
final class EWSHTTPTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Method: String { case basic = "Basic", ntlm = "NTLM" }

    private let url: URL
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var working: Method?
    /// Сервер уже отказал с этим паролем — больше не стучимся (иначе опрос раз в минуту заблокирует учётку в AD).
    /// Сбрасывается новым паролем: MailStore пересоздаёт транспорт.
    private var rejected: String?

    /// Basic: без делегата и хранилища паролей — на 401 URLSession просто вернёт ответ.
    private lazy var basicSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// NTLM: рукопожатие делает URLSession, делегат отдаёт логин и пароль.
    private lazy var ntlmSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(url: URL, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    func post(_ body: Data) async throws -> (status: Int, body: Data) {
        if let rejected = lock.withLock({ rejected }) { throw EWSError.unauthorized(rejected) }
        let known = lock.withLock { working }
        switch known {
        case .basic:
            return try await send(body, method: .basic)
        case .ntlm:
            return try await send(body, method: .ntlm)
        case nil:
            var report: [String] = []
            for method in [Method.basic, .ntlm] {
                let result = try await send(body, method: method)
                if result.status != 401 {
                    if (200..<300).contains(result.status) { lock.withLock { working = method } }
                    return result
                }
                report.append("\(method.rawValue) → 401")
            }
            let detail = report.joined(separator: ", ") + " (логин «\(username)»)"
            lock.withLock { rejected = detail }
            throw EWSError.unauthorized(detail)
        }
    }

    private func send(_ body: Data, method: Method) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("UniMail/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if method == .basic {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let session = method == .basic ? basicSession : ntlmSession
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain
                && (ns.code == NSURLErrorUserCancelledAuthentication || ns.code == NSURLErrorCancelled) {
                return (401, Data())
            }
            throw MailProviderError.network("EWS \(url.host ?? "") — \(error.localizedDescription)")
        }
    }

    /// Только NTLM и одна попытка: Negotiate и Basic в этой сессии отклоняем, чтобы URLSession перешла к NTLM.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        switch method {
        case NSURLAuthenticationMethodNTLM:
            if challenge.previousFailureCount > 0 {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
            }
        case NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault:
            completionHandler(.rejectProtectionSpace, nil)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func close() {
        basicSession.invalidateAndCancel()
        ntlmSession.invalidateAndCancel()
    }
}
#endif
