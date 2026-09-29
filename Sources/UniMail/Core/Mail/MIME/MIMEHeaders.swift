import Foundation

/// Одно поле заголовка: имя как в письме, значение развёрнуто (unfolded), но не декодировано (RFC 2047 не применён).
struct MIMEHeaderField: Sendable, Hashable {
    var name: String
    var value: String
}

/// Заголовки письма или MIME-части. Поиск по имени без учёта регистра, порядок сохраняется.
/// Значения — «сырые» (развёрнутые, без RFC 2047-декодирования); для текста используйте `decoded(_:)`.
struct MIMEHeaders: Sendable {
    var fields: [MIMEHeaderField]

    init(_ fields: [MIMEHeaderField] = []) {
        self.fields = fields
    }

    /// Первое значение заголовка (обрезанное по краям).
    subscript(_ name: String) -> String? {
        let key = name.lowercased()
        return fields.first { $0.name.lowercased() == key }?.value.trimmingCharacters(in: .whitespaces)
    }

    /// Все значения заголовка в порядке появления.
    func all(_ name: String) -> [String] {
        let key = name.lowercased()
        return fields.filter { $0.name.lowercased() == key }.map { $0.value.trimmingCharacters(in: .whitespaces) }
    }

    /// Значение с декодированными encoded-words.
    func decoded(_ name: String) -> String? {
        self[name].map(RFC2047.decode)
    }

    /// Словарь «имя в нижнем регистре → первое значение» (для `IMAPMessageSummary.headers` и категоризации).
    var dictionary: [String: String] {
        var d: [String: String] = [:]
        for f in fields where d[f.name.lowercased()] == nil {
            d[f.name.lowercased()] = f.value.trimmingCharacters(in: .whitespaces)
        }
        return d
    }

    // MARK: Разбор блока заголовков

    /// Делит байты на блок заголовков и тело (по первой пустой строке CRLFCRLF или LFLF).
    static func split(_ bytes: ArraySlice<UInt8>) -> (header: ArraySlice<UInt8>, body: ArraySlice<UInt8>) {
        var i = bytes.startIndex
        let end = bytes.endIndex
        // Письмо, начинающееся с пустой строки, — без заголовков.
        if i < end, bytes[i] == 10 { return (bytes[i..<i], bytes[(i + 1)...]) }
        if i + 1 < end, bytes[i] == 13, bytes[i + 1] == 10 { return (bytes[i..<i], bytes[(i + 2)...]) }
        while i < end {
            if bytes[i] == 10 {
                var j = i + 1
                if j < end, bytes[j] == 13 { j += 1 }
                if j < end, bytes[j] == 10 {
                    return (bytes[bytes.startIndex..<i], bytes[(j + 1)...])
                }
                if j == end { break }
            }
            i += 1
        }
        return (bytes, bytes[end..<end])
    }

    /// Разбор блока заголовков: развёртка строк продолжения, декодирование 8-битных значений
    /// (UTF-8, иначе `charsetHint`, иначе windows-1252).
    static func parse(_ block: ArraySlice<UInt8>, charsetHint: String? = nil) -> MIMEHeaders {
        var fields: [MIMEHeaderField] = []
        var current: [UInt8] = []

        func finish() {
            defer { current = [] }
            guard let colon = current.firstIndex(of: UInt8(ascii: ":")) else { return }
            let nameBytes = current[..<colon]
            let name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { return }
            var valueBytes = Array(current[(colon + 1)...])
            while let f = valueBytes.first, f == 32 || f == 9 { valueBytes.removeFirst() }
            fields.append(MIMEHeaderField(name: name, value: decodeRaw(valueBytes, hint: charsetHint)))
        }

        var lineStart = block.startIndex
        let end = block.endIndex
        var i = block.startIndex
        while i <= end {
            if i == end || block[i] == 10 {
                var lineEnd = i
                if lineEnd > lineStart, block[lineEnd - 1] == 13 { lineEnd -= 1 }
                let line = block[lineStart..<lineEnd]
                if let first = line.first, first == 32 || first == 9 {
                    // Продолжение: CRLF удаляется, пробельный символ остаётся.
                    if !current.isEmpty { current += line }
                } else if !line.isEmpty {
                    if !current.isEmpty { finish() }
                    // mbox-строка «From ...» без двоеточия в имени — пропускаем.
                    current = Array(line)
                }
                lineStart = i + 1
            }
            i += 1
        }
        if !current.isEmpty { finish() }
        return MIMEHeaders(fields)
    }

    /// Сырые байты значения заголовка → строка. ASCII и UTF-8 (RFC 6532) — как есть; иначе по подсказке.
    static func decodeRaw(_ bytes: [UInt8], hint: String?) -> String {
        if bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        if let s = TextEncodings.strictUTF8(bytes) { return s }
        let h = TextEncodings.normalize(hint)
        if !h.isEmpty, h != "utf-8", h != "us-ascii" { return TextEncodings.decode(bytes: bytes, charset: h) }
        return TextEncodings.decodeSingleByte(bytes, table: SingleByteTables.windows1251)
    }
}

