import Foundation

/// Вспомогательные функции полнотекстового индекса: построение безопасного выражения
/// FTS5 MATCH из пользовательского ввода и извлечение текста из HTML.
enum MailFTS {
    /// Операторы, которые сужают поиск до колонки индекса.
    static let columnPrefixes: [(prefix: String, column: String)] = [
        ("from:", "sender"),
        ("subject:", "subject"),
        ("to:", "recipients"),
    ]

    /// Операторы-фильтры, которые не относятся к тексту (их применяет вызывающий код,
    /// см. `SearchQuery`): в FTS-выражение они не попадают.
    static let ignoredPrefixes = ["is:", "has:"]

    /// Строит выражение для `MATCH` из пользовательской строки.
    ///
    /// - Ввод делится на слова по пробелам; `"…"` объединяет слова в точную фразу.
    /// - Каждое слово берётся в кавычки (кавычки внутри экранируются удвоением), поэтому
    ///   операторы FTS5 (`AND`, `NEAR`, `*`, `:`, скобки) из ввода не интерпретируются.
    /// - Неквотированные слова ищутся по префиксу (`"догов"*` находит «договор»).
    /// - `from:` → колонка sender, `subject:` → subject, `to:` → recipients; прочее — по всем колонкам.
    /// - Слова без букв и цифр отбрасываются. Все условия объединяются через AND.
    ///
    /// Возвращает nil, если искать нечего.
    static func matchExpression(for input: String) -> String? {
        var clauses: [String] = []
        for token in tokenize(input) {
            var value = token.text
            var column: String?
            if !token.startsWithQuote {
                let lower = value.lowercased()
                if ignoredPrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
                if let match = columnPrefixes.first(where: { lower.hasPrefix($0.prefix) }) {
                    column = match.column
                    value = String(value.dropFirst(match.prefix.count))
                }
            }
            guard value.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            var term = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if !token.quoted { term += "*" }
            clauses.append(column.map { "\($0) : \(term)" } ?? term)
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
    }

    struct Token: Equatable {
        var text: String
        /// Внутри токена были кавычки (точная фраза, без префиксного поиска).
        var quoted: Bool
        /// Токен начинался с кавычки — тогда `from:` внутри считается текстом.
        var startsWithQuote: Bool
    }

    /// Деление строки на слова с учётом кавычек. Сами кавычки в текст не попадают.
    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        var quoted = false
        var startsWithQuote = false
        var started = false

        func flush() {
            if started && !current.isEmpty {
                tokens.append(Token(text: current, quoted: quoted, startsWithQuote: startsWithQuote))
            }
            current = ""; quoted = false; startsWithQuote = false; started = false
        }

        for ch in input {
            if ch == "\"" || ch == "«" || ch == "»" || ch == "“" || ch == "”" {
                if !started { startsWithQuote = true; started = true }
                inQuotes.toggle()
                quoted = true
            } else if ch.isWhitespace && !inQuotes {
                flush()
            } else {
                started = true
                current.append(ch)
            }
        }
        flush()
        return tokens
    }

    // MARK: HTML → текст

    private static let inlineTags: Set<String> = [
        "a", "b", "i", "u", "s", "em", "strong", "span", "font", "small", "big",
        "sup", "sub", "mark", "code", "abbr", "wbr", "strike", "ins", "del",
    ]
    private static let skippedTags: Set<String> = ["script", "style", "head", "title", "template", "noscript"]

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "laquo": "«", "raquo": "»", "mdash": "—", "ndash": "–", "hellip": "…",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "bull": "•", "middot": "·", "shy": "", "zwnj": "", "zwj": "",
    ]

    /// Грубое, но быстрое извлечение текста из HTML для индекса:
    /// теги убираются (script/style/head — вместе с содержимым), комментарии пропускаются,
    /// основные сущности (`&amp;`, `&nbsp;`, `&#1076;`, `&#x444;`) декодируются, пробелы схлопываются.
    static func plainText(fromHTML html: String) -> String {
        let b = Array(html.utf8)
        let n = b.count
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var i = 0

        func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }
        func matches(_ pattern: [UInt8], at index: Int) -> Bool {
            guard index + pattern.count <= n else { return false }
            for k in 0..<pattern.count where lower(b[index + k]) != pattern[k] { return false }
            return true
        }
        func find(_ pattern: [UInt8], from start: Int) -> Int? {
            var k = start
            while k + pattern.count <= n {
                if matches(pattern, at: k) { return k }
                k += 1
            }
            return nil
        }
        /// Конец тега: первый `>` вне кавычек атрибутов.
        func tagEnd(from start: Int) -> Int {
            var k = start
            var quote: UInt8 = 0
            while k < n {
                let c = b[k]
                if quote != 0 { if c == quote { quote = 0 } }
                else if c == 34 || c == 39 { quote = c }
                else if c == 62 { return k }
                k += 1
            }
            return n
        }

        while i < n {
            let c = b[i]
            if c == 60 /* < */ {
                if matches(Array("<!--".utf8), at: i) {
                    i = (find(Array("-->".utf8), from: i + 4).map { $0 + 3 }) ?? n
                    out.append(32)
                    continue
                }
                var j = i + 1
                var closing = false
                if j < n && b[j] == 47 /* / */ { closing = true; j += 1 }
                let nameStart = j
                while j < n, (b[j] >= 65 && b[j] <= 90) || (b[j] >= 97 && b[j] <= 122) || (b[j] >= 48 && b[j] <= 57) { j += 1 }
                if j == nameStart && !(j < n && (b[j] == 33 || b[j] == 63)) {
                    // «<» без имени тега — обычный символ (например, «a < b»).
                    out.append(c); i += 1; continue
                }
                let name = String(decoding: b[nameStart..<j].map(lower), as: UTF8.self)
                let end = tagEnd(from: j)
                i = end + 1
                if !closing && skippedTags.contains(name) {
                    let closeTag = Array("</\(name)".utf8)
                    if let close = find(closeTag, from: i) {
                        i = tagEnd(from: close) + 1
                    } else {
                        i = n
                    }
                    out.append(32)
                } else if !inlineTags.contains(name) {
                    out.append(32)
                }
                continue
            }
            if c == 38 /* & */ {
                var j = i + 1
                while j < n, j - i <= 10, b[j] != 59 /* ; */, b[j] != 38, b[j] != 32 { j += 1 }
                if j < n, b[j] == 59 {
                    let entity = String(decoding: b[(i + 1)..<j], as: UTF8.self)
                    if let decoded = decodeEntity(entity) {
                        out.append(contentsOf: Array(decoded.utf8))
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(c)
            i += 1
        }
        let text = String(decoding: out, as: UTF8.self)
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func decodeEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return value == 0xA0 ? " " : String(Character(scalar))
        }
        return namedEntities[entity.lowercased()]
    }
}
