import Foundation

/// Байтовый канал до почтового сервера. На macOS — `StreamTransport` (URLSessionStreamTask),
/// в тестах — `ScriptedTransport`. IMAP и SMTP работают только через этот протокол.
protocol MailTransport: AnyObject, Sendable {
    /// Отправить байты целиком.
    func write(_ data: Data) async throws
    /// Прочитать следующую порцию (≥ 1 байта). Бросает `MailTransportError.closed`, если соединение закрыто.
    func read() async throws -> Data
    /// Включить TLS поверх уже открытого соединения (STARTTLS) или сразу после открытия (неявный TLS).
    func startTLS() async throws
    func close()
}

enum MailTransportError: LocalizedError, Equatable {
    case closed
    case timeout
    case tls(String)
    case connect(String)

    var errorDescription: String? {
        switch self {
        case .closed: "Сервер закрыл соединение"
        case .timeout: "Сервер не отвечает"
        case .tls(let s): "Ошибка TLS: \(s)"
        case .connect(let s): "Не удалось подключиться: \(s)"
        }
    }
}

/// Буфер чтения построчно (CRLF) и блоками фиксированной длины (IMAP-литералы, SMTP-ответы).
final class LineReader: @unchecked Sendable {
    private let transport: MailTransport
    private var buffer = Data()

    init(transport: MailTransport) {
        self.transport = transport
    }

    /// Строка без завершающего CRLF.
    func readLine() async throws -> Data {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return line
            }
            buffer.append(try await transport.read())
        }
    }

    /// Ровно `count` байт.
    func readExactly(_ count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await transport.read())
        }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }
}

/// Транспорт для тестов: отдаёт заранее записанные ответы сервера и запоминает, что клиент отправил.
/// `responder` получает отправленную клиентом строку и возвращает то, что «сервер» ответит.
final class ScriptedTransport: MailTransport, @unchecked Sendable {
    private var pending = Data()
    private(set) var sent: [String] = []
    private(set) var tlsStarted = false
    private let responder: (String) -> String?
    private let lock = NSLock()

    init(greeting: String, responder: @escaping (String) -> String?) {
        self.pending = Data(greeting.utf8)
        self.responder = responder
    }

    func write(_ data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            sent.append(text)
            if let reply = responder(text) { pending.append(Data(reply.utf8)) }
        }
    }

    func read() async throws -> Data {
        for _ in 0..<200 {
            let chunk: Data? = lock.withLock {
                guard !pending.isEmpty else { return nil }
                let chunk = pending.prefix(7) // маленькие порции — проверяем склейку буфера
                pending.removeFirst(chunk.count)
                return Data(chunk)
            }
            if let chunk { return chunk }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw MailTransportError.timeout
    }

    func startTLS() async throws { tlsStarted = true }
    func close() {}
}
