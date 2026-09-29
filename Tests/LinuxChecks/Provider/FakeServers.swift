import Foundation

// Фейковые IMAP- и SMTP-серверы поверх ScriptedTransport и тестовые письма.
// Используются проверками Provider и Store.

// MARK: - Фейковый IMAP-сервер

struct FakeMail {
    var uid: UInt32
    var flags: [String]
    var modSeq: UInt64
    var raw: String
    var envelope: String
    var structure: String
    var headerBlock: String
    var text: String
}

final class FakeIMAP: @unchecked Sendable {
    let lock = NSLock()
    var folders: [String: [FakeMail]] = ["INBOX": [], "Sent": [], "Archive": [], "Trash": []]
    var modSeq: UInt64 = 100
    var uidValidity: UInt32 = 7
    var selected = "INBOX"
    var log: [String] = []
    var appended: [String] = []
    /// «Нет связи»: сервер перестаёт отвечать на команды.
    var offline = false

    static let caps = "IMAP4rev1 LITERAL+ UIDPLUS MOVE IDLE ENABLE CONDSTORE AUTH=PLAIN SASL-IR SPECIAL-USE"

    func transport() -> ScriptedTransport {
        ScriptedTransport(greeting: "* OK [CAPABILITY \(Self.caps)] Fake ready\r\n") { [unowned self] line in
            self.lock.withLock { self.respond(line) }
        }
    }

    func literal(_ s: String) -> String { "{\(s.utf8.count)}\r\n\(s)" }

    func unquote(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }

    func uids(_ set: String) -> [UInt32] {
        let all = (folders[selected] ?? []).map(\.uid)
        var result: [UInt32] = []
        for piece in set.split(separator: ",") {
            let bounds = piece.split(separator: ":").map(String.init)
            if bounds.count == 2 {
                let lo = UInt32(bounds[0]) ?? 0
                let hi = bounds[1] == "*" ? (all.max() ?? 0) : (UInt32(bounds[1]) ?? 0)
                let (a, b) = (min(lo, hi), max(lo, hi))
                result += all.filter { $0 >= a && $0 <= b }
                // RFC 3501: n:* всегда включает последнее письмо, даже если n больше.
                if bounds[1] == "*", lo > (all.max() ?? 0), let last = all.max() { result.append(last) }
            } else if let n = UInt32(bounds[0]), all.contains(n) {
                result.append(n)
            }
        }
        return result
    }

    func respond(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .newlines)
        guard let space = line.firstIndex(of: " ") else { return nil }
        let tag = String(line[..<space])
        let rest = String(line[line.index(after: space)...])
        log.append(rest)
        let upper = rest.uppercased()
        if offline { return nil }

