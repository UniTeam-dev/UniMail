import Foundation

// MARK: - Значения и ответы IMAP

/// Одно значение из ответа сервера.
indirect enum IMAPValue: Sendable, Equatable {
    /// Атом: `OK`, `\Seen`, `12`, `BODY[HEADER.FIELDS (REFERENCES)]<0>`.
    case atom(String)
    /// Строка в кавычках или литерал `{n}` / `~{n}` — сырые байты.
    case string(Data)
    /// Скобочный список.
    case list([IMAPValue])
    /// NIL.
    case null

    /// Текст атома или строки (UTF-8, с заменой битых байтов); nil для NIL и списков.
    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    /// Сырые байты строки/атома.
    var data: Data? {
        switch self {
        case .atom(let s): return Data(s.utf8)
        case .string(let d): return d
        default: return nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }

    var number: UInt64? {
        guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return UInt64(t)
    }

    var isNil: Bool {
        if case .null = self { return true }
        return false
    }
}

enum IMAPStatus: String, Sendable {
    case ok = "OK", no = "NO", bad = "BAD", preauth = "PREAUTH", bye = "BYE"
}

/// Код ответа в квадратных скобках: `[UIDVALIDITY 3857529045]`, `[APPENDUID 38505 3955]`…
struct IMAPResponseCode: Sendable, Equatable {
    /// Имя в верхнем регистре.
    var name: String
    /// Аргументы (списки — как вложенные значения).
    var arguments: [IMAPValue]

    var firstNumber: UInt64? { arguments.first?.number }

    /// Все аргументы-атомы плоским списком (для `[CAPABILITY …]`).
    var atoms: [String] { arguments.compactMap(\.text) }
}

/// Ответ статуса: OK/NO/BAD/PREAUTH/BYE + необязательный код + текст.
struct IMAPStatusResponse: Sendable, Equatable {
    var status: IMAPStatus
    var code: IMAPResponseCode?
    var text: String
}

/// Разобранная строка LIST/LSUB/XLIST (имя уже декодировано из modified UTF-7).
struct IMAPListEntry: Sendable, Equatable {
    var attributes: [String]
    var delimiter: String?
    var name: String
}

/// Атрибуты одного ответа FETCH в порядке прихода. Ключи — в верхнем регистре.
struct IMAPFetchAttributes: Sendable, Equatable {
    var items: [(key: String, value: IMAPValue)] = []

    static func == (lhs: IMAPFetchAttributes, rhs: IMAPFetchAttributes) -> Bool {
        lhs.items.count == rhs.items.count && zip(lhs.items, rhs.items).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    subscript(_ key: String) -> IMAPValue? {
        let k = key.uppercased()
        return items.last(where: { $0.key == k })?.value
    }

    /// Первое значение, ключ которого начинается с `prefix` (например, `BODY[HEADER.FIELDS`).
    func value(prefix: String) -> IMAPValue? {
        let p = prefix.uppercased()
        return items.last(where: { $0.key.hasPrefix(p) })?.value
    }

    var uid: UInt32? { self["UID"]?.number.flatMap { UInt32(exactly: $0) } }

    mutating func merge(_ other: IMAPFetchAttributes) {
        items.append(contentsOf: other.items)
    }
}

enum IMAPUntagged: Sendable, Equatable {
    case status(IMAPStatusResponse)
    case capability([String])
    case list(IMAPListEntry)
    case flags([String])
    case exists(Int)
    case recent(Int)
    case expunge(Int)
    case fetch(seq: Int, IMAPFetchAttributes)
    case search([UInt32])
    /// ESEARCH: UID-ы из `ALL` (развёрнутые).
    case esearch([UInt32])
    case enabled([String])
    /// VANISHED (QRESYNC) — UID-ы удалённых писем; `earlier` для VANISHED (EARLIER).
    case vanished(earlier: Bool, uids: [UInt32])
    /// Любой другой ответ: ключевое слово (верхний регистр) и значения.
    case other(String, [IMAPValue])
}

enum IMAPResponse: Sendable, Equatable {
    case tagged(tag: String, IMAPStatusResponse)
    case untagged(IMAPUntagged)
    /// `+ текст` — сервер ждёт продолжения (литерал, IDLE, AUTHENTICATE).
    case continuation(String)
}

// MARK: - Токенизатор

/// «Сырой» ответ: текст строк с маркерами `{n}` и отдельно прочитанные литералы.
/// Строка ответа, заканчивающаяся на `{n}`, продолжается литералом из `literals` и следующей строкой.
struct IMAPRawResponse: Sendable {
    var text: [UInt8]
    var literals: [Data]

    init(text: [UInt8], literals: [Data] = []) {
        self.text = text
        self.literals = literals
    }

    init(_ string: String, literals: [Data] = []) {
        self.text = Array(string.utf8)
        self.literals = literals
    }
}

/// Курсор по сырому ответу. Терпим к лишним пробелам, регистру и незакрытым скобкам.
struct IMAPTokenizer {
    private let bytes: [UInt8]
    private let literals: [Data]
    private(set) var position = 0
    private var literalIndex = 0

    init(_ raw: IMAPRawResponse) {
        bytes = raw.text
        literals = raw.literals
    }

    var atEnd: Bool { position >= bytes.count }

    var peek: UInt8? { position < bytes.count ? bytes[position] : nil }

    mutating func skipSpaces() {
        while position < bytes.count, bytes[position] == 0x20 || bytes[position] == 0x09 { position += 1 }
    }

    mutating func advance() {
        if position < bytes.count { position += 1 }
    }

    /// Содержимое `[...]` с учётом вложенных скобок (курсор — на «[»); nil, если скобки нет.
    mutating func bracketed() -> String? {
        guard peek == UInt8(ascii: "[") else { return nil }
        var depth = 0
        let start = position + 1
        var i = position
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "[") { depth += 1 }
            if bytes[i] == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 {
                    position = i + 1
                    return String(decoding: bytes[start..<i], as: UTF8.self)
                }
            }
            i += 1
        }
        position = bytes.count
        return String(decoding: bytes[min(start, bytes.count)...], as: UTF8.self)
    }

    /// Остаток строки как текст (для человекочитаемой части статусов).
    mutating func rest() -> String {
        guard position < bytes.count else { return "" }
        let s = String(decoding: bytes[position...], as: UTF8.self)
        position = bytes.count
        return s
    }

    /// Атом до пробела/скобки. Квадратные скобки внутри атома читаются целиком
    /// (`BODY[HEADER.FIELDS (A B)]<0>`), как и угловые (`<0.2048>`).
    mutating func atom() -> String {
        let start = position
        var depth = 0
        while position < bytes.count {
            let c = bytes[position]
            if depth > 0 {
                if c == UInt8(ascii: "[") { depth += 1 }
                if c == UInt8(ascii: "]") { depth -= 1 }
                position += 1
                continue
            }
            if c == 0x20 || c == 0x09 || c == UInt8(ascii: "(") || c == UInt8(ascii: ")") || c == UInt8(ascii: "\"") { break }
            if c == UInt8(ascii: "{"), position > start { break }
            if c == UInt8(ascii: "[") { depth += 1 }
            position += 1
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// Следующее значение (после пробелов). nil — конец данных или закрывающая скобка.
    mutating func value() -> IMAPValue? {
        skipSpaces()
        guard let c = peek else { return nil }
        switch c {
        case UInt8(ascii: "("):
            position += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard let p = peek else { break }                 // незакрытый список — закрываем сами
                if p == UInt8(ascii: ")") { position += 1; break }
                if let v = value() { items.append(v) } else { break }
            }
            return .list(items)
        case UInt8(ascii: ")"):
            return nil
        case UInt8(ascii: "\""):
            return .string(quoted())
        case UInt8(ascii: "{"):
            if let lit = literal() { return .string(lit) }
            return .atom(atom())
        case UInt8(ascii: "~"):
            if position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "{") {
                let save = position
                position += 1
                if let lit = literal() { return .string(lit) }
                position = save
            }
            return atomValue()
        default:
            return atomValue()
        }
    }

    private mutating func atomValue() -> IMAPValue {
        let a = atom()
        if a.isEmpty {
            // Непонятный одиночный байт — пропускаем, чтобы не зациклиться.
            position += 1
            return .atom(String(decoding: [bytes[position - 1]], as: UTF8.self))
        }
        if a.count == 3, a.uppercased() == "NIL" { return .null }
        return .atom(a)
    }

    /// Строка в кавычках с экранированием `\"` и `\\`.
    private mutating func quoted() -> Data {
        position += 1
        var out: [UInt8] = []
        while position < bytes.count {
            let c = bytes[position]
            position += 1
            if c == UInt8(ascii: "\\"), position < bytes.count {
                out.append(bytes[position])
                position += 1
            } else if c == UInt8(ascii: "\"") {
                break
            } else {
                out.append(c)
            }
        }
        return Data(out)
    }

    /// `{n}`, `{n+}` — берём следующий прочитанный литерал.
    private mutating func literal() -> Data? {
        let save = position
        guard peek == UInt8(ascii: "{") else { return nil }
        position += 1
        var digits = 0
        while position < bytes.count, bytes[position] >= 0x30, bytes[position] <= 0x39 { position += 1; digits += 1 }
        if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") { position += 1 }
        guard digits > 0, position < bytes.count, bytes[position] == UInt8(ascii: "}") else {
            position = save
            return nil
        }
        position += 1
        guard literalIndex < literals.count else {
            position = save
            return nil
        }
        defer { literalIndex += 1 }
        return literals[literalIndex]
    }

    /// Все оставшиеся значения.
    mutating func values() -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpaces()
            if peek == UInt8(ascii: ")") { position += 1; continue }   // лишняя скобка
            guard let v = value() else { break }
            out.append(v)
        }
        return out
    }
}

