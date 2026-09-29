import Foundation

enum SMTPError: LocalizedError, Equatable {
    /// Сервер ответил кодом 4xx/5xx (или неожиданным кодом).
    case rejected(code: Int, message: String)
    /// Неверный логин/пароль (535) или сервер не принял аутентификацию.
    case authenticationFailed(String)
    /// Нарушение протокола: нечитаемый ответ, нет нужного расширения и т.п.
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(code, message): "Сервер отклонил команду (\(code)): \(message)"
        case let .authenticationFailed(message): "Не удалось войти: \(message)"
        case let .unexpected(message): "Ошибка SMTP: \(message)"
        }
    }
}

/// Ответ SMTP-сервера: код и строки текста (без «250-»).
struct SMTPReply: Sendable, Equatable {
    var code: Int
    var lines: [String]
    var message: String { lines.joined(separator: "\n") }
    var isPositive: Bool { (200..<400).contains(code) }
}

/// SMTP-клиент (RFC 5321) поверх `MailTransport`: EHLO, STARTTLS, AUTH PLAIN/LOGIN/XOAUTH2,
/// MAIL/RCPT/DATA с dot-stuffing.
actor SMTPClient {
    private let transport: MailTransport
    private var reader: LineReader
    private let heloName: String

    /// Расширения из последнего EHLO: ключевые слова в верхнем регистре ("STARTTLS", "8BITMIME", "SIZE",
    /// "AUTH", "PIPELINING"…) и механизмы в виде "AUTH=PLAIN", "AUTH=LOGIN".
    private(set) var capabilities: Set<String> = []
    /// Механизмы AUTH из EHLO (в верхнем регистре).
    private(set) var authMechanisms: Set<String> = []
    /// Лимит SIZE из EHLO, если сервер его объявил.
    private(set) var maxMessageSize: Int?

    init(transport: MailTransport, heloName: String = "unimail.local") {
        self.transport = transport
        self.reader = LineReader(transport: transport)
        self.heloName = heloName
    }

    /// Читает приветствие 220.
    func connect() async throws {
        let reply = try await readReply()
        guard reply.code == 220 else { throw SMTPError.rejected(code: reply.code, message: reply.message) }
    }

    /// EHLO (при 5xx — HELO). Возвращает множество расширений.
    @discardableResult
    func ehlo() async throws -> Set<String> {
        let reply = try await command("EHLO \(heloName)")
        if reply.code == 250 {
            parseCapabilities(reply)
            return capabilities
        }
        if (500..<600).contains(reply.code) {
            let helo = try await command("HELO \(heloName)")
            guard helo.code == 250 else { throw SMTPError.rejected(code: helo.code, message: helo.message) }
            capabilities = []; authMechanisms = []; maxMessageSize = nil
            return capabilities
        }
        throw SMTPError.rejected(code: reply.code, message: reply.message)
    }

    /// STARTTLS → TLS на транспорте → повторный EHLO (расширения после TLS могут отличаться).
    func startTLS() async throws {
        let reply = try await command("STARTTLS")
        guard reply.code == 220 else { throw SMTPError.rejected(code: reply.code, message: reply.message) }
        try await transport.startTLS()
        // Всё, что пришло до TLS, выбрасываем (защита от STARTTLS command injection).
        reader = LineReader(transport: transport)
        capabilities = []; authMechanisms = []
        try await ehlo()
    }

    /// AUTH PLAIN, если объявлен (или сервер не объявил механизмы), иначе AUTH LOGIN.
    func authenticate(username: String, password: String) async throws {
        if authMechanisms.contains("PLAIN") || !authMechanisms.contains("LOGIN") {
            let token = Data(([0] + Array(username.utf8) + [0] + Array(password.utf8))).base64EncodedString()
            let reply = try await command("AUTH PLAIN \(token)")
            if reply.code == 334 {
                // Сервер хочет данные отдельной строкой (пустой challenge).
                try await finishAuth(try await command(token))
            } else {
                try await finishAuth(reply)
            }
        } else {
            let first = try await command("AUTH LOGIN")
            guard first.code == 334 else { try await finishAuth(first); return }
            let second = try await command(Data(username.utf8).base64EncodedString())
            guard second.code == 334 else { try await finishAuth(second); return }
            try await finishAuth(try await command(Data(password.utf8).base64EncodedString()))
        }
    }

    /// AUTH XOAUTH2 (Gmail, Outlook.com) с OAuth-токеном доступа.
    func authenticateXOAUTH2(username: String, accessToken: String) async throws {
        let raw = "user=\(username)\u{1}auth=Bearer \(accessToken)\u{1}\u{1}"
        let reply = try await command("AUTH XOAUTH2 \(Data(raw.utf8).base64EncodedString())")
        if reply.code == 334 {
            // В challenge — JSON с ошибкой; по протоколу отвечаем пустой строкой и получаем 535.
            _ = try? await command("")
            throw SMTPError.authenticationFailed(decodeChallenge(reply.message))
        }
        try await finishAuth(reply)
    }

    /// Отправка: MAIL FROM, RCPT TO для каждого получателя, DATA с dot-stuffing и завершающим CRLF.CRLF.
    func send(from: String, recipients: [String], data: Data) async throws {
        guard !recipients.isEmpty else { throw SMTPError.unexpected("Нет получателей") }
        if let max = maxMessageSize, max > 0, data.count > max {
            throw SMTPError.rejected(code: 552, message: "Письмо больше лимита сервера (\(max) байт)")
        }
        var mail = "MAIL FROM:<\(from)>"
        if capabilities.contains("SIZE") { mail += " SIZE=\(data.count)" }
        if capabilities.contains("8BITMIME"), data.contains(where: { $0 >= 0x80 }) { mail += " BODY=8BITMIME" }
        let mailReply = try await command(mail)
        guard mailReply.code == 250 else { throw SMTPError.rejected(code: mailReply.code, message: mailReply.message) }

        for rcpt in recipients {
            let r = try await command("RCPT TO:<\(rcpt)>")
            guard r.code == 250 || r.code == 251 else {
                _ = try? await command("RSET")
                throw SMTPError.rejected(code: r.code, message: "\(rcpt): \(r.message)")
            }
        }

        let dataReply = try await command("DATA")
        guard dataReply.code == 354 else {
            _ = try? await command("RSET")
            throw SMTPError.rejected(code: dataReply.code, message: dataReply.message)
        }
        try await transport.write(Self.dotStuff(data))
        let final = try await readReply()
        guard final.code == 250 else { throw SMTPError.rejected(code: final.code, message: final.message) }
    }

    /// QUIT без ошибок наружу и закрытие транспорта.
    func quit() async {
        _ = try? await command("QUIT")
        transport.close()
    }

    /// Произвольная команда (NOOP, RSET…) — для расширений и диагностики.
    func command(_ line: String) async throws -> SMTPReply {
        try await transport.write(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    // MARK: Протокол

    /// Многострочный ответ: «250-…» … «250 …».
    private func readReply() async throws -> SMTPReply {
        var lines: [String] = []
        var code: Int?
        while true {
            let raw = try await reader.readLine()
            let line = String(decoding: raw, as: UTF8.self)
            guard line.count >= 3, let c = Int(line.prefix(3)) else {
                throw SMTPError.unexpected("Неверный ответ сервера: \(line.prefix(200))")
            }
            if code == nil { code = c }
            let sep = line.dropFirst(3).first
            lines.append(line.count > 4 ? String(line.dropFirst(4)) : "")
            if sep != "-" { break }
            if lines.count > 1000 { throw SMTPError.unexpected("Слишком длинный ответ сервера") }
        }
        return SMTPReply(code: code ?? 0, lines: lines)
    }

    private func parseCapabilities(_ reply: SMTPReply) {
        var caps: Set<String> = []
        var mechs: Set<String> = []
        maxMessageSize = nil
        for line in reply.lines.dropFirst() {
            let upper = line.uppercased()
            let parts = upper.split(whereSeparator: { $0 == " " || $0 == "=" }).map(String.init)
            guard let keyword = parts.first else { continue }
            caps.insert(keyword)
            if keyword == "AUTH" {
                for m in parts.dropFirst() { mechs.insert(m); caps.insert("AUTH=\(m)") }
            } else if keyword == "SIZE", parts.count > 1 {
                maxMessageSize = Int(parts[1])
            }
        }
        capabilities = caps
        authMechanisms = mechs
    }

    private func finishAuth(_ reply: SMTPReply) async throws {
        switch reply.code {
        case 235: return
        case 535, 534, 454, 530:
            throw SMTPError.authenticationFailed(reply.message)
        default:
            throw SMTPError.rejected(code: reply.code, message: reply.message)
        }
    }

    private func decodeChallenge(_ s: String) -> String {
        Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) } ?? s
    }

    /// Нормализует переводы строк в CRLF, удваивает точку в начале строк, добавляет «CRLF.CRLF».
    static func dotStuff(_ data: Data) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(data.count + data.count / 50 + 5)
        var atLineStart = true
        var prev: UInt8 = 0
        for b in data {
            if b == 10 && prev != 13 { out.append(13) }   // голый LF → CRLF
            if prev == 13 && b != 10 { out.append(10); atLineStart = true } // голый CR → CRLF
            if atLineStart && b == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(b)
            atLineStart = (b == 10)
            prev = b
        }
        if prev == 13 { out.append(10) }
        if !(out.count >= 2 && out[out.count - 2] == 13 && out[out.count - 1] == 10) && !out.isEmpty {
            out += [13, 10]
        }
        out += Array(".\r\n".utf8)
        return Data(out)
    }
}
