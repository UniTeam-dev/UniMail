import Foundation

struct OutgoingAttachment: Sendable {
    var filename: String
    var mimeType: String
    var data: Data
}

/// Исходящее письмо для сборки в RFC 5322/MIME.
struct OutgoingMIME: Sendable {
    var from: Address
    var to: [Address]
    var cc: [Address] = []
    /// Только для конверта SMTP — в заголовки не попадает.
    var bcc: [Address] = []
    var subject: String
    var textBody: String
    var htmlBody: String?
    var attachments: [OutgoingAttachment] = []
    /// Идентификаторы можно передавать со скобками или без — в заголовках всегда `<…>`.
    var messageID: String
    var inReplyTo: String?
    var references: [String] = []
    var date: Date = Date()
    /// Дополнительные заголовки (Reply-To, X-Mailer…). Не-ASCII значения кодируются RFC 2047 целиком,
    /// поэтому адресные заголовки лучше передавать уже отформатированными через `MIMEBuilder.formatAddress`.
    var extraHeaders: [(String, String)] = []
    /// Ответ на приглашение: `("REPLY", ics)` → часть text/calendar; method=REPLY внутри multipart/alternative.
    var calendar: (method: String, ics: String)?
}

/// Сборка письма: CRLF, RFC 2047 для заголовков, RFC 2231 для имён файлов,
/// quoted-printable для текста, base64 (строки по 76) для вложений.
///
/// Структура: text/plain → с HTML или календарём multipart/alternative(text/plain, text/html, text/calendar)
/// → с вложениями всё это оборачивается в multipart/mixed.
enum MIMEBuilder {
    private enum Node {
        case leaf(headers: [(String, String)], body: String)
        case multipart(subtype: String, children: [Node])
    }

    private static let reservedHeaders: Set<String> = [
        "date", "from", "to", "cc", "bcc", "subject", "message-id", "in-reply-to", "references",
        "mime-version", "content-type", "content-transfer-encoding", "content-disposition",
    ]

    static func build(_ m: OutgoingMIME) -> Data {
        var headers: [(String, String)] = []
        headers.append(("Date", formatDate(m.date)))
        headers.append(("From", formatAddress(m.from)))
        if !m.to.isEmpty { headers.append(("To", m.to.map(formatAddress).joined(separator: ", "))) }
        if !m.cc.isEmpty { headers.append(("Cc", m.cc.map(formatAddress).joined(separator: ", "))) }
        headers.append(("Subject", RFC2047.encode(m.subject)))
        headers.append(("Message-ID", "<\(MIMEParser.stripAngles(m.messageID))>"))
        if let irt = m.inReplyTo.map(MIMEParser.stripAngles), !irt.isEmpty {
            headers.append(("In-Reply-To", "<\(irt)>"))
        }
        let refs = m.references.map(MIMEParser.stripAngles).filter { !$0.isEmpty }
        if !refs.isEmpty { headers.append(("References", refs.map { "<\($0)>" }.joined(separator: " "))) }
        headers.append(("MIME-Version", "1.0"))
        for (name, value) in m.extraHeaders where !reservedHeaders.contains(name.lowercased()) {
            let clean = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            // Кодируем только не-ASCII: готовые encoded-words (formatAddress) не трогаем.
            let nonASCII = clean.unicodeScalars.contains { $0.value > 126 }
            headers.append((name, nonASCII ? RFC2047.encode(clean) : clean))
        }

        // Тело.
        var alternatives: [Node] = [textLeaf(m.textBody, subtype: "plain", extra: nil)]
        if let html = m.htmlBody { alternatives.append(textLeaf(html, subtype: "html", extra: nil)) }
        if let cal = m.calendar {
            let method = cal.method.uppercased().filter { $0.isLetter || $0 == "-" }
            alternatives.append(textLeaf(cal.ics, subtype: "calendar", extra: "method=\(method)"))
        }
        var root: Node = alternatives.count == 1 ? alternatives[0] : .multipart(subtype: "alternative", children: alternatives)
        if !m.attachments.isEmpty {
            root = .multipart(subtype: "mixed", children: [root] + m.attachments.map(attachmentLeaf))
        }

        let (rootHeaders, rootBody) = render(root, topLevel: true)
        var out = ""
        for (name, value) in headers + rootHeaders { out += foldHeader(name, value) + "\r\n" }
        out += "\r\n"
        out += rootBody
        if !out.hasSuffix("\r\n") { out += "\r\n" }
        return Data(out.utf8)
    }

    /// Уникальный Message-ID БЕЗ угловых скобок (как их хранит парсер).
    static func makeMessageID(domain: String) -> String {
        let host = domain.isEmpty ? "unimail.local" : domain
        let stamp = String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
        return "\(stamp).\(UUID().uuidString.lowercased())@\(host)"
    }

    // MARK: Адреса и даты

