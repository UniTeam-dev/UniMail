import Foundation

/// Асинхронный мьютекс: IMAP-соединение одно, а операции (синхронизация папки, скачивание тела,
/// действия) не должны перемешиваться между SELECT разных папок.
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Как открыть соединение: хост, порт, неявный TLS (993/465) или открытый канал под STARTTLS.
typealias TransportFactory = @Sendable (_ host: String, _ port: Int, _ implicitTLS: Bool, _ readTimeout: TimeInterval) async throws -> MailTransport

#if canImport(Darwin)
/// Транспорт на URLSessionStreamTask: умеет и неявный TLS, и STARTTLS посреди соединения.
final class StreamTransport: MailTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private let readTimeout: TimeInterval

    private init(session: URLSession, task: URLSessionStreamTask, readTimeout: TimeInterval) {
        self.session = session
        self.task = task
        self.readTimeout = readTimeout
    }

    static let factory: TransportFactory = { host, port, implicitTLS, readTimeout in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)
        let task = session.streamTask(withHostName: host, port: port)
        task.resume()
        if implicitTLS {
            task.startSecureConnection()
        }
        return StreamTransport(session: session, task: task, readTimeout: readTimeout)
    }

    func write(_ data: Data) async throws {
        do {
            try await task.write(data, timeout: 60)
        } catch {
            throw MailTransportError.connect(error.localizedDescription)
        }
    }

    func read() async throws -> Data {
        while true {
            let (data, atEOF): (Data?, Bool)
            do {
                (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: readTimeout)
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut { throw MailTransportError.timeout }
                if ns.domain == NSURLErrorDomain && (ns.code == NSURLErrorSecureConnectionFailed
                    || ns.code == NSURLErrorServerCertificateUntrusted
                    || ns.code == NSURLErrorServerCertificateHasBadDate
                    || ns.code == NSURLErrorServerCertificateHasUnknownRoot) {
                    throw MailTransportError.tls(error.localizedDescription)
                }
                throw MailTransportError.connect(error.localizedDescription)
            }
            if let data, !data.isEmpty { return data }
            if atEOF { throw MailTransportError.closed }
        }
    }

    func startTLS() async throws {
        task.startSecureConnection()
    }

    func close() {
        task.closeWrite()
        task.closeRead()
        task.cancel()
        session.invalidateAndCancel()
    }
}
#endif
