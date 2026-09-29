import Foundation

/// Вложение (или встроенная картинка) из разобранного письма.
struct ParsedAttachment: Sendable {
    var filename: String
    var mimeType: String
    var data: Data
    /// Content-ID без угловых скобок — для замены `cid:` в HTML.
    var contentID: String?
    /// Встроенная часть (картинка из `multipart/related` / на неё ссылается HTML через cid:).
    var isInline: Bool
    /// Номер части как в IMAP BODY[…]: "1", "1.2", "2".
    var partID: String
}

/// Результат разбора RFC 5322/MIME-письма.
struct ParsedMessage: Sendable {
    var headers: MIMEHeaders
    var subject: String
    var from: [Address]
    var to: [Address]
    var cc: [Address]
    var replyTo: [Address]
    var date: Date?
    /// Message-ID, In-Reply-To и References хранятся БЕЗ угловых скобок.
    var messageID: String?
    var inReplyTo: String?
    var references: [String]
    /// Первый https:-адрес из List-Unsubscribe, иначе mailto:.
    var listUnsubscribe: String?
    /// List-Unsubscribe-Post содержит «One-Click» (RFC 8058).
    var listUnsubscribePost: Bool
    /// Текст с переводами строк "\n" (format=flowed развёрнут).
    var textBody: String?
    var htmlBody: String?
    var attachments: [ParsedAttachment]
    /// Сырой text/calendar (или application/ics), если есть приглашение.
    var calendar: String?
}

/// Разбор писем. Никогда не падает: битые части становятся вложениями или пропускаются.
enum MIMEParser {
    private static let maxDepth = 40

    static func parse(_ data: Data) -> ParsedMessage {
        let bytes = [UInt8](data)
        let (headerBlock, body) = MIMEHeaders.split(bytes[...])
        let headers = parseHeaders(headerBlock)

        var collected = walk(headers: headers, body: body, partID: nil, depth: 0, defaultType: "text/plain", forceAttachment: false)
        collected.finalizeInline()

        let listUnsub = headers["list-unsubscribe"].flatMap(pickUnsubscribe)
        let post = headers["list-unsubscribe-post"]?.range(of: "one-click", options: .caseInsensitive) != nil

        return ParsedMessage(
            headers: headers,
            subject: cleanHeaderText(headers.decoded("subject") ?? ""),
            from: parseAddressList(headers["from"] ?? ""),
            to: headers.all("to").flatMap(parseAddressList),
            cc: headers.all("cc").flatMap(parseAddressList),
            replyTo: parseAddressList(headers["reply-to"] ?? ""),
            date: headers["date"].flatMap(parseDate),
            messageID: headers["message-id"].flatMap { parseMessageIDs($0).first },
            inReplyTo: headers["in-reply-to"].flatMap { parseMessageIDs($0).first },
            references: headers["references"].map(parseMessageIDs) ?? [],
            listUnsubscribe: listUnsub,
            listUnsubscribePost: post && listUnsub != nil,
            textBody: collected.text,
            htmlBody: collected.html,
            attachments: collected.attachments,
            calendar: collected.calendar
        )
    }

    /// Заголовки с учётом «сырых» 8-битных значений: подсказка кодировки — charset из Content-Type.
    static func parseHeaders(_ block: ArraySlice<UInt8>) -> MIMEHeaders {
        let headers = MIMEHeaders.parse(block)
        if block.contains(where: { $0 >= 0x80 }), !TextEncodings.isValidUTF8(Array(block)),
           let cs = MIMEParameterizedValue.parse(headers["content-type"])["charset"] {
            return MIMEHeaders.parse(block, charsetHint: cs)
        }
        return headers
    }

    // MARK: Обход дерева

    private struct Collected {
        var text: String?
        var html: String?
        var attachments: [ParsedAttachment] = []
        var calendar: String?

        mutating func appendSequential(_ other: Collected) {
            if let t = other.text { text = text.map { $0 + "\n\n" + t } ?? t }
            if let h = other.html { html = html.map { $0 + "\n" + h } ?? h }
            attachments += other.attachments
            if calendar == nil { calendar = other.calendar }
        }