        if upper.hasPrefix("AUTHENTICATE PLAIN") {
            return "\(tag) OK [CAPABILITY \(Self.caps)] Logged in\r\n"
        }
        if upper.hasPrefix("LOGIN") { return "\(tag) OK Logged in\r\n" }
        if upper.hasPrefix("CAPABILITY") { return "* CAPABILITY \(Self.caps)\r\n\(tag) OK\r\n" }
        if upper.hasPrefix("ENABLE") { return "* ENABLED CONDSTORE\r\n\(tag) OK Enabled\r\n" }
        if upper.hasPrefix("LIST") {
            return "* LIST (\\HasNoChildren) \"/\" INBOX\r\n"
                + "* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"\r\n"
                + "* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"\r\n"
                + "* LIST (\\HasNoChildren \\Trash) \"/\" \"Trash\"\r\n"
                + "\(tag) OK LIST done\r\n"
        }
        if upper.hasPrefix("EXAMINE") || upper.hasPrefix("SELECT") {
            var name = String(rest.split(separator: " ", maxSplits: 1)[1])
            if name.hasSuffix(" (CONDSTORE)") { name = String(name.dropLast(12)) }
            selected = unquote(name)
            let mails = folders[selected] ?? []
            let next = (mails.map(\.uid).max() ?? 0) + 1
            return "* \(mails.count) EXISTS\r\n* OK [UIDVALIDITY \(uidValidity)] ok\r\n* OK [UIDNEXT \(next)] ok\r\n"
                + "* OK [HIGHESTMODSEQ \(modSeq)] ok\r\n\(tag) OK [\(upper.hasPrefix("EXAMINE") ? "READ-ONLY" : "READ-WRITE")] done\r\n"
        }
        if upper.hasPrefix("UID SEARCH") {
            let criteria = String(rest.dropFirst("UID SEARCH ".count))
            var found: [UInt32]
            if criteria.uppercased().hasPrefix("UID ") {
                found = uids(String(criteria.dropFirst(4)))
            } else if criteria.uppercased().hasPrefix("TEXT") || criteria.uppercased().hasPrefix("X-GM-RAW") {
                let q = unquote(String(criteria.split(separator: " ", maxSplits: 1)[1])).lowercased()
                found = (folders[selected] ?? []).filter { $0.raw.lowercased().contains(q) }.map(\.uid)
            } else {
                found = (folders[selected] ?? []).map(\.uid)
            }
            return "* SEARCH" + found.map { " \($0)" }.joined() + "\r\n\(tag) OK SEARCH done\r\n"
        }
        if upper.hasPrefix("UID FETCH") {
            let parts = rest.split(separator: " ", maxSplits: 3).map(String.init)
            let set = parts[2]
            let items = parts[3]
            var out = ""
            if items.contains("CHANGEDSINCE") {
                let since = UInt64(items.components(separatedBy: "CHANGEDSINCE ").last!.dropLast()) ?? 0
                for (i, m) in (folders[selected] ?? []).enumerated() where m.modSeq > since {
                    out += "* \(i + 1) FETCH (UID \(m.uid) FLAGS (\(m.flags.joined(separator: " "))) MODSEQ (\(m.modSeq)))\r\n"
                }
                return out + "\(tag) OK FETCH done\r\n"
            }
            let wanted = Set(uids(set))
            for (i, m) in (folders[selected] ?? []).enumerated() where wanted.contains(m.uid) {
                if items.contains("ENVELOPE") {
                    out += "* \(i + 1) FETCH (UID \(m.uid) FLAGS (\(m.flags.joined(separator: " "))) INTERNALDATE \"29-Sep-2026 10:00:00 +0300\" RFC822.SIZE \(m.raw.utf8.count) "
                        + "ENVELOPE \(m.envelope) BODYSTRUCTURE \(m.structure) "
                        + "BODY[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] \(literal(m.headerBlock)) MODSEQ (\(m.modSeq)))\r\n"
                } else if items.contains("BODY.PEEK[]") {
                    out += "* \(i + 1) FETCH (UID \(m.uid) BODY[] \(literal(m.raw)))\r\n"
                } else if let r = items.range(of: "BODY.PEEK[") {
                    let section = items[r.upperBound...].prefix { $0 != "]" }
                    out += "* \(i + 1) FETCH (UID \(m.uid) BODY[\(section)]<0> \(literal(m.text)))\r\n"
                } else {
                    out += "* \(i + 1) FETCH (UID \(m.uid) FLAGS (\(m.flags.joined(separator: " "))))\r\n"
                }
            }
            return out + "\(tag) OK FETCH done\r\n"
        }
        if upper.hasPrefix("UID STORE") {
            let parts = rest.split(separator: " ", maxSplits: 4).map(String.init)
            let targets = Set(uids(parts[2]))
            let add = parts[3].hasPrefix("+")
            let flags = parts[4].trimmingCharacters(in: CharacterSet(charactersIn: "()")).split(separator: " ").map(String.init)
            modSeq += 1
            folders[selected] = folders[selected]?.map { m in
                guard targets.contains(m.uid) else { return m }
                var m = m
                m.flags = add ? Array(Set(m.flags + flags)).sorted() : m.flags.filter { !flags.contains($0) }
                m.modSeq = modSeq
                return m
            }
            return "\(tag) OK STORE done\r\n"
        }
        if upper.hasPrefix("UID MOVE") {
            let parts = rest.split(separator: " ", maxSplits: 3).map(String.init)
            let targets = Set(uids(parts[2]))
            let dest = unquote(parts[3])
            let moving = (folders[selected] ?? []).filter { targets.contains($0.uid) }
            folders[selected]?.removeAll { targets.contains($0.uid) }
            folders[dest, default: []] += moving
            return "\(tag) OK MOVE done\r\n"
        }
        if upper.hasPrefix("UID EXPUNGE") {
            return "\(tag) OK EXPUNGE done\r\n"
        }
        if offline { return nil }
        if upper.hasPrefix("APPEND") {
            appended.append(rest)
            // Кладём письмо в папку, чтобы следующая синхронизация его увидела.
            let folder = unquote(String(rest.dropFirst(7).prefix { $0 != " " }))
            if let r = rest.range(of: "Message-ID: <"), let end = rest[r.upperBound...].firstIndex(of: ">") {
                let id = String(rest[r.upperBound..<end])
                let uid = (folders[folder]?.map(\.uid).max() ?? 0) + 1
                modSeq += 1
                folders[folder, default: []].append(FakeMail(
                    uid: uid, flags: ["\\Seen"], modSeq: modSeq, raw: "Message-ID: <\(id)>\r\n\r\nsent\r\n",
                    envelope: envelope(subject: "Re: Отчёт", from: "me@example.com", messageID: id, inReplyTo: "m2@example.ru"),
                    structure: plainStructure, headerBlock: "\r\n", text: "Спасибо!"))
            }
            return "\(tag) OK [APPENDUID \(uidValidity) 50] APPEND done\r\n"
        }
        if upper.hasPrefix("NOOP") { return "\(tag) OK NOOP\r\n" }
        if upper.hasPrefix("LOGOUT") { return "* BYE\r\n\(tag) OK LOGOUT\r\n" }
        return "\(tag) BAD unknown \(rest)\r\n"
    }
}