/// Значение вида `type/subtype; a=b; c="d"` (Content-Type, Content-Disposition) с RFC 2231-параметрами.
struct MIMEParameterizedValue: Sendable {
    /// Основное значение в нижнем регистре (`text/plain`, `attachment`).
    var value: String
    /// Параметры: ключ в нижнем регистре, значение декодировано (RFC 2231 и, нестандартно, RFC 2047).
    var parameters: [String: String]

    init(value: String, parameters: [String: String] = [:]) {
        self.value = value
        self.parameters = parameters
    }

    subscript(_ key: String) -> String? { parameters[key.lowercased()] }

    /// Разбор с поддержкой кавычек, `\`-экранирования, `name*=utf-8''%D0...` и продолжений `name*0*=`.
    static func parse(_ raw: String?) -> MIMEParameterizedValue {
        guard let raw else { return MIMEParameterizedValue(value: "") }
        let parts = splitParameters(raw)
        guard let first = parts.first else { return MIMEParameterizedValue(value: "") }
        let main = stripComments(first).trimmingCharacters(in: .whitespaces).lowercased()

        // name → [(index, encoded, value)]
        struct Segment { var index: Int; var encoded: Bool; var value: String }
        var plain: [String: String] = [:]
        var extended: [String: [Segment]] = [:]

        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            var key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            value = unquote(value)
            guard !key.isEmpty else { continue }
            if let star = key.firstIndex(of: "*") {
                let base = String(key[..<star])
                var rest = String(key[key.index(after: star)...])
                var encoded = false
                var index = 0
                if rest.isEmpty {
                    encoded = true              // name*=
                } else {
                    if rest.hasSuffix("*") { encoded = true; rest.removeLast() }
                    index = Int(rest) ?? 0      // name*0= / name*1*=
                }
                extended[base, default: []].append(Segment(index: index, encoded: encoded, value: value))
                key = base
            } else {
                if plain[key] == nil { plain[key] = value }
            }
        }

        var params: [String: String] = [:]
        for (key, value) in plain {
            params[key] = RFC2047.decode(value)
        }
        for (key, segments) in extended {
            let sorted = segments.sorted { $0.index < $1.index }
            var charset: String?
            var bytes: [UInt8] = []
            for (n, seg) in sorted.enumerated() {
                var v = seg.value
                if seg.encoded && n == 0 {
                    // charset'language'value
                    let pieces = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if pieces.count == 3 {
                        charset = String(pieces[0])
                        v = String(pieces[2])
                    }
                }
                bytes += seg.encoded ? percentDecode(v) : Array(v.utf8)
            }
            let decoded: String
            if let charset, !charset.isEmpty {
                decoded = TextEncodings.decode(bytes: bytes, charset: charset)
            } else {
                decoded = MIMEHeaders.decodeRaw(bytes, hint: nil)
            }
            params[key] = RFC2047.decode(decoded)   // RFC 2231 приоритетнее обычного параметра
        }
        return MIMEParameterizedValue(value: main, parameters: params)
    }

    /// Разбивка по «;» вне кавычек и комментариев.
    static func splitParameters(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var depth = 0
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            switch ch {
            case "\\" where inQuotes:
                current.append(ch); escaped = true
            case "\"" where depth == 0:
                inQuotes.toggle(); current.append(ch)
            case "(" where !inQuotes:
                depth += 1; current.append(ch)
            case ")" where !inQuotes && depth > 0:
                depth -= 1; current.append(ch)
            case ";" where !inQuotes && depth == 0:
                parts.append(current); current = ""
            default:
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.enumerated()
            .filter { $0.offset == 0 || !$0.element.isEmpty }.map(\.element)
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else {
            // Незакрытая кавычка — просто убираем её.
            if s.hasPrefix("\"") { return String(s.dropFirst()) }
            return stripComments(s).trimmingCharacters(in: .whitespaces)
        }
        var out = ""
        var escaped = false
        for ch in s.dropFirst().dropLast() {
            if escaped { out.append(ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out
    }

    static func stripComments(_ s: String) -> String {
        guard s.contains("(") else { return s }
        var out = ""
        var depth = 0
        var inQuotes = false
        for ch in s {
            if ch == "\"" && depth == 0 { inQuotes.toggle() }
            if !inQuotes && ch == "(" { depth += 1; continue }
            if !inQuotes && ch == ")" && depth > 0 { depth -= 1; continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    static func percentDecode(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        while i < b.count {
            if b[i] == UInt8(ascii: "%"), i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return out
    }
}