    /// `Имя <email>`: не-ASCII имя — RFC 2047, ASCII со спецсимволами — в кавычках.
    static func formatAddress(_ a: Address) -> String {
        guard let name = a.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return a.email }
        let phrase: String
        if RFC2047.needsEncoding(name) {
            phrase = RFC2047.encode(name)
        } else if name.contains(where: { "()<>[]:;@\\,.\"".contains($0) }) {
            phrase = "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } else {
            phrase = name
        }
        return "\(phrase) <\(a.email)>"
    }

    static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    // MARK: Части

    private static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func textLeaf(_ text: String, subtype: String, extra: String?) -> Node {
        let normalized = normalizeNewlines(text)
        let bytes = Array(normalized.utf8)
        let ascii = bytes.allSatisfy { $0 < 0x80 }
        let shortLines = normalized.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 76 && !$0.hasPrefix(".") && !$0.hasSuffix(" ") }
        var ct = "text/\(subtype); charset=utf-8"
        if let extra { ct += "; " + extra }
        if ascii && shortLines {
            return .leaf(headers: [("Content-Type", ct), ("Content-Transfer-Encoding", "7bit")], body: normalized)
        }
        return .leaf(headers: [("Content-Type", ct), ("Content-Transfer-Encoding", "quoted-printable")],
                     body: MIMECodec.encodeQuotedPrintable(bytes))
    }

    private static func attachmentLeaf(_ a: OutgoingAttachment) -> Node {
        let name = a.filename.isEmpty ? "attachment" : a.filename
        let type = a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType.lowercased()
        let plainOK = !RFC2047.needsEncoding(name) && !name.contains("\"") && !name.contains("\\")
        let ctHeader: String
        let cdHeader: String
        if plainOK {
            ctHeader = "\(type); name=\"\(name)\""
            cdHeader = "attachment; filename=\"\(name)\""
        } else {
            // Запасное имя для старых клиентов — RFC 2047 в name=, основное — RFC 2231 в filename*.
            ctHeader = "\(type); name=\"\(RFC2047.encode(name.replacingOccurrences(of: "\"", with: "'")))\""
            cdHeader = "attachment; " + rfc2231Parameter("filename", value: name).joined(separator: "; ")
        }
        return .leaf(headers: [("Content-Type", ctHeader),
                               ("Content-Disposition", cdHeader),
                               ("Content-Transfer-Encoding", "base64")],
                     body: MIMECodec.encodeBase64([UInt8](a.data)))
    }

    /// `filename*=utf-8''%D0%9E…` или с продолжениями `filename*0*=…; filename*1*=…`.
    static func rfc2231Parameter(_ key: String, value: String) -> [String] {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)
        var tokens: [String] = []
        for b in value.utf8 {
            tokens.append(allowed.contains(b) ? String(UnicodeScalar(b)) : String(format: "%%%02X", b))
        }
        let full = tokens.joined()
        if full.count + key.count + 9 <= 70 { return ["\(key)*=utf-8''\(full)"] }
        var segments: [String] = []
        var current = ""
        for t in tokens {
            if current.count + t.count > 54 { segments.append(current); current = "" }
            current += t
        }
        if !current.isEmpty { segments.append(current) }
        return segments.enumerated().map { i, seg in
            i == 0 ? "\(key)*0*=utf-8''\(seg)" : "\(key)*\(i)*=\(seg)"
        }
    }

    private static func render(_ node: Node, topLevel: Bool) -> (headers: [(String, String)], body: String) {
        switch node {
        case let .leaf(headers, body):
            return (headers, body)
        case let .multipart(subtype, children):
            let boundary = "=_UniMail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            var body = topLevel ? "This is a multi-part message in MIME format.\r\n" : ""
            for child in children {
                let (h, b) = render(child, topLevel: false)
                body += (body.isEmpty ? "" : "\r\n") + "--\(boundary)\r\n"
                body += h.map { foldHeader($0.0, $0.1) }.joined(separator: "\r\n")
                body += "\r\n\r\n" + b
            }
            body += "\r\n--\(boundary)--"
            if topLevel { body += "\r\n" } // у вложенной части CRLF перед следующей границей добавит родитель
            return ([("Content-Type", "multipart/\(subtype); boundary=\"\(boundary)\"")], body)
        }
    }

    // MARK: Перенос заголовков

    /// `Name: value` с переносом по пробелам так, чтобы строки были ≤ 78 символов где возможно.
    /// Перенос заменяет существующий пробел на CRLF+пробел — развёртка восстанавливает значение точно.
    static func foldHeader(_ name: String, _ value: String) -> String {
        let line = "\(name): \(value)"
        guard line.count > 78 else { return line }
        let words = value.split(separator: " ", omittingEmptySubsequences: false)
        var lines: [String] = []
        var current = "\(name):"
        var first = true
        for w in words {
            let candidate = current + " " + w
            if !first && !w.isEmpty && candidate.count > 78 && !current.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(current)
                current = " " + w
            } else {
                current = candidate
            }
            first = false
        }
        lines.append(current)
        return lines.joined(separator: "\r\n")
    }
}