// MARK: - Фейковый SMTP-сервер

final class FakeSMTP: @unchecked Sendable {
    let lock = NSLock()
    var commands: [String] = []
    var messages: [String] = []
    var inData = false
    var buffer = ""

    func transport() -> ScriptedTransport {
        ScriptedTransport(greeting: "220 fake.smtp ESMTP\r\n") { [unowned self] text in
            self.lock.withLock { self.respond(text) }
        }
    }

    func respond(_ text: String) -> String? {
        if inData {
            buffer += text
            if buffer.hasSuffix("\r\n.\r\n") {
                inData = false
                messages.append(buffer)
                buffer = ""
                return "250 2.0.0 queued\r\n"
            }
            return nil
        }
        let line = text.trimmingCharacters(in: .newlines)
        commands.append(line)
        let upper = line.uppercased()
        if upper.hasPrefix("EHLO") { return "250-fake.smtp\r\n250-AUTH PLAIN LOGIN\r\n250-8BITMIME\r\n250 SIZE 10000000\r\n" }
        if upper.hasPrefix("AUTH PLAIN") { return "235 2.7.0 ok\r\n" }
        if upper.hasPrefix("MAIL FROM") || upper.hasPrefix("RCPT TO") { return "250 ok\r\n" }
        if upper == "DATA" { inData = true; return "354 go\r\n" }
        if upper == "QUIT" { return "221 bye\r\n" }
        return "502 unknown\r\n"
    }
}

// MARK: - Письма

func envelope(subject: String, from: String, messageID: String, inReplyTo: String?) -> String {
    let parts = from.split(separator: "@")
    let irt = inReplyTo.map { "\"<\($0)>\"" } ?? "NIL"
    return "(\"Tue, 29 Sep 2026 10:00:00 +0300\" \"\(subject)\" ((\"Иван\" NIL \"\(parts[0])\" \"\(parts[1])\")) NIL NIL "
        + "((NIL NIL \"me\" \"example.com\")) NIL NIL \(irt) \"<\(messageID)>\")"
}

