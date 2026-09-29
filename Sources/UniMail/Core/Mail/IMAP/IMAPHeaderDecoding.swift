import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Минимальный декодер заголовков и текста для IMAP-модуля (без зависимости от MIME-модуля):
/// RFC 2047 (B и Q), кодировки, quoted-printable, base64 и получение превью.
enum IMAPHeaderDecoding {

    // MARK: RFC 2047

    /// Декодирует encoded-words `=?charset?B|Q?...?=`. Пробелы между соседними encoded-words удаляются,
    /// соседние слова в одной кодировке склеиваются до перекодирования (многобайтные символы на стыке).
    static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var out = ""
        var pendingBytes = Data()
        var pendingCharset: String?
        var rest = Substring(input)

        func flushPending() {
            if let cs = pendingCharset {
                out += decodeText(pendingBytes, charset: cs)
            }
            pendingBytes = Data()
            pendingCharset = nil
        }

        while !rest.isEmpty {
            guard let start = rest.range(of: "=?") else {
                flushPending()
                out += rest
                break
            }
            let before = rest[rest.startIndex..<start.lowerBound]
            if let word = parseEncodedWord(rest[start.lowerBound...]) {
                let onlyWhitespace = before.allSatisfy(\.isWhitespace)
                if onlyWhitespace && pendingCharset != nil {
                    // Пробелы между encoded-words игнорируются (RFC 2047 §6.2).
                } else {
                    flushPending()
                    out += before
                }
                let cs = word.charset.lowercased()
                if pendingCharset != nil, pendingCharset != cs { flushPending() }
                pendingCharset = cs
                pendingBytes.append(word.bytes)
                rest = rest[word.end...]
            } else {
                flushPending()
                out += before + "=?"
                rest = rest[start.upperBound...]
            }
        }
        flushPending()
        return out
    }

    private struct EncodedWord {
        var charset: String
        var bytes: Data
        var end: Substring.Index
    }

    private static func parseEncodedWord(_ s: Substring) -> EncodedWord? {
        // =?charset?X?text?=
        guard s.hasPrefix("=?") else { return nil }
        let afterStart = s.index(s.startIndex, offsetBy: 2)
        guard let q1 = s[afterStart...].firstIndex(of: "?") else { return nil }
        var charset = String(s[afterStart..<q1])
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }  // RFC 2231 язык
        guard !charset.isEmpty, charset.count < 40 else { return nil }
        let encIndex = s.index(after: q1)
        guard encIndex < s.endIndex else { return nil }
        let enc = s[encIndex]
        let q2 = s.index(after: encIndex)
        guard q2 < s.endIndex, s[q2] == "?" else { return nil }
        let textStart = s.index(after: q2)
        guard let endRange = s[textStart...].range(of: "?=") else { return nil }
        let text = s[textStart..<endRange.lowerBound]
        guard !text.contains(" ") else { return nil }
        let bytes: Data
        switch enc {
        case "B", "b": bytes = decodeBase64(Data(text.utf8))
        case "Q", "q": bytes = decodeQuotedPrintable(Data(text.utf8), underscoreIsSpace: true)
        default: return nil
        }
        return EncodedWord(charset: charset, bytes: bytes, end: endRange.upperBound)
    }

    // MARK: Transfer encodings

    /// base64 с терпимостью к пробелам, переносам, отсутствию «=» и обрезанному хвосту.
    static func decodeBase64(_ data: Data) -> Data {
        var clean: [UInt8] = []
        clean.reserveCapacity(data.count)
        for b in data {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                clean.append(b)
            case UInt8(ascii: "-"): clean.append(UInt8(ascii: "+"))   // base64url
            case UInt8(ascii: "_"): clean.append(UInt8(ascii: "/"))
            default: continue
            }
        }
        if clean.count % 4 == 1 { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(UInt8(ascii: "=")) }
        return Data(base64Encoded: Data(clean)) ?? Data()
    }

    /// quoted-printable; мягкие переносы `=\r\n` удаляются, битые `=X` остаются как есть, обрезанный `=` в конце отбрасывается.
    static func decodeQuotedPrintable(_ data: Data, underscoreIsSpace: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - 48
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - 55
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - 87
            default: return nil
            }
        }
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "=") {
                if i + 1 >= bytes.count { break }                        // обрезанный хвост
                if bytes[i + 1] == 13, i + 2 < bytes.count, bytes[i + 2] == 10 { i += 3; continue }
                if bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 >= bytes.count { break }
                if let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                out.append(c)
                i += 1
            } else if underscoreIsSpace && c == UInt8(ascii: "_") {
                out.append(0x20)
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return Data(out)
    }

    /// Снимает Content-Transfer-Encoding (7bit/8bit/binary — без изменений).
    static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": return decodeBase64(data)
        case "quoted-printable": return decodeQuotedPrintable(data)
        default: return data
        }
    }

    // MARK: Charsets

    /// Байты → строка в указанной кодировке. Кириллические и латинские однобайтовые кодировки
    /// декодируются своими таблицами (одинаково на macOS и Linux), остальные — через CoreFoundation,
    /// если он есть, иначе UTF-8 с заменой. Без charset: UTF-8, а при невалидном UTF-8 — windows-1251.
    static func decodeText(_ data: Data, charset: String?) -> String {
        let cs = normalizeCharset(charset)
        switch cs {
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            return decodeUTF8Lossy(data)
        case "us-ascii", "ascii", "ansi_x3.4-1968", "":
            if let s = String(data: data, encoding: .utf8) { return s }
            return charset == nil || cs.isEmpty ? decodeSingleByte(data, table: IMAPCharsetTables.cp1251) : decodeUTF8Lossy(data)
        case "windows-1251", "cp1251", "x-cp1251", "cp-1251":
            return decodeSingleByte(data, table: IMAPCharsetTables.cp1251)
        case "koi8-r", "koi8", "koi8-u", "koi8-ru":
            return decodeSingleByte(data, table: IMAPCharsetTables.koi8r)
        case "iso-8859-5", "iso8859-5", "iso_8859-5", "cyrillic":
            return decodeSingleByte(data, table: IMAPCharsetTables.iso88595)
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1":
            return decodeSingleByte(data, table: nil)
        case "windows-1252", "cp1252":
            return decodeSingleByte(data, table: IMAPCharsetTables.cp1252)
        default:
            #if canImport(CoreFoundation)
            if let cf = CFStringCreateWithCString(nil, cs, CFStringBuiltInEncodings.UTF8.rawValue) {
                let enc = CFStringConvertIANACharSetNameToEncoding(cf)
                if enc != kCFStringEncodingInvalidId {
                    let ns = CFStringConvertEncodingToNSStringEncoding(enc)
                    if let s = String(data: data, encoding: String.Encoding(rawValue: ns)) { return s }
                }
            }
            #endif
            return decodeUTF8Lossy(data)
        }
    }

    static func normalizeCharset(_ charset: String?) -> String {
        guard var c = charset?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return "" }
        c = c.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return c
    }

    /// UTF-8 с заменой битых байтов; обрезанный многобайтный символ в конце отбрасывается.
    static func decodeUTF8Lossy(_ data: Data) -> String {
        var s = String(decoding: data, as: UTF8.self)
        while s.hasSuffix("\u{FFFD}") { s.removeLast() }
        return s
    }

    private static func decodeSingleByte(_ data: Data, table: [UInt16]?) -> String {
        var scalars = String.UnicodeScalarView()
        for b in data {
            if b < 0x80 || table == nil {
                scalars.append(Unicode.Scalar(b))
            } else if let t = table, let s = Unicode.Scalar(UInt32(t[Int(b) - 0x80])) {
                scalars.append(s)
            }
        }
        return String(scalars)
    }

    // MARK: Заголовки

    /// Разбор блока заголовков (как в BODY[HEADER.FIELDS (...)]) в словарь с ключами в нижнем регистре.
    /// Складки (строки, начинающиеся с пробела/таба) склеиваются; повторные заголовки объединяются через пробел.
    static func parseHeaderBlock(_ data: Data) -> [String: String] {
        let text = decodeText(data, charset: nil)
        var result: [String: String] = [:]
        var currentName: String?
        var currentValue = ""

        func commit() {
            guard let name = currentName else { return }
            let value = currentValue.trimmingCharacters(in: .whitespaces)
            if let existing = result[name], !existing.isEmpty {
                result[name] = existing + " " + value
            } else {
                result[name] = value
            }
            currentName = nil
            currentValue = ""
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            if line.isEmpty { commit(); continue }
            if let first = line.first, first == " " || first == "\t" {
                if currentName != nil {
                    currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            commit()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            currentName = name
            currentValue = String(line[line.index(after: colon)...])
        }
        commit()
        return result
    }

    // MARK: Превью

    /// Текст превью из (возможно обрезанного) фрагмента части письма.
    static func previewText(from data: Data, encoding: String?, charset: String?, isHTML: Bool, limit: Int = 200) -> String? {
        var raw = data
        if encoding?.lowercased() == "base64" {
            // Обрезанный base64: берём только полные четвёрки.
            let clean = raw.filter { !($0 == 13 || $0 == 10 || $0 == 32 || $0 == 9) }
            raw = Data(clean.prefix(clean.count - clean.count % 4))
        }
        let decoded = decodeTransfer(raw, encoding: encoding)
        var text = decodeText(decoded, charset: charset?.isEmpty == false ? charset : "utf-8")
        if isHTML { text = stripHTML(text) }
        return collapse(text, limit: limit)
    }

    /// Схлопывает пробелы и обрезает до `limit` символов; убирает строки цитат `>`.
    static func collapse(_ text: String, limit: Int) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix(">") }
        var out = ""
        var lastWasSpace = true
        for ch in lines.joined(separator: " ") {
            if ch.isWhitespace || ch == "\u{00A0}" || ch == "\u{200C}" || ch == "\u{200B}" {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
            if out.count >= limit { break }
        }
        let result = out.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    /// Грубое удаление HTML: блоки style/script/head, комментарии, теги, основные сущности.
    static func stripHTML(_ html: String) -> String {
        var s = html
        for pattern in ["(?is)<head\\b.*?</head>", "(?is)<style\\b.*?(</style>|$)", "(?is)<script\\b.*?(</script>|$)",
                        "(?s)<!--.*?(-->|$)", "(?i)<br\\s*/?>", "(?i)</(p|div|tr|li|h[1-6])>"] {
            s = s.replacingOccurrences(of: pattern, with: " \n", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?s)<[^>]*>?", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        return s
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                       "laquo": "«", "raquo": "»", "mdash": "—", "ndash": "–", "hellip": "…",
                                       "copy": "©", "reg": "®", "trade": "™", "zwnj": "", "zwj": "", "shy": ""]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let v = UInt32(name.dropFirst(2), radix: 16), let sc = Unicode.Scalar(v) { replacement = String(sc) }
                } else if name.hasPrefix("#") {
                    if let v = UInt32(name.dropFirst()), let sc = Unicode.Scalar(v) { replacement = String(sc) }
                } else {
                    replacement = named[name.lowercased()]
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

// MARK: - Таблицы однобайтовых кодировок (0x80…0xFF → Unicode)

enum IMAPCharsetTables {
    static let cp1251: [UInt16] = [
        0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
        0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
        0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
        0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    ] + (0x0410...0x044F).map { UInt16($0) }

    static let koi8r: [UInt16] = {
        let head: [UInt16] = [
            0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C, 0x2580, 0x2584, 0x2588, 0x258C, 0x2590,
            0x2591, 0x2592, 0x2593, 0x2320, 0x25A0, 0x2219, 0x221A, 0x2248, 0x2264, 0x2265, 0x00A0, 0x2321, 0x00B0, 0x00B2, 0x00B7, 0x00F7,
            0x2550, 0x2551, 0x2552, 0x0451, 0x2553, 0x2554, 0x2555, 0x2556, 0x2557, 0x2558, 0x2559, 0x255A, 0x255B, 0x255C, 0x255D, 0x255E,
            0x255F, 0x2560, 0x2561, 0x0401, 0x2562, 0x2563, 0x2564, 0x2565, 0x2566, 0x2567, 0x2568, 0x2569, 0x256A, 0x256B, 0x256C, 0x00A9,
        ]
        let lower = "юабцдефгхийклмнопярстужвьызшэщчъ"
        let letters = (lower + lower.uppercased()).unicodeScalars.map { UInt16($0.value) }
        return head + letters
    }()

    static let iso88595: [UInt16] = {
        var t = (0x80...0x9F).map { UInt16($0) }                   // C1
        t.append(0x00A0)
        t += (0x0401...0x040C).map { UInt16($0) }                  // A1…AC
        t.append(0x00AD)
        t += [0x040E, 0x040F]                                      // AE, AF
        t += (0x0410...0x044F).map { UInt16($0) }                  // B0…EF
        t.append(0x2116)                                           // F0
        t += (0x0451...0x045C).map { UInt16($0) }                  // F1…FC
        t += [0x00A7, 0x045E, 0x045F]                              // FD…FF
        return t
    }()

    static let cp1252: [UInt16] = [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    ] + (0xA0...0xFF).map { UInt16($0) }
}