        /// Вложения, на которые ссылается HTML через cid:, считаются встроенными.
        mutating func finalizeInline() {
            guard let html = html?.lowercased() else { return }
            for i in attachments.indices {
                if let cid = attachments[i].contentID, html.contains("cid:" + cid.lowercased()) {
                    attachments[i].isInline = true
                }
            }
        }
    }

    private static func childID(_ parent: String?, _ index: Int) -> String {
        parent.map { "\($0).\(index)" } ?? "\(index)"
    }

    private static func walk(headers: MIMEHeaders, body: ArraySlice<UInt8>, partID: String?, depth: Int,
                             defaultType: String, forceAttachment: Bool) -> Collected {
        let ct = MIMEParameterizedValue.parse(headers["content-type"])
        var type = ct.value
        if type.isEmpty || !type.contains("/") { type = defaultType }

        if type.hasPrefix("multipart/"), depth < maxDepth, let boundary = ct["boundary"], !boundary.isEmpty {
            let rawParts = splitMultipart(body, boundary: boundary)
            if !rawParts.isEmpty {
                let childDefault = type == "multipart/digest" ? "message/rfc822" : "text/plain"
                let children: [(MIMEHeaders, ArraySlice<UInt8>, String)] = rawParts.enumerated().map { idx, raw in
                    let (h, b) = MIMEHeaders.split(raw)
                    return (parseHeaders(h), b, childID(partID, idx + 1))
                }
                return combine(type: type, params: ct, children: children, depth: depth,
                               childDefault: childDefault, forceAttachment: forceAttachment)
            }
            // Граница не найдена — показываем тело как текст.
            type = "text/plain"
        } else if type.hasPrefix("multipart/") {
            type = "text/plain"
        }

        return leaf(headers: headers, contentType: ct, type: type, body: body,
                    partID: partID ?? "1", forceAttachment: forceAttachment)
    }

    private static func combine(type: String, params: MIMEParameterizedValue,
                                children: [(MIMEHeaders, ArraySlice<UInt8>, String)], depth: Int,
                                childDefault: String, forceAttachment: Bool) -> Collected {
        func sub(_ c: (MIMEHeaders, ArraySlice<UInt8>, String), force: Bool = forceAttachment) -> Collected {
            walk(headers: c.0, body: c.1, partID: c.2, depth: depth + 1, defaultType: childDefault, forceAttachment: force)
        }
        var result = Collected()
        switch type {
        case "multipart/alternative":
            // Более поздняя альтернатива — предпочтительнее: HTML берём из последней, текст — из первой.
            let subs = children.map { sub($0) }
            result.text = subs.first { $0.text != nil }?.text
            result.html = subs.last { $0.html != nil }?.html
            result.calendar = subs.first { $0.calendar != nil }?.calendar
            result.attachments = subs.flatMap(\.attachments)

        case "multipart/related":
            let start = params["start"].map(stripAngles)
            let rootIndex = start.flatMap { s in
                children.firstIndex { MIMEParser.stripAngles($0.0["content-id"] ?? "") == s }
            } ?? 0
            for (i, c) in children.enumerated() {
                if i == rootIndex {
                    result.appendSequential(sub(c))
                } else {
                    var r = sub(c, force: true)
                    for j in r.attachments.indices where r.attachments[j].contentID != nil {
                        let dispo = MIMEParameterizedValue.parse(c.0["content-disposition"]).value
                        if dispo != "attachment" { r.attachments[j].isInline = true }
                    }
                    result.appendSequential(r)
                }
            }

        case "multipart/signed":
            // Подпись (smime.p7s, signature.asc) не показываем.
            for (i, c) in children.enumerated() {
                let childType = MIMEParameterizedValue.parse(c.0["content-type"]).value
                if i > 0 && isSignatureType(childType) { continue }
                result.appendSequential(sub(c))
            }

        case "multipart/encrypted":
            for c in children { result.appendSequential(sub(c, force: true)) }

        default: // mixed, report, digest, parallel и неизвестные
            for c in children {
                let childType = MIMEParameterizedValue.parse(c.0["content-type"]).value
                if isSignatureType(childType) { continue }
                result.appendSequential(sub(c))
            }
        }
        return result
    }

    private static func isSignatureType(_ t: String) -> Bool {
        t == "application/pkcs7-signature" || t == "application/x-pkcs7-signature" || t == "application/pgp-signature"
    }

