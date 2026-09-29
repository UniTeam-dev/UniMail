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
/// HTTPS до EWS. Вход — тем способом, который предложит сервер: Basic, NTLM или Kerberos (Negotiate);
/// URLSession делает рукопожатие сама, мы только отдаём логин и пароль.
final class EWSHTTPTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let url: URL
    private let username: String
    private let password: String
    private lazy var session: URLSession = {
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("UniMail/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorUserCancelledAuthentication {
                throw EWSError.unauthorized
            }
            throw MailProviderError.network("EWS \(url.host ?? "") — \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        switch method {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodNTLM,
             NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault:
            // Одна попытка на способ: неверный пароль не должен крутиться по кругу.
            if challenge.previousFailureCount > 0 {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func close() {
        session.invalidateAndCancel()
    }
}
#endif
