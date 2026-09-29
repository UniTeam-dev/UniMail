import Foundation

/// Событие из iCalendar (VEVENT).
struct ICSEvent: Sendable, Hashable {
    var uid: String
    var summary: String
    var start: Date
    var end: Date
    /// Событие на весь день (VALUE=DATE): start — полночь в текущем часовом поясе, end — исключающий.
    var allDay: Bool
    var location: String?
    var organizer: Address?
    var attendees: [Address]
    var sequence: Int
    /// METHOD календаря: REQUEST, CANCEL, REPLY, PUBLISH…
    var method: String?
}

/// Строка содержимого iCalendar: `NAME;PARAM=V:value`.
struct ICSProperty: Sendable, Hashable {
    var name: String
    /// Ключи параметров — в верхнем регистре; значения без кавычек.
    var params: [String: String]
    var value: String
}

enum ICSParser {
    /// Все VEVENT календаря. События без DTSTART пропускаются. Не падает на битых данных.
    static func parse(_ text: String) -> [ICSEvent] {
        var method: String?
        var eventProps: [[ICSProperty]] = []
        var current: [ICSProperty]?
        var stack: [String] = []
        // VTIMEZONE: TZID → смещение STANDARD (запасной вариант, если TZID неизвестен системе).
        var tzOffsets: [String: Int] = [:]
        var tzid: String?

        for prop in properties(text) {
            switch prop.name {
            case "BEGIN":
                let comp = prop.value.uppercased()
                stack.append(comp)
                if comp == "VEVENT" && stack.count >= 1 && current == nil { current = [] }
                if comp == "VTIMEZONE" { tzid = nil }
            case "END":
                let comp = prop.value.uppercased()
                if let idx = stack.lastIndex(of: comp) { stack.removeSubrange(idx...) }
                if comp == "VEVENT", let c = current { eventProps.append(c); current = nil }
            default:
                guard let top = stack.last else { continue }
                switch top {
                case "VCALENDAR" where prop.name == "METHOD":
                    method = prop.value.uppercased().trimmingCharacters(in: .whitespaces)
                case "VEVENT":
                    current?.append(prop)
                case "VTIMEZONE" where prop.name == "TZID":
                    tzid = prop.value
                case "STANDARD" where prop.name == "TZOFFSETTO":
                    if let tzid, tzOffsets[tzid] == nil, let off = parseUTCOffset(prop.value) { tzOffsets[tzid] = off }
                default:
                    break
                }
            }
        }

        return eventProps.compactMap { makeEvent($0, method: method, tzOffsets: tzOffsets) }
    }