    private static func leaf(headers: MIMEHeaders, contentType ct: MIMEParameterizedValue, type: String,
                             body: ArraySlice<UInt8>, partID: String, forceAttachment: Bool) -> Collected {
        var result = Collected()
        let disposition = MIMEParameterizedValue.parse(headers["content-disposition"])
        let dispo = disposition.value
        let rawName = disposition["filename"] ?? ct["name"]
        let filename = rawName.map(cleanFilename).flatMap { $0.isEmpty ? nil : $0 }
        let data = decodeTransfer(body, encoding: headers["content-transfer-encoding"])
        let contentID = headers["content-id"].map(stripAngles).flatMap { $0.isEmpty ? nil : $0 }

        func textValue() -> String {
            var charset = ct["charset"]
            if charset == nil, type == "text/html" { charset = sniffHTMLCharset(data) }
            return TextEncodings.decode(bytes: data, charset: charset)
        }

        if type == "text/calendar" || type == "application/ics" {
            result.calendar = textValue()
            if dispo != "attachment" && filename == nil { return result }
        } else if !forceAttachment, dispo != "attachment", filename == nil,
                  type == "text/plain" || type == "text/html" {
            var text = textValue().replacingOccurrences(of: "\r\n", with: "\n")
            while text.hasSuffix("\n") { text.removeLast() } // завершающий перевод строки тела не значим
            if type == "text/html" {
                result.html = text
            } else {
                if ct["format"]?.lowercased() == "flowed" {
                    text = unflow(text, delSp: ct["delsp"]?.lowercased() == "yes")
                }
                result.text = text
            }
            return result
        }

        var name = filename
        if name == nil, type == "message/rfc822" || type == "message/global" {
            let (h, _) = MIMEHeaders.split(data[...])
            let subject = cleanHeaderText(parseHeaders(h).decoded("subject") ?? "")
            name = (subject.isEmpty ? "message" : cleanFilename(subject)) + ".eml"
        }
        if name == nil { name = generatedName(type: type, partID: partID) }

        let isInline = contentID != nil && dispo != "attachment"
        result.attachments.append(ParsedAttachment(filename: name!, mimeType: type, data: Data(data),
                                                   contentID: contentID, isInline: isInline, partID: partID))
        return result
    }

    /// Content-Transfer-Encoding → байты.
    static func decodeTransfer(_ body: ArraySlice<UInt8>, encoding: String?) -> [UInt8] {
        switch MIMEParameterizedValue.stripComments(encoding ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": return MIMECodec.decodeBase64(body)
        case "quoted-printable": return MIMECodec.decodeQuotedPrintable(body)
        default: return Array(body) // 7bit, 8bit, binary, неизвестное
        }
    }

    // MARK: Multipart