// MARK: - Разбор ответа

enum IMAPResponseParser {
    /// Если строка заканчивается маркером литерала `{n}` / `{n+}` / `~{n}` — его длина.
    static func trailingLiteralLength(_ line: [UInt8]) -> Int? {
        guard let last = line.last, last == UInt8(ascii: "}") else { return nil }
        var i = line.count - 2
        if i >= 0, line[i] == UInt8(ascii: "+") || line[i] == UInt8(ascii: "-") { i -= 1 }
        var value = 0
        var digits = 0
        var multiplier = 1
        while i >= 0, line[i] >= 0x30, line[i] <= 0x39 {
            value += Int(line[i] - 0x30) * multiplier
            multiplier = multiplier &* 10
            digits += 1
            i -= 1
            if digits > 12 { return nil }
        }
        guard digits > 0, i >= 0, line[i] == UInt8(ascii: "{") else { return nil }
        return value
    }

    static func parse(_ raw: IMAPRawResponse) -> IMAPResponse {
        var t = IMAPTokenizer(raw)
        guard let first = t.peek else { return .untagged(.other("", [])) }
        if first == UInt8(ascii: "+") {
            t.advance()   // "+"
            t.skipSpaces()
            return .continuation(t.rest())
        }
        if first == UInt8(ascii: "*") {
            _ = t.atom()
            return .untagged(parseUntagged(&t))
        }
        let tag = t.atom()
        t.skipSpaces()
        let word = t.atom().uppercased()
        let status = IMAPStatus(rawValue: word) ?? .bad
        var s = parseStatusTail(&t, status: status)
        if IMAPStatus(rawValue: word) == nil { s.text = word + " " + s.text }
        return .tagged(tag: tag, s)
    }

