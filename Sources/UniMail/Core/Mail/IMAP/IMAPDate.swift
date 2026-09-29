import Foundation

/// Разбор и форматирование дат IMAP/RFC 5322 вручную — без зависимостей от локали и DateFormatter.
enum IMAPDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// INTERNALDATE: `17-Jul-1996 02:44:25 -0700` (день может быть с ведущим пробелом: ` 7-Jul-1996`).
    static func parseInternalDate(_ string: String) -> Date? {
        let parts = string.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { return nil }
        let dmy = parts[0].split(separator: "-")
        guard dmy.count == 3, let day = Int(dmy[0]), let month = monthIndex(dmy[1]), let year = Int(dmy[2]) else { return nil }
        guard let (h, m, s) = parseTime(parts[1]) else { return nil }
        let offset = parts.count > 2 ? (zoneOffset(String(parts[2])) ?? 0) : 0
        return make(year: year, month: month, day: day, hour: h, minute: m, second: s, offsetSeconds: offset)
    }

    /// Дата RFC 5322 (заголовок Date / ENVELOPE): `Mon, 29 Sep 2026 10:15:00 +0300 (MSK)`,
    /// без дня недели, с двузначным годом, с буквенной зоной, а также asctime и ISO 8601.
    static func parseRFC5322(_ string: String) -> Date? {
        var s = string
        // Убираем комментарии в скобках.
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            s.removeSubrange(open...close)
        }
        s = s.replacingOccurrences(of: ",", with: " ")
        var tokens = s.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        if tokens.count == 1 { return parseISO(tokens[0]) }

        // День недели.
        if let first = tokens.first, first.first?.isLetter == true, monthIndex(Substring(first)) == nil {
            tokens.removeFirst()
        }
        guard tokens.count >= 3 else { return nil }

        var day: Int?, month: Int?, year: Int?
        var timeToken: String?
        var zoneToken: String?

        if let m = monthIndex(Substring(tokens[0])) {
            // asctime: "Sep 29 10:15:00 2026" или "Sep 29 2026 10:15:00"
            month = m
            day = Int(tokens[0 + 1])
            for t in tokens.dropFirst(2) {
                if t.contains(":") { timeToken = t } else if let y = Int(t), y > 31 || t.count == 4 { year = y } else if zoneToken == nil { zoneToken = t }
            }
        } else if tokens[0].contains("-"), tokens[0].split(separator: "-").count == 3 {
            // "29-Sep-2026 10:15:00 +0300"
            let dmy = tokens[0].split(separator: "-")
            day = Int(dmy[0]); month = monthIndex(dmy[1]); year = Int(dmy[2])
            if tokens.count > 1 { timeToken = tokens[1] }
            if tokens.count > 2 { zoneToken = tokens[2] }
        } else {
            day = Int(tokens[0])
            month = monthIndex(Substring(tokens[1]))
            year = Int(tokens[2])
            if tokens.count > 3 { timeToken = tokens[3] }
            if tokens.count > 4 { zoneToken = tokens[4] }
            // "29 Sep 2026 10:15:00+0300"
            if let t = timeToken, let sign = t.firstIndex(where: { $0 == "+" || $0 == "-" }) {
                zoneToken = zoneToken ?? String(t[sign...])
                timeToken = String(t[..<sign])
            }
        }
        guard let d = day, let mo = month, var y = year else { return nil }
        if y < 50 { y += 2000 } else if y < 1000 { y += 1900 }
        let (h, mi, se) = timeToken.flatMap { parseTime(Substring($0)) } ?? (0, 0, 0)
        let offset = zoneToken.flatMap(zoneOffset) ?? 0
        return make(year: y, month: mo, day: d, hour: h, minute: mi, second: se, offsetSeconds: offset)
    }

    /// Формат для APPEND/SEARCH: `17-Jul-1996 02:44:25 +0000` (всегда UTC).
    static func formatInternalDate(_ date: Date) -> String {
        let c = components(date)
        func pad(_ v: Int, _ n: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, n - s.count)) + s
        }
        return "\(pad(c.day, 2))-\(monthNames[c.month - 1])-\(pad(c.year, 4)) \(pad(c.hour, 2)):\(pad(c.minute, 2)):\(pad(c.second, 2)) +0000"
    }

    /// Формат даты для SEARCH SINCE/BEFORE: `1-Sep-2026` (UTC).
    static func formatSearchDate(_ date: Date) -> String {
        let c = components(date)
        return "\(c.day)-\(monthNames[c.month - 1])-\(c.year)"
    }

    // MARK: Внутреннее

    private static func monthIndex(_ s: Substring) -> Int? {
        let l = s.prefix(3).lowercased()
        guard s.count >= 3, let i = months.firstIndex(of: l) else { return nil }
        return i + 1
    }

    private static func parseTime(_ s: Substring) -> (Int, Int, Int)? {
        let p = s.split(separator: ":")
        guard p.count >= 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        let sec = p.count > 2 ? Int(p[2].prefix(2)) ?? 0 : 0
        return (h, m, sec)
    }

    private static func zoneOffset(_ z: String) -> Int? {
        if let sign = z.first, sign == "+" || sign == "-" {
            let digits = z.dropFirst().filter(\.isNumber)
            guard digits.count >= 4, let v = Int(digits.prefix(4)) else { return nil }
            let seconds = (v / 100) * 3600 + (v % 100) * 60
            return sign == "-" ? -seconds : seconds
        }
        switch z.uppercased() {
        case "UT", "UTC", "GMT", "Z": return 0
        case "EST": return -5 * 3600
        case "EDT": return -4 * 3600
        case "CST": return -6 * 3600
        case "CDT": return -5 * 3600
        case "MST": return -7 * 3600
        case "MDT": return -6 * 3600
        case "PST": return -8 * 3600
        case "PDT": return -7 * 3600
        case "MSK": return 3 * 3600
        case "CET": return 3600
        case "CEST": return 2 * 3600
        default: return nil
        }
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Дни от 1970-01-01 по гражданскому календарю (алгоритм Хиннанта).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func make(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offsetSeconds: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (0...24).contains(hour), (0...59).contains(minute), (0...61).contains(second) else { return nil }
        let days = daysFromCivil(year, month, day)
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func components(_ date: Date) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        var days = total / 86400
        var rem = total % 86400
        if rem < 0 { rem += 86400; days -= 1 }
        // civil_from_days
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return (y, m, d, rem / 3600, (rem % 3600) / 60, rem % 60)
    }
}