    /// Части между разделителями `--boundary`. CRLF перед разделителем принадлежит разделителю.
    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delim = Array(("--" + boundary).utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var lineStart = body.startIndex
        let end = body.endIndex

        while lineStart < end {
            var lineEnd = lineStart
            while lineEnd < end, body[lineEnd] != 10 { lineEnd += 1 }
            let next = lineEnd < end ? lineEnd + 1 : end

            if lineEnd - lineStart >= delim.count, body[lineStart] == 45, body[lineStart + 1] == 45,
               body[lineStart..<(lineStart + delim.count)].elementsEqual(delim) {
                var rest = body[(lineStart + delim.count)..<lineEnd]
                let isClose = rest.starts(with: [45, 45])
                if isClose { rest = rest.dropFirst(2) }
                if rest.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) {
                    if let s = partStart {
                        var e = lineStart
                        if e > s, body[e - 1] == 10 { e -= 1 }
                        if e > s, body[e - 1] == 13 { e -= 1 }
                        parts.append(body[s..<max(s, e)])
                    }
                    if isClose { return parts }
                    partStart = next
                }
            }
            lineStart = next
        }
        // Нет закрывающего разделителя — письмо обрезано; берём, что есть.
        if let s = partStart, s <= end { parts.append(body[s..<end]) }
        return parts
    }

    // MARK: Вспомогательное

    static func stripAngles(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<") { t.removeFirst() }
        if t.hasSuffix(">") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Все `<id>` из Message-ID / In-Reply-To / References, без скобок. Без скобок — по пробелам.
    static func parseMessageIDs(_ s: String) -> [String] {
        let cleaned = MIMEParameterizedValue.stripComments(s)
        var ids: [String] = []
        var current: String?
        for ch in cleaned {
            if ch == "<" { current = "" }
            else if ch == ">" {
                if let c = current?.trimmingCharacters(in: .whitespaces), !c.isEmpty { ids.append(c.replacingOccurrences(of: " ", with: "")) }
                current = nil
            } else if current != nil { current!.append(ch) }
        }
        if ids.isEmpty {
            ids = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init).filter { $0.contains("@") || $0.count > 3 }
        }
        return ids
    }

    private static func pickUnsubscribe(_ value: String) -> String? {
        var urls: [String] = []
        var current: String?
        for ch in value {
            if ch == "<" { current = "" }
            else if ch == ">" { if let c = current { urls.append(c.trimmingCharacters(in: .whitespaces)) }; current = nil }
            else if current != nil { current!.append(ch) }
        }
        if urls.isEmpty { urls = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        urls = urls.map { $0.replacingOccurrences(of: " ", with: "") }.filter { !$0.isEmpty }
        return urls.first { $0.lowercased().hasPrefix("https:") }
            ?? urls.first { $0.lowercased().hasPrefix("mailto:") }
            ?? urls.first { $0.lowercased().hasPrefix("http:") }
    }

    private static func cleanHeaderText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Имя файла без путей и управляющих символов.
    private static func cleanFilename(_ s: String) -> String {
        var name = cleanHeaderText(s)
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = String(name[name.index(after: slash)...]) }
        name = String(name.unicodeScalars.filter { $0.value >= 32 && $0 != ":" }.map(Character.init))
        return name.trimmingCharacters(in: .whitespaces)
    }

    private static func generatedName(type: String, partID: String) -> String {
        let ext: String
        switch type {
        case "application/pdf": ext = "pdf"
        case "image/jpeg", "image/jpg", "image/pjpeg": ext = "jpg"
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/heic": ext = "heic"
        case "text/plain", "message/delivery-status", "text/rfc822-headers", "message/disposition-notification": ext = "txt"
        case "text/html": ext = "html"
        case "text/calendar", "application/ics": ext = "ics"
        case "application/zip": ext = "zip"
        case "application/ms-tnef", "application/vnd.ms-tnef": return "winmail.dat"
        default:
            let sub = type.split(separator: "/").last.map(String.init) ?? "bin"
            ext = sub.count <= 5 && sub.allSatisfy({ $0.isLetter || $0.isNumber }) ? sub : "bin"
        }
        return "part-\(partID).\(ext)"
    }

    private static func sniffHTMLCharset(_ data: [UInt8]) -> String? {
        let head = String(decoding: data.prefix(2048).map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self).lowercased()
        guard let r = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-:.]+)"#, options: .regularExpression) else { return nil }
        let match = head[r]
        guard let eq = match.firstIndex(of: "=") else { return nil }
        return match[match.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    /// RFC 3676: format=flowed — строки, кончающиеся пробелом, склеиваются со следующей.
    static func unflow(_ text: String, delSp: Bool) -> String {
        var out: [String] = []
        var paragraph: String?
        var paragraphDepth = 0
        for rawLine in text.components(separatedBy: "\n") {
            var line = Substring(rawLine)
            var depth = 0
            while line.hasPrefix(">") { depth += 1; line = line.dropFirst() }
            if line.hasPrefix(" ") { line = line.dropFirst() } // space-stuffing
            let isSig = line == "-- "
            let flowed = line.hasSuffix(" ") && !isSig
            var content = String(line)
            if flowed && delSp { content.removeLast() }
            if let p = paragraph, depth == paragraphDepth {
                paragraph = p + content
            } else {
                if let p = paragraph { out.append(String(repeating: ">", count: paragraphDepth) + (paragraphDepth > 0 ? " " : "") + p) }
                paragraph = content
                paragraphDepth = depth
            }
            if !flowed {
                out.append(String(repeating: ">", count: depth) + (depth > 0 && !content.isEmpty ? " " : "") + paragraph!)
                paragraph = nil
            }
        }
        if let p = paragraph { out.append(String(repeating: ">", count: paragraphDepth) + (paragraphDepth > 0 ? " " : "") + p) }
        return out.joined(separator: "\n")
    }
}