    private static func makeEvent(_ props: [ICSProperty], method: String?, tzOffsets: [String: Int]) -> ICSEvent? {
        func first(_ name: String) -> ICSProperty? { props.first { $0.name == name } }
        guard let dtstart = first("DTSTART"),
              let (start, allDay) = parseDateTime(dtstart, tzOffsets: tzOffsets) else { return nil }
        var end: Date
        if let dtend = first("DTEND"), let (e, _) = parseDateTime(dtend, tzOffsets: tzOffsets) {
            end = e
        } else if let dur = first("DURATION").flatMap({ parseDuration($0.value) }) {
            end = start.addingTimeInterval(dur)
        } else {
            end = allDay ? start.addingTimeInterval(86_400) : start
        }
        if end < start { end = start }

        return ICSEvent(
            uid: first("UID")?.value ?? "",
            summary: unescape(first("SUMMARY")?.value ?? ""),
            start: start,
            end: end,
            allDay: allDay,
            location: first("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
            organizer: first("ORGANIZER").flatMap(address),
            attendees: props.filter { $0.name == "ATTENDEE" }.compactMap(address),
            sequence: first("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0,
            method: method
        )
    }

    // MARK: Строки

    /// Развёртка (строка, начинающаяся с пробела/таба, продолжает предыдущую) и разбор свойств.
    static func properties(_ text: String) -> [ICSProperty] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if let f = raw.first, f == " " || f == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(raw)
            }
        }
        return lines.compactMap(parseLine)
    }

    static func parseLine(_ line: String) -> ICSProperty? {
        var name = ""
        var params: [String: String] = [:]
        var i = line.startIndex
        while i < line.endIndex, line[i] != ";" && line[i] != ":" { name.append(line[i]); i = line.index(after: i) }
        guard !name.isEmpty, i < line.endIndex else { return nil }
        while i < line.endIndex, line[i] == ";" {
            i = line.index(after: i)
            var key = ""
            while i < line.endIndex, line[i] != "=" && line[i] != ":" && line[i] != ";" { key.append(line[i]); i = line.index(after: i) }
            var value = ""
            if i < line.endIndex, line[i] == "=" {
                i = line.index(after: i)
                var inQuotes = false
                while i < line.endIndex {
                    let c = line[i]
                    if c == "\"" { inQuotes.toggle() }
                    else if !inQuotes && (c == ";" || c == ":") { break }
                    else { value.append(c) }
                    i = line.index(after: i)
                }
            }
            params[key.uppercased()] = value
        }
        guard i < line.endIndex, line[i] == ":" else { return nil }
        let value = String(line[line.index(after: i)...])
        return ICSProperty(name: name.uppercased(), params: params, value: value)
    }

    /// `\n`, `\N`, `\,`, `\;`, `\\` → символы.
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for c in s {
            if escaped {
                switch c {
                case "n", "N": out.append("\n")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    private static func address(_ p: ICSProperty) -> Address? {
        var email = p.value.trimmingCharacters(in: .whitespaces)
        if email.lowercased().hasPrefix("mailto:") { email = String(email.dropFirst(7)) }
        if email.isEmpty, let e = p.params["EMAIL"] { email = e }
        guard !email.isEmpty else { return nil }
        let cn = p.params["CN"].map(unescape)?.trimmingCharacters(in: .whitespaces)
        return Address(name: cn?.isEmpty == false ? cn : nil, email: email)
    }

    // MARK: Даты

    /// DTSTART/DTEND: `…Z` (UTC), `TZID=…` (пояс), без зоны (плавающее → текущий пояс), `VALUE=DATE` (весь день).
    static func parseDateTime(_ p: ICSProperty, tzOffsets: [String: Int] = [:]) -> (Date, Bool)? {
        let v = p.value.trimmingCharacters(in: .whitespaces)
        let digits = v.filter(\.isNumber)
        let isDate = p.params["VALUE"]?.uppercased() == "DATE" || (!v.contains("T") && digits.count == 8)
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")

        guard digits.count >= 8, let y = Int(digits.prefix(4)),
              let mo = Int(digits.dropFirst(4).prefix(2)), let d = Int(digits.dropFirst(6).prefix(2)) else { return nil }
        var comps = DateComponents(year: y, month: mo, day: d)
        if isDate {
            cal.timeZone = .current
            return cal.date(from: comps).map { ($0, true) }
        }
        let time = digits.dropFirst(8)
        comps.hour = Int(time.prefix(2)) ?? 0
        comps.minute = Int(time.dropFirst(2).prefix(2)) ?? 0
        comps.second = min(Int(time.dropFirst(4).prefix(2)) ?? 0, 59)
        if v.uppercased().hasSuffix("Z") {
            cal.timeZone = TimeZone(identifier: "UTC")!
        } else if let tzid = p.params["TZID"] {
            cal.timeZone = timeZone(for: tzid, vtimezoneOffsets: tzOffsets)
        } else {
            cal.timeZone = .current
        }
        return cal.date(from: comps).map { ($0, false) }
    }

    /// TZID → TimeZone: IANA, Windows-имя («Russian Standard Time»), Mozilla-префикс,
    /// «(UTC+03:00) Moscow…», смещение из VTIMEZONE; иначе текущий пояс.
    static func timeZone(for rawTZID: String, vtimezoneOffsets: [String: Int] = [:]) -> TimeZone {
        let tzid = rawTZID.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let tz = TimeZone(identifier: tzid) { return tz }
        if let iana = WindowsTimeZones.iana(for: tzid), let tz = TimeZone(identifier: iana) { return tz }
        // /mozilla.org/20050126_1/Europe/Moscow, /softwarestudio.org/Olson_20011030_5/Europe/Moscow
        let comps = tzid.split(separator: "/")
        if comps.count >= 2 {
            for n in [3, 2] where comps.count >= n {
                if let tz = TimeZone(identifier: comps.suffix(n).joined(separator: "/")) { return tz }
            }
        }
        if let off = vtimezoneOffsets[rawTZID] ?? vtimezoneOffsets[tzid], let tz = TimeZone(secondsFromGMT: off) { return tz }
        // «(UTC+03:00) Moscow, St. Petersburg» / «GMT+0300»
        if let r = tzid.range(of: #"(UTC|GMT)\s*[+-]\d{1,2}(:?\d{2})?"#, options: .regularExpression) {
            let s = tzid[r].dropFirst(3).trimmingCharacters(in: .whitespaces)
            if let off = parseUTCOffset(s), let tz = TimeZone(secondsFromGMT: off) { return tz }
        }
        return .current
    }

    /// «+0300», «-05:30», «+3» → секунды.
    static func parseUTCOffset(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let signChar = t.first, signChar == "+" || signChar == "-" else { return nil }
        let sign = signChar == "-" ? -1 : 1
        let digits = t.dropFirst().filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        let h: Int, m: Int
        if digits.count <= 2 { h = Int(digits) ?? 0; m = 0 }
        else if digits.count == 3 { h = Int(digits.prefix(1)) ?? 0; m = Int(digits.suffix(2)) ?? 0 }
        else { h = Int(digits.prefix(2)) ?? 0; m = Int(digits.dropFirst(2).prefix(2)) ?? 0 }
        guard h <= 14, m < 60 else { return nil }
        return sign * (h * 3600 + m * 60)
    }

    /// RFC 5545 DURATION: `P1D`, `PT1H30M`, `-PT15M`, `P1W`, `P1DT2H`.
    static func parseDuration(_ s: String) -> TimeInterval? {
        var t = s.trimmingCharacters(in: .whitespaces).uppercased()
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        guard t.hasPrefix("P") else { return nil }
        t.removeFirst()
        var total = 0.0
        var number = ""
        var inTime = false
        for c in t {
            if c.isNumber { number.append(c); continue }
            if c == "T" { inTime = true; continue }
            guard let n = Double(number) else { return nil }
            switch (c, inTime) {
            case ("W", _): total += n * 604_800
            case ("D", _): total += n * 86_400
            case ("H", true): total += n * 3600
            case ("M", true): total += n * 60
            case ("S", true): total += n
            default: return nil
            }
            number = ""
        }
        return sign * total
    }
}
