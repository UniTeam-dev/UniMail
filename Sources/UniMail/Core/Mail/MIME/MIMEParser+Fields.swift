import Foundation

// MARK: - Адреса (RFC 5322 address-list)

extension MIMEParser {
    /// Разбор списка адресов: отображаемые имена в кавычках (с запятыми и `\"` внутри), группы
    /// `Команда: a@b, c@d;`, encoded-words (в том числе внутри кавычек — нестандартно, но часто),
    /// адреса без угловых скобок и `user@host (Имя)`.
    static func parseAddressList(_ s: String) -> [Address] {
        var result: [Address] = []
        for item in splitAddressItems(s) {
            if let a = parseMailbox(item) { result.append(a) }
        }
        return result
    }

    /// Делит список по запятым/«;» верхнего уровня и отбрасывает имена групп («Имя:»).
    private static func splitAddressItems(_ s: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false, escaped = false, inAngle = false
        var depth = 0
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if inQuotes {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inQuotes = false }
                current.append(ch)
                continue
            }
            if depth > 0 {
                if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 } else if ch == "\\" { escaped = true }
                current.append(ch)
                continue
            }
            switch ch {
            case "\"": inQuotes = true; current.append(ch)
            case "(": depth = 1; current.append(ch)
            case "<": inAngle = true; current.append(ch)
            case ">": inAngle = false; current.append(ch)
            case "," where !inAngle, ";" where !inAngle:
                items.append(current); current = ""
            case ":" where !inAngle:
                // Начало группы: всё накопленное — имя группы.
                current = ""
            default:
                current.append(ch)
            }
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func parseMailbox(_ item: String) -> Address? {
        // Разбираем на: фразу (кусочки в кавычках и атомы), комментарии, адрес в <>.
        var phrase = ""
        var comments: [String] = []
        var angle: String?
        var bare = ""                 // текст вне кавычек/комментариев/скобок
        var inQuotes = false, escaped = false
        var depth = 0
        var comment = ""
        var angleBuf: String?

        for ch in item {
            if escaped {
                if depth > 0 { comment.append(ch) } else { phrase.append(ch) }
                escaped = false
                continue
            }
            if angleBuf != nil {
                if ch == ">" { angle = angleBuf; angleBuf = nil } else { angleBuf!.append(ch) }
                continue
            }
            if inQuotes {
                if ch == "\\" { escaped = true } else if ch == "\"" { inQuotes = false } else { phrase.append(ch) }
                continue
            }
            if depth > 0 {
                if ch == "(" { depth += 1; comment.append(ch) }
                else if ch == ")" {
                    depth -= 1
                    if depth == 0 { comments.append(comment); comment = "" } else { comment.append(ch) }
                } else if ch == "\\" { escaped = true }
                else { comment.append(ch) }
                continue
            }
            switch ch {
            case "\"": inQuotes = true
            case "(": depth = 1
            case "<": angleBuf = ""
            default:
                phrase.append(ch)
                bare.append(ch)
            }
        }
        if let rest = angleBuf { angle = rest } // незакрытая «<»

        var email: String
        var name: String?
        if let angle {
            email = angle
            // Маршрут вида <@a.com,@b.com:user@c.com>.
            if let colon = email.lastIndex(of: ":"), email.hasPrefix("@") { email = String(email[email.index(after: colon)...]) }
            name = phrase
        } else {
            // Без угловых скобок: адрес — текст вне комментариев (в т.ч. "john.doe"@x.com); имя — из комментария.
            email = phrase.contains("@") ? phrase : bare
            name = comments.first
        }
        email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
        if email.lowercased().hasPrefix("mailto:") { email = String(email.dropFirst(7)) }
        guard !email.isEmpty, angle != nil || email.contains("@") else { return nil }

        if var n = name {
            n = RFC2047.decode(n.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).joined(separator: " "))
            n = n.trimmingCharacters(in: .whitespacesAndNewlines)
            // Outlook: 'Имя Фамилия'
            if n.count >= 2, n.hasPrefix("'"), n.hasSuffix("'") { n = String(n.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
            if n.hasPrefix("\""), n.hasSuffix("\""), n.count >= 2 { n = String(n.dropFirst().dropLast()) }
            name = n.isEmpty || n.caseInsensitiveCompare(email) == .orderedSame ? nil : n
        }
        return Address(name: name, email: email)
    }
}