let plainStructure = "(\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"8bit\" 40 2 NIL NIL NIL NIL)"
let mixedStructure = "((\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"8bit\" 100 3 NIL NIL NIL NIL)"
    + "(\"image\" \"png\" (\"name\" \"logo.png\") \"<logo1>\" NIL \"base64\" 8 NIL (\"inline\" NIL) NIL NIL)"
    + "(\"application\" \"pdf\" (\"name\" \"report.pdf\") NIL NIL \"base64\" 12 NIL (\"attachment\" (\"filename\" \"report.pdf\")) NIL NIL)"
    + "(\"text\" \"calendar\" (\"charset\" \"utf-8\" \"method\" \"REQUEST\") NIL NIL \"8bit\" 200 8 NIL NIL NIL NIL)"
    + " \"mixed\" (\"boundary\" \"b1\") NIL NIL NIL)"

let mail1Raw = "Message-ID: <m1@example.ru>\r\nFrom: Иван <ivan@example.ru>\r\nTo: me@example.com\r\nSubject: Отчёт\r\n"
    + "Date: Tue, 29 Sep 2026 10:00:00 +0300\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nПривет! Отчёт готов.\r\n"

let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:ev-1\r\nSUMMARY:Созвон по отчёту\r\n"
    + "DTSTART:20261001T090000Z\r\nDTEND:20261001T093000Z\r\nLOCATION:Zoom\r\nORGANIZER;CN=Иван:mailto:ivan@example.ru\r\n"
    + "ATTENDEE;CN=Me:mailto:me@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

let mail2Raw = "Message-ID: <m2@example.ru>\r\nIn-Reply-To: <m1@example.ru>\r\nReferences: <m1@example.ru>\r\n"
    + "From: Иван <ivan@example.ru>\r\nTo: me@example.com\r\nSubject: Re: Отчёт\r\nDate: Tue, 29 Sep 2026 11:00:00 +0300\r\n"
    + "List-Unsubscribe: <mailto:unsub@example.ru>, <https://example.ru/unsub?id=1>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n"
    + "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n"
    + "--b1\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Смотрите <img src=\"cid:logo1\"> и вложение</p>\r\n"
    + "--b1\r\nContent-Type: image/png; name=\"logo.png\"\r\nContent-ID: <logo1>\r\nContent-Disposition: inline\r\nContent-Transfer-Encoding: base64\r\n\r\niVBORw0KGgo=\r\n"
    + "--b1\r\nContent-Type: application/pdf; name=\"report.pdf\"\r\nContent-Disposition: attachment; filename=\"report.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERi0xLjQK\r\n"
    + "--b1\r\nContent-Type: text/calendar; charset=utf-8; method=REQUEST\r\n\r\n" + ics
    + "--b1--\r\n"

let mail1 = FakeMail(uid: 1, flags: [], modSeq: 90, raw: mail1Raw,
                     envelope: envelope(subject: "Отчёт", from: "ivan@example.ru", messageID: "m1@example.ru", inReplyTo: nil),
                     structure: plainStructure, headerBlock: "Content-Type: text/plain; charset=utf-8\r\n\r\n",
                     text: "Привет! Отчёт готов.")
let mail2 = FakeMail(uid: 2, flags: [], modSeq: 95, raw: mail2Raw,
                     envelope: envelope(subject: "Re: Отчёт", from: "ivan@example.ru", messageID: "m2@example.ru", inReplyTo: "m1@example.ru"),
                     structure: mixedStructure,
                     headerBlock: "References: <m1@example.ru>\r\nList-Unsubscribe: <mailto:unsub@example.ru>, <https://example.ru/unsub?id=1>\r\n"
                        + "List-Unsubscribe-Post: List-Unsubscribe=One-Click\r\nContent-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n",
                     text: "<p>Смотрите и вложение</p>")
let mail3 = FakeMail(uid: 3, flags: ["\\Seen"], modSeq: 102, raw: mail1Raw.replacingOccurrences(of: "m1@", with: "m3@"),
                     envelope: envelope(subject: "Новое", from: "olga@example.ru", messageID: "m3@example.ru", inReplyTo: nil),
                     structure: plainStructure, headerBlock: "\r\n", text: "Новое письмо")