    /// Код в скобках и текст после статуса.
    static func parseStatusTail(_ t: inout IMAPTokenizer, status: IMAPStatus) -> IMAPStatusResponse {
        t.skipSpaces()
        var code: IMAPResponseCode?
        if let inner = t.bracketed() {
            var ct = IMAPTokenizer(IMAPRawResponse(inner))
            let name = ct.atom().uppercased()
            code = IMAPResponseCode(name: name, arguments: ct.values())
        }
        t.skipSpaces()
        return IMAPStatusResponse(status: status, code: code, text: t.rest().trimmingCharacters(in: .whitespaces))
    }

    static func parseUntagged(_ t: inout IMAPTokenizer) -> IMAPUntagged {
        t.skipSpaces()
        let first = t.atom()
        let upper = first.uppercased()

        if let number = Int(first) {
            t.skipSpaces()
            let keyword = t.atom().uppercased()
            switch keyword {
            case "EXISTS": return .exists(number)
            case "RECENT": return .recent(number)
            case "EXPUNGE": return .expunge(number)
            case "FETCH":
                var attrs = IMAPFetchAttributes()
                if case .list(let items)? = t.value() {
                    var i = 0
                    while i < items.count {
                        let key = items[i].text?.uppercased() ?? ""
                        let value = i + 1 < items.count ? items[i + 1] : .null
                        attrs.items.append((key: normalizeFetchKey(key), value: value))
                        i += 2
                    }
                }
                return .fetch(seq: number, attrs)
            default:
                return .other(keyword, [.atom(first)] + t.values())
            }
        }

        switch upper {
        case "OK", "NO", "BAD", "PREAUTH", "BYE":
            return .status(parseStatusTail(&t, status: IMAPStatus(rawValue: upper)!))
        case "CAPABILITY":
            return .capability(t.values().compactMap { $0.text?.uppercased() })
        case "LIST", "LSUB", "XLIST":
            let values = t.values()
            let attrs = values.first?.list?.compactMap(\.text) ?? []
            let delimiter: String? = values.count > 1 ? values[1].text : nil
            var name = ""
            if values.count > 2, let d = values[2].data {
                name = IMAPUTF7.decode(IMAPHeaderDecoding.decodeText(d, charset: "utf-8"))
            }
            return .list(IMAPListEntry(attributes: attrs, delimiter: delimiter, name: name))
        case "FLAGS":
            return .flags(t.value()?.list?.compactMap(\.text) ?? [])
        case "SEARCH", "SORT":
            var uids: [UInt32] = []
            for v in t.values() {
                if let n = v.number, let u = UInt32(exactly: n) { uids.append(u) }  // «(MODSEQ n)» — список, пропускаем
            }
            return .search(uids)
        case "ESEARCH":
            let values = t.values()
            var uids: [UInt32] = []
            var i = 0
            while i < values.count {
                if let k = values[i].text?.uppercased(), k == "ALL", i + 1 < values.count {
                    uids = IMAPSequenceSet.expand(values[i + 1].text ?? "")
                    i += 1
                }
                i += 1
            }
            return .esearch(uids)
        case "ENABLED":
            return .enabled(t.values().compactMap { $0.text?.uppercased() })
        case "VANISHED":
            var values = t.values()
            var earlier = false
            if let l = values.first?.list, l.first?.text?.uppercased() == "EARLIER" {
                earlier = true
                values.removeFirst()
            }
            return .vanished(earlier: earlier, uids: IMAPSequenceSet.expand(values.first?.text ?? ""))
        default:
            return .other(upper, t.values())
        }
    }

