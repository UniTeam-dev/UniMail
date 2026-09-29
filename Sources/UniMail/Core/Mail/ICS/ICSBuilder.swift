import Foundation

enum ICSPartStat: String, Sendable {
    case accepted = "ACCEPTED"
    case tentative = "TENTATIVE"
    case declined = "DECLINED"
}

/// Сборка iCalendar-ответов (RFC 5546, METHOD:REPLY).
enum ICSBuilder {
    /// VCALENDAR с METHOD:REPLY для организатора. Время — в UTC (весь день — VALUE=DATE).
    /// Отправлять письмом с частью `text/calendar; method=REPLY` (см. `OutgoingMIME.calendar`).
    static func reply(to event: ICSEvent, attendee: Address, status: ICSPartStat, now: Date = Date()) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "PRODID:-//UniMail//RU",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(event.uid)",
            "SEQUENCE:\(event.sequence)",
            "DTSTAMP:\(utcStamp(now))",
        ]
        if event.allDay {
            lines.append("DTSTART;VALUE=DATE:\(dateStamp(event.start))")
            lines.append("DTEND;VALUE=DATE:\(dateStamp(event.end))")
        } else {
            lines.append("DTSTART:\(utcStamp(event.start))")
            lines.append("DTEND:\(utcStamp(event.end))")
        }
        if let org = event.organizer {
            lines.append("ORGANIZER\(cnParam(org.name)):mailto:\(org.email)")
        }
        lines.append("ATTENDEE;PARTSTAT=\(status.rawValue)\(cnParam(attendee.name)):mailto:\(attendee.email)")
        lines.append("SUMMARY:\(escape(event.summary))")
        if let loc = event.location, !loc.isEmpty { lines.append("LOCATION:\(escape(loc))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Форматирование

    static func utcStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func dateStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    /// `;CN="Имя"` — кавычки обязательны при «:;,»; двойные кавычки внутри параметров запрещены.
    private static func cnParam(_ name: String?) -> String {
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return "" }
        let clean = n.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
        return ";CN=\"\(clean)\""
    }

    /// Экранирование TEXT: `\` `;` `,` и переводы строк.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Перенос строк по 75 октетов (RFC 5545 §3.1), не разрывая символы UTF-8.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var parts: [String] = []
        var current = ""
        var currentBytes = 0
        var limit = 75
        for ch in line {
            let n = String(ch).utf8.count
            if currentBytes + n > limit {
                parts.append(current)
                current = ""
                currentBytes = 0
                limit = 74 // продолжение начинается с пробела
            }
            current.append(ch)
            currentBytes += n
        }
        parts.append(current)
        return parts.joined(separator: "\r\n ")
    }
}