// MARK: - Дата (RFC 5322 + устаревшие формы)

extension MIMEParser {
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let zoneOffsets: [String: Int] = [
        "ut": 0, "utc": 0, "gmt": 0, "z": 0,
        "est": -5, "edt": -4, "cst": -6, "cdt": -5, "mst": -7, "mdt": -6, "pst": -8, "pdt": -7,
        "msk": 3, "msd": 4, "cet": 1, "cest": 2, "eet": 2, "eest": 3, "wet": 0, "west": 1, "bst": 1,
        "yekt": 5, "omst": 6, "novt": 7, "krat": 7, "irkt": 8, "yakt": 9, "vlat": 10, "samt": 4,
        "jst": 9, "kst": 9, "ist": 5, // IST неоднозначен; берём Индию (+5:30 ниже)
    ]

    /// Разбор Date: «Tue, 1 Sep 2026 10:00:00 +0300 (MSK)», без дня недели, без секунд,
    /// двузначный год, буквенные зоны, asctime («Tue Sep  1 10:00:00 2026»), ISO 8601.
    static func parseDate(_ raw: String) -> Date? {
        let s = MIMEParameterizedValue.stripComments(raw)
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if s.count >= 10, s.first?.isNumber == true, s.dropFirst(4).first == "-" {
            return parseISO(s)
        }

        var day: Int?, month: Int?, year: Int?
        var hour = 0, minute = 0, second = 0
        var offsetSeconds: Int?
        var hasTime = false

        for token in s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }) {
            let t = token.lowercased()
            if t.contains(":") && !hasTime, t.first?.isNumber == true {
                let comps = t.split(separator: ":").map { Int($0.prefix { $0.isNumber }) ?? 0 }
                hour = comps.first ?? 0
                minute = comps.count > 1 ? comps[1] : 0
                second = comps.count > 2 ? comps[2] : 0
                hasTime = true
                // «10:00:00+0300» — зона вплотную к времени.
                if let signIdx = t.firstIndex(where: { $0 == "+" || $0 == "-" }) {
                    offsetSeconds = parseNumericZone(String(t[signIdx...]))
                }
                continue
            }
            if (t.hasPrefix("+") || t.hasPrefix("-")), t.count >= 3, t.dropFirst().allSatisfy({ $0.isNumber || $0 == ":" }) {
                offsetSeconds = parseNumericZone(t)
                continue
            }
            if let m = monthNames.firstIndex(where: { t.hasPrefix($0) }), t.first?.isLetter == true, month == nil {
                month = m + 1
                continue
            }
            if t.allSatisfy(\.isNumber) {
                let v = Int(t) ?? 0
                if t.count >= 3 || (day != nil && month != nil) || v > 31 {
                    if year == nil { year = t.count == 2 ? (v < 50 ? 2000 + v : 1900 + v) : (t.count == 3 ? 1900 + v : v) }
                } else if day == nil {
                    day = v
                }
                continue
            }
            if t.allSatisfy(\.isLetter), let h = zoneOffsets[t], offsetSeconds == nil {
                offsetSeconds = t == "ist" ? 19800 : h * 3600
                continue
            }
            // День недели и прочий мусор пропускаем.
        }
        guard let day, let month, let year, (1...31).contains(day) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = min(second, 59)
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone(secondsFromGMT: offsetSeconds ?? 0) ?? TimeZone(identifier: "UTC")!
        return cal.date(from: comps)
    }

    private static func parseNumericZone(_ t: String) -> Int? {
        let sign = t.hasPrefix("-") ? -1 : 1
        let digits = t.dropFirst().filter(\.isNumber)
        guard digits.count >= 2 else { return nil }
        let h: Int, m: Int
        if digits.count >= 4 {
            h = Int(digits.prefix(2)) ?? 0
            m = Int(digits.dropFirst(2).prefix(2)) ?? 0
        } else {
            h = Int(digits.prefix(2)) ?? 0
            m = 0
        }
        guard h <= 14, m < 60 else { return nil }
        return sign * (h * 3600 + m * 60)
    }

    private static func parseISO(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }
}