    /// `BODY.PEEK[...]` сервер возвращает как `BODY[...]`; `BINARY.PEEK` — как `BINARY`.
    static func normalizeFetchKey(_ key: String) -> String {
        var k = key
        if let r = k.range(of: ".PEEK[") { k.replaceSubrange(r, with: "[") }
        return k
    }
}

// MARK: - Наборы UID

enum IMAPSequenceSet {
    /// Сжатие в диапазоны: [1,2,3,4,5,8,10,11,12] → "1:5,8,10:12".
    static func compress(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        guard var start = sorted.first else { return "" }
        var parts: [String] = []
        var prev = start
        for u in sorted.dropFirst() {
            if u == prev &+ 1 { prev = u; continue }
            parts.append(start == prev ? "\(start)" : "\(start):\(prev)")
            start = u
            prev = u
        }
        parts.append(start == prev ? "\(start)" : "\(start):\(prev)")
        return parts.joined(separator: ",")
    }

    /// Разворачивание "1:3,7" → [1,2,3,7]. `*` и слишком большие диапазоны игнорируются.
    static func expand(_ set: String) -> [UInt32] {
        var out: [UInt32] = []
        for part in set.split(separator: ",") {
            let bounds = part.split(separator: ":", maxSplits: 1)
            if bounds.count == 2, let a = UInt32(bounds[0]), let b = UInt32(bounds[1]) {
                let lo = min(a, b), hi = max(a, b)
                guard hi - lo < 1_000_000 else { continue }
                out.append(contentsOf: lo...hi)
            } else if let a = UInt32(part) {
                out.append(a)
            }
        }
        return out
    }
}
