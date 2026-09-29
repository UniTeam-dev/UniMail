// Linux-проверки IMAP-модуля UniMail: парсер, modified UTF-7, RFC 2047, даты, роли папок,
// BODYSTRUCTURE и полные сценарии IMAPClient поверх ScriptedTransport (Dovecot, Gmail, Exchange).
//
// Сборка и запуск (из корня проекта UniMailClient):
//
//   SWIFTC=/tmp/claude-0/-home-claude/7ab09e26-48a3-5891-ac64-9f910eb6e912/scratchpad/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin/swiftc
//   $SWIFTC -swift-version 5 \
//       Sources/UniMail/Core/Models/*.swift \
//       Sources/UniMail/Core/Mail/Transport.swift \
//       Sources/UniMail/Core/Mail/IMAP/*.swift \
//       Tests/LinuxChecks/IMAP/main.swift \
//       -o /tmp/claude-0/-home-claude/7ab09e26-48a3-5891-ac64-9f910eb6e912/scratchpad/imaptest \
//   && /tmp/claude-0/-home-claude/7ab09e26-48a3-5891-ac64-9f910eb6e912/scratchpad/imaptest
//
// На macOS то же самое: `swiftc -swift-version 5 <те же файлы> -o /tmp/imaptest && /tmp/imaptest`.
// Код возврата 0 — все проверки прошли; иначе печатается список FAIL и код 1.

import Foundation

// MARK: - Мини-фреймворк проверок

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed: [String] = []

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        failed.append("\(name) (line \(line))")
        print("FAIL \(name) (line \(line))")
    }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    if actual == expected {
        passed += 1
        print("PASS \(name)")
    } else {
        failed.append("\(name) (line \(line)): got \(actual), expected \(expected)")
        print("FAIL \(name) (line \(line))\n     got:      \(actual)\n     expected: \(expected)")
    }
}

func expectError(_ name: String, line: Int = #line, _ matches: (Error) -> Bool, _ body: () async throws -> Void) async {
    do {
        try await body()
        failed.append("\(name) (line \(line)): no error thrown")
        print("FAIL \(name) (line \(line)): no error thrown")
    } catch {
        check(matches(error), name + " [\(error)]", line: line)
    }
}

func section(_ title: String) { print("\n== \(title) ==") }

// MARK: - Помощники транскриптов

/// Строки ответа сервера, склеенные через CRLF (с CRLF в конце).
func lines(_ l: String...) -> String { l.joined(separator: "\r\n") + "\r\n" }

/// IMAP-литерал `{n}\r\n<байты>` — n считается в байтах UTF-8.
func lit(_ s: String) -> String { "{\(s.utf8.count)}\r\n" + s }

func raw(_ s: String, _ literals: [String] = []) -> IMAPRawResponse {
    IMAPRawResponse(s, literals: literals.map { Data($0.utf8) })
}

/// «Сервер» для ScriptedTransport: разбирает тег команды и отдаёт ответ из обработчика.
final class FakeServer: @unchecked Sendable {
    var lastTag = ""
    /// Команды без тега (первая строка записи).
    var commands: [String] = []
    /// Полные записи клиента, начинающиеся с тега.
    var fullWrites: [String] = []
    /// Записи без тега: продолжения литералов, DONE, ответы AUTHENTICATE.
    var rawWrites: [String] = []
    let onCommand: (FakeServer, String, String) -> String?
    var onRaw: (FakeServer, String) -> String?

    init(onCommand: @escaping (FakeServer, String, String) -> String?,
         onRaw: @escaping (FakeServer, String) -> String? = { _, _ in nil }) {
        self.onCommand = onCommand
        self.onRaw = onRaw
    }

    func handle(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        if bytes.count > 6, bytes[0] == UInt8(ascii: "A"), bytes[1...4].allSatisfy({ $0 >= 48 && $0 <= 57 }), bytes[5] == 32 {
            lastTag = String(text.prefix(5))
            var line = String(text.dropFirst(6))
            if let r = line.range(of: "\r\n") { line = String(line[..<r.lowerBound]) }
            commands.append(line)
            fullWrites.append(text)
            return onCommand(self, lastTag, line)
        }
        rawWrites.append(text)
        return onRaw(self, text)
    }

    func makeTransport(greeting: String) -> ScriptedTransport {
        ScriptedTransport(greeting: greeting) { [self] text in self.handle(text) }
    }
}

// MARK: - 1. Токенизатор и парсер ответов

section("Parser")
do {
    if case .tagged(let tag, let s) = IMAPResponseParser.parse(raw("a0001 ok [READ-WRITE] SELECT completed")) {
        eq(tag, "a0001", "tagged: tag")
        eq(s.status, .ok, "tagged: lowercase ok")
        eq(s.code?.name, "READ-WRITE", "tagged: code READ-WRITE")
        eq(s.text, "SELECT completed", "tagged: text")
    } else { check(false, "tagged parse") }

    if case .tagged(_, let s) = IMAPResponseParser.parse(raw("A0002 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)")) {
        eq(s.status, .no, "tagged NO")
        eq(s.code?.name, "AUTHENTICATIONFAILED", "tagged NO code")
        eq(s.text, "Invalid credentials (Failure)", "tagged NO text")
    } else { check(false, "tagged NO parse") }

    if case .tagged(_, let s) = IMAPResponseParser.parse(raw("A0003 BAD Command Argument Error. 11")) {
        eq(s.status, .bad, "tagged BAD")
    } else { check(false, "tagged BAD parse") }

    if case .untagged(.status(let s)) = IMAPResponseParser.parse(raw("* OK [UIDVALIDITY 3857529045] UIDs valid")) {
        eq(s.code?.name, "UIDVALIDITY", "untagged OK code")
        eq(s.code?.firstNumber, 3857529045, "UIDVALIDITY number")
    } else { check(false, "untagged OK parse") }

    if case .untagged(.status(let s)) = IMAPResponseParser.parse(raw("* OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft \\*)] Flags permitted.")) {
        eq(s.code?.arguments.first?.list?.compactMap(\.text) ?? [], ["\\Answered", "\\Flagged", "\\Deleted", "\\Seen", "\\Draft", "\\*"], "PERMANENTFLAGS list")
    } else { check(false, "PERMANENTFLAGS parse") }

    if case .tagged(_, let s) = IMAPResponseParser.parse(raw("A0009 OK [APPENDUID 38505 3955] APPEND completed")) {
        eq(s.code?.arguments.compactMap(\.number) ?? [], [38505, 3955], "APPENDUID args")
    } else { check(false, "APPENDUID parse") }

    if case .untagged(.status(let s)) = IMAPResponseParser.parse(raw("* OK [CAPABILITY IMAP4rev1 SASL-IR LITERAL+ AUTH=PLAIN] Dovecot ready.")) {
        eq(s.code?.atoms ?? [], ["IMAP4rev1", "SASL-IR", "LITERAL+", "AUTH=PLAIN"], "CAPABILITY code atoms")
        eq(s.text, "Dovecot ready.", "greeting text")
    } else { check(false, "CAPABILITY code parse") }

    if case .untagged(.status(let s)) = IMAPResponseParser.parse(raw("* OK [ALERT]Password expires soon")) {
        eq(s.code?.name, "ALERT", "code without trailing space")
        eq(s.text, "Password expires soon", "text right after ]")
    } else { check(false, "ALERT parse") }

    eq(IMAPResponseParser.parse(raw("+ idling")), .continuation("idling"), "continuation")
    eq(IMAPResponseParser.parse(raw("+")), .continuation(""), "bare continuation")
    eq(IMAPResponseParser.parse(raw("* 23 EXISTS")), .untagged(.exists(23)), "EXISTS")
    eq(IMAPResponseParser.parse(raw("* 5 expunge")), .untagged(.expunge(5)), "lowercase EXPUNGE")
    eq(IMAPResponseParser.parse(raw("* SEARCH 2 84 882")), .untagged(.search([2, 84, 882])), "SEARCH")
    eq(IMAPResponseParser.parse(raw("* SEARCH 2 84 (MODSEQ 917162500)")), .untagged(.search([2, 84])), "SEARCH with MODSEQ")
    eq(IMAPResponseParser.parse(raw("* SEARCH")), .untagged(.search([])), "empty SEARCH")
    eq(IMAPResponseParser.parse(raw("* ESEARCH (TAG \"A0005\") UID ALL 1:3,7")), .untagged(.esearch([1, 2, 3, 7])), "ESEARCH")
    eq(IMAPResponseParser.parse(raw("* ENABLED CONDSTORE QRESYNC")), .untagged(.enabled(["CONDSTORE", "QRESYNC"])), "ENABLED")
    eq(IMAPResponseParser.parse(raw("* VANISHED (EARLIER) 41,43:45")), .untagged(.vanished(earlier: true, uids: [41, 43, 44, 45])), "VANISHED")
    eq(IMAPResponseParser.parse(raw("* capability imap4rev1 idle")), .untagged(.capability(["IMAP4REV1", "IDLE"])), "lowercase CAPABILITY")

    // Строки в кавычках с экранированием, NIL, пустые списки, лишние пробелы.
    var t = IMAPTokenizer(raw(#"("a \"b\" c\\d" NIL nil ()   (x  (y)) "")"#))
    if case .list(let items)? = t.value() {
        eq(items.count, 6, "list item count")
        eq(items[0].text, #"a "b" c\d"#, "quoted escapes")
        check(items[1].isNil && items[2].isNil, "NIL / nil")
        eq(items[3], .list([]), "empty list")
        eq(items[4], .list([.atom("x"), .list([.atom("y")])]), "nested list with extra spaces")
        eq(items[5], .string(Data()), "empty quoted")
    } else { check(false, "tokenizer list") }

    // Атомы с квадратными скобками и частичной выборкой.
    var t2 = IMAPTokenizer(raw("BODY[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE)]<0> {5}", ["hello"]))
    eq(t2.value(), .atom("BODY[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE)]<0>"), "bracket atom")
    eq(t2.value(), .string(Data("hello".utf8)), "literal after bracket atom")

    // literal8 и несколько литералов подряд.
    var t3 = IMAPTokenizer(raw("(~{3} {2} {0})", ["abc", "de", ""]))
    eq(t3.value(), .list([.string(Data("abc".utf8)), .string(Data("de".utf8)), .string(Data())]), "literal8 + literals")

    eq(IMAPResponseParser.trailingLiteralLength(Array("* 1 FETCH (BODY[] {1234}".utf8)), 1234, "trailing literal")
    eq(IMAPResponseParser.trailingLiteralLength(Array("A1 APPEND x {12+}".utf8)), 12, "trailing literal+")
    eq(IMAPResponseParser.trailingLiteralLength(Array("* 1 FETCH (BINARY[1] ~{77}".utf8)), 77, "trailing literal8")
    eq(IMAPResponseParser.trailingLiteralLength(Array("* OK \"x {5}\"".utf8)), nil, "no literal in quoted")
    eq(IMAPResponseParser.trailingLiteralLength(Array("* OK {}".utf8)), nil, "empty braces")

    // FETCH с литералом внутри ENVELOPE.
    let fetchRaw = raw("* 12 FETCH (UID 99 FLAGS (\\Seen) ENVELOPE (NIL {11}\r\n NIL NIL NIL NIL NIL NIL NIL NIL) BODY[] {4}\r\n)",
                       ["Hello world", "abcd"])
    if case .untagged(.fetch(let seq, let attrs)) = IMAPResponseParser.parse(fetchRaw) {
        eq(seq, 12, "fetch seq")
        eq(attrs.uid, 99, "fetch uid")
        eq(attrs["ENVELOPE"]?.list?[1].text, "Hello world", "literal inside envelope")
        eq(attrs["BODY[]"]?.data, Data("abcd".utf8), "BODY[] literal")
    } else { check(false, "FETCH parse") }

    // LIST с modified UTF-7.
    if case .untagged(.list(let e)) = IMAPResponseParser.parse(raw(#"* LIST (\HasNoChildren \Sent) "/" "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-""#)) {
        eq(e.name, "Отправленные", "LIST mUTF-7 name")
        eq(e.delimiter, "/", "LIST delimiter")
        eq(e.attributes, ["\\HasNoChildren", "\\Sent"], "LIST attributes")
    } else { check(false, "LIST parse") }
    if case .untagged(.list(let e)) = IMAPResponseParser.parse(raw(#"* LIST (\Noselect) NIL [Gmail]"#)) {
        eq(e.name, "[Gmail]", "LIST atom name with brackets")
        eq(e.delimiter, nil, "LIST NIL delimiter")
    } else { check(false, "LIST atom parse") }

    eq(IMAPSequenceSet.compress([10, 1, 2, 3, 4, 5, 8, 11, 12, 3]), "1:5,8,10:12", "UID set compress")
    eq(IMAPSequenceSet.compress([7]), "7", "UID set single")
    eq(IMAPSequenceSet.expand("1:3,7,9:8"), [1, 2, 3, 7, 8, 9], "UID set expand")
}

// MARK: - 2. Modified UTF-7

section("IMAPUTF7")
do {
    eq(IMAPUTF7.decode("&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-"), "Отправленные", "decode Отправленные")
    eq(IMAPUTF7.encode("Отправленные"), "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-", "encode Отправленные")
    eq(IMAPUTF7.encode("[Gmail]/Вся почта"), "[Gmail]/&BBIEQQRP- &BD8EPgRHBEIEMA-", "encode Gmail Вся почта")
    eq(IMAPUTF7.encode("Отчёты & планы"), "&BB4EQgRHBFEEQgRL- &- &BD8EOwQwBD0ESw-", "encode with &")
    eq(IMAPUTF7.encode("日本語 😀"), "&ZeVnLIqe- &2D3eAA-", "encode CJK + surrogate pair")
    for s in ["INBOX", "Отчёты & планы", "日本語 😀", "Work/Проекты/2026", "a&b", "~peter/mail/台北/日本語"] {
        eq(IMAPUTF7.decode(IMAPUTF7.encode(s)), s, "round trip \(s)")
    }
    eq(IMAPUTF7.decode("AT&T"), "AT&T", "unterminated & left as is")
    eq(IMAPUTF7.decode("A&-B"), "A&B", "&- decodes to &")
    eq(IMAPUTF7.decode("x&!!!-y"), "x&!!!-y", "invalid base64 left as is")
}

// MARK: - 3. RFC 2047 и кодировки

section("IMAPHeaderDecoding")
do {
    eq(IMAPHeaderDecoding.decode("=?UTF-8?B?0J/RgNC40LLQtdGCLCDQvNC40YA=?="), "Привет, мир", "B utf-8")
    eq(IMAPHeaderDecoding.decode("=?windows-1251?Q?=CF=F0=E8=E2=E5=F2?="), "Привет", "Q windows-1251")
    eq(IMAPHeaderDecoding.decode("=?koi8-r?B?8NLJ18XU?="), "Привет", "B koi8-r")
    eq(IMAPHeaderDecoding.decode("=?UTF-8?B?0J7RgtGH0Q==?= =?UTF-8?B?kdGCINC30LAg0YHQtdC90YLRj9Cx0YDRjA==?="), "Отчёт за сентябрь", "split multibyte across words")
    eq(IMAPHeaderDecoding.decode("Re: =?utf-8?q?caf=C3=A9_au_lait?= today"), "Re: café au lait today", "Q utf-8 mixed with text")
    eq(IMAPHeaderDecoding.decode("=?iso-8859-1?q?caf=E9?="), "café", "Q iso-8859-1")
    eq(IMAPHeaderDecoding.decode("=?ISO-8859-5?Q?=BF=E0=D8=D2=D5=E2?="), "Привет", "Q iso-8859-5")
    eq(IMAPHeaderDecoding.decode("=?us-ascii?Q?Hello_World?="), "Hello World", "Q us-ascii")
    eq(IMAPHeaderDecoding.decode("=?UTF-8*ru?B?0J/RgNC40LLQtdGC?="), "Привет", "charset with language")
    eq(IMAPHeaderDecoding.decode("=?utf-8?B?0J/RgNC40LLQtdGC?=\r\n =?windows-1251?Q?=2C_=EC=E8=F0?="), "Привет, мир", "folded mixed charsets")
    eq(IMAPHeaderDecoding.decode("Price =? 100"), "Price =? 100", "not an encoded word")
    eq(IMAPHeaderDecoding.decode("=?utf-8?x?abc?="), "=?utf-8?x?abc?=", "unknown encoding kept")
    eq(IMAPHeaderDecoding.decodeText(Data([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]), charset: nil), "Привет", "raw 8-bit fallback cp1251")
    eq(IMAPHeaderDecoding.decodeText(Data("Привет".utf8), charset: nil), "Привет", "raw 8-bit utf-8")
    eq(IMAPHeaderDecoding.decodeText(Data([0x80, 0xB9]), charset: "windows-1251"), "Ђ№", "cp1251 high table")
    eq(IMAPHeaderDecoding.decodeText(Data([0xA3, 0xB3]), charset: "KOI8-R"), "ёЁ", "koi8-r ё/Ё")
    eq(IMAPHeaderDecoding.decodeText(Data([0x80, 0x93]), charset: "\"windows-1252\""), "€“", "cp1252 quoted charset")
    eq(String(decoding: IMAPHeaderDecoding.decodeQuotedPrintable(Data("a=3Db=\r\nc=".utf8)), as: UTF8.self), "a=bc", "QP soft break + truncated")
    eq(String(decoding: IMAPHeaderDecoding.decodeBase64(Data("0J/R\r\ngNC4\n0LLQtdGC".utf8)), as: UTF8.self), "Привет", "base64 with line breaks")

    let headers = IMAPHeaderDecoding.parseHeaderBlock(Data("References: <a1@x>\r\n\t<a2@x>\r\nLIST-Unsubscribe: <mailto:u@x>,\r\n <https://x/u>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n\r\n".utf8))
    eq(headers["references"], "<a1@x> <a2@x>", "header unfold")
    eq(headers["list-unsubscribe"], "<mailto:u@x>, <https://x/u>", "header case-insensitive + unfold")
    eq(headers["list-unsubscribe-post"], "List-Unsubscribe=One-Click", "header post")

    eq(IMAPHeaderDecoding.stripHTML("<p>A&nbsp;&amp;&#1041;&#x411;</p><style>x{}</style>").trimmingCharacters(in: .whitespacesAndNewlines), "A &ББ", "strip html + entities")
    let longText = String(repeating: "слово ", count: 100)
    eq(IMAPHeaderDecoding.previewText(from: Data(longText.utf8), encoding: "8bit", charset: "utf-8", isHTML: false)?.count, 200, "preview limited to 200")
    // Обрезанный base64 и обрезанный UTF-8.
    let b64 = Data("Привет, мир! Как дела?".utf8).base64EncodedString()
    let cut = Data(b64.utf8.prefix(22))
    eq(IMAPHeaderDecoding.previewText(from: cut, encoding: "base64", charset: "utf-8", isHTML: false), "Привет,", "truncated base64 preview (partial char dropped)")
}

// MARK: - 4. Даты

section("IMAPDate")
do {
    eq(IMAPDate.parseInternalDate("17-Jul-1996 02:44:25 -0700")?.timeIntervalSince1970, 837596665, "INTERNALDATE")
    eq(IMAPDate.parseInternalDate(" 7-Sep-2026 09:05:01 +0000")?.timeIntervalSince1970, 1788771901, "INTERNALDATE leading space")
    eq(IMAPDate.parseRFC5322("Tue, 29 Sep 2026 10:15:00 +0300 (MSK)")?.timeIntervalSince1970, 1790666100, "RFC5322 with comment")
    eq(IMAPDate.parseRFC5322("29 Sep 2026 07:15:00 GMT")?.timeIntervalSince1970, 1790666100, "RFC5322 no weekday GMT")
    eq(IMAPDate.parseRFC5322("Tue, 29 Sep 26 03:15 EDT")?.timeIntervalSince1970, 1790666100, "RFC5322 2-digit year, no seconds, EDT")
    eq(IMAPDate.parseRFC5322("Tue Sep 29 07:15:00 2026")?.timeIntervalSince1970, 1790666100, "asctime")
    eq(IMAPDate.parseRFC5322("Tue,29 Sep 2026 10:15:00+0300")?.timeIntervalSince1970, 1790666100, "glued zone")
    eq(IMAPDate.parseRFC5322("2026-09-29T07:15:00Z")?.timeIntervalSince1970, 1790666100, "ISO 8601")
    eq(IMAPDate.parseRFC5322("garbage"), nil, "garbage date")
    eq(IMAPDate.formatInternalDate(Date(timeIntervalSince1970: 1790666100)), "29-Sep-2026 07:15:00 +0000", "format INTERNALDATE")
    eq(IMAPDate.formatInternalDate(Date(timeIntervalSince1970: 837596665)), "17-Jul-1996 09:44:25 +0000", "format 1996")
    eq(IMAPDate.formatSearchDate(Date(timeIntervalSince1970: 1788771901)), "7-Sep-2026", "format SEARCH date")
}

// MARK: - 5. Роли папок

section("IMAPFolderRoles")
do {
    func roles(_ list: [(String, String?, [String])]) -> [String: MailboxRole?] {
        var folders = list.map { IMAPFolder(name: $0.0, delimiter: $0.1, attributes: Set($0.2), role: nil) }
        IMAPFolderRoles.assignRoles(&folders)
        var out: [String: MailboxRole?] = [:]
        for f in folders { out[f.name] = f.role }
        return out
    }
    // Exchange on-prem (англ.) без SPECIAL-USE.
    let ex = roles([("INBOX", "/", []), ("Sent Items", "/", []), ("Deleted Items", "/", []), ("Junk E-mail", "/", []),
                    ("Drafts", "/", []), ("Archive", "/", []), ("Outbox", "/", []), ("INBOX/Sent", "/", []), ("Calendar", "/", ["\\HasChildren"])])
    eq(ex["INBOX"]!, .inbox, "exchange INBOX")
    eq(ex["Sent Items"]!, .sent, "exchange Sent Items")
    eq(ex["Deleted Items"]!, .trash, "exchange Deleted Items")
    eq(ex["Junk E-mail"]!, .spam, "exchange Junk E-mail")
    eq(ex["Drafts"]!, .drafts, "exchange Drafts")
    eq(ex["Archive"]!, .archive, "exchange Archive")
    eq(ex["Outbox"]!, nil, "exchange Outbox has no role")
    eq(ex["INBOX/Sent"]!, nil, "top-level Sent Items wins over INBOX/Sent")
    // Exchange/Outlook по-русски, Mail.ru, Яндекс без SPECIAL-USE.
    let ru = roles([("INBOX", "|", []), ("Отправленные", "|", []), ("Удаленные", "|", []), ("Черновики", "|", []),
                    ("Нежелательная почта", "|", []), ("Архив", "|", []), ("Работа|Спам", "|", [])])
    eq(ru["Отправленные"]!, .sent, "ru Отправленные")
    eq(ru["Удаленные"]!, .trash, "ru Удаленные")
    eq(ru["Черновики"]!, .drafts, "ru Черновики")
    eq(ru["Нежелательная почта"]!, .spam, "ru Нежелательная почта")
    eq(ru["Архив"]!, .archive, "ru Архив")
    eq(ru["Работа|Спам"]!, nil, "nested user folder ignored")
    let mailru = roles([("INBOX", "/", []), ("Корзина", "/", []), ("Спам", "/", []), ("Удалённые", "/", [])])
    eq(mailru["Корзина"]!, .trash, "mail.ru Корзина (first match)")
    eq(mailru["Спам"]!, .spam, "mail.ru Спам")
    eq(mailru["Удалённые"]!, nil, "second trash candidate not assigned")
    // Courier: INBOX.Sent.
    let courier = roles([("INBOX", ".", []), ("INBOX.Sent", ".", []), ("INBOX.Trash", ".", []), ("INBOX.Junk", ".", []), ("INBOX.Drafts", ".", [])])
    eq(courier["INBOX.Sent"]!, .sent, "courier INBOX.Sent")
    eq(courier["INBOX.Trash"]!, .trash, "courier INBOX.Trash")
    eq(courier["INBOX.Junk"]!, .spam, "courier INBOX.Junk")
    // SPECIAL-USE побеждает эвристику; \All уступает \Archive.
    let su = roles([("INBOX", "/", []), ("Sent", "/", []), ("Отправленные", "/", ["\\Sent"]), ("All", "/", ["\\All"]),
                    ("Archive", "/", ["\\Archive"]), ("Spam", "/", ["\\Junk"]), ("Flagged", "/", ["\\Flagged"])])
    eq(su["Отправленные"]!, .sent, "SPECIAL-USE \\Sent")
    eq(su["Sent"]!, nil, "heuristic skipped when role claimed")
    eq(su["Archive"]!, .archive, "\\Archive is archive")
    eq(su["All"]!, nil, "\\All yields to \\Archive")
    eq(su["Flagged"]!, .flagged, "\\Flagged")
    // Gmail локализованный без атрибутов (старый XLIST-подобный сервер).
    let gm = roles([("INBOX", "/", []), ("[Gmail]", "/", ["\\Noselect"]), ("[Gmail]/Вся почта", "/", []),
                    ("[Gmail]/Помеченные", "/", []), ("[Google Mail]/Bin", "/", [])])
    eq(gm["[Gmail]/Вся почта"]!, .archive, "gmail Вся почта heuristic")
    eq(gm["[Gmail]/Помеченные"]!, .flagged, "gmail Помеченные heuristic")
    eq(gm["[Google Mail]/Bin"]!, .trash, "google mail Bin")
    eq(gm["[Gmail]"]!, nil, "noselect parent")
}

// MARK: - 6. BODYSTRUCTURE

section("IMAPBodyPart")
do {
    func structure(_ s: String) -> IMAPBodyPart? {
        var t = IMAPTokenizer(raw(s))
        return t.value().flatMap(IMAPBodyPart.parse)
    }
    let mixed = structure(#"((("text" "plain" ("charset" "windows-1251") NIL NIL "quoted-printable" 312 9 NIL NIL NIL NIL)("text" "html" ("charset" "utf-8") NIL NIL "base64" 1024 14 NIL NIL NIL NIL) "alternative" ("boundary" "b2") NIL NIL NIL)("application" "pdf" ("name" "report.pdf") NIL NIL "base64" 48210 NIL ("attachment" ("filename" "=?UTF-8?B?0J7RgtGH0ZHRgi5wZGY=?=")) NIL NIL) "mixed" ("boundary" "b1") NIL NIL NIL)"#)
    eq(mixed?.mimeType, "multipart/mixed", "mixed type")
    eq(mixed?.hasAttachments, true, "mixed with pdf has attachments")
    eq(mixed?.previewPart?.partNumber, "1.1", "preview part 1.1")
    eq(mixed?.previewPart?.charset, "windows-1251", "preview charset")
    eq(mixed?.previewPart?.encoding, "quoted-printable", "preview encoding")
    eq(mixed?.leaves.map(\.partNumber) ?? [], ["1.1", "1.2", "2"], "leaf part numbers")
    eq(mixed?.leaves.last?.filename, "Отчёт.pdf", "attachment filename RFC2047")
    eq(mixed?.leaves.last?.disposition, "attachment", "disposition")

    let alt = structure(#"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "BASE64" 150 2 NIL NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "QUOTED-PRINTABLE" 900 12 NIL NIL NIL NIL) "ALTERNATIVE" ("BOUNDARY" "000") NIL NIL)"#)
    eq(alt?.hasAttachments, false, "alternative has no attachments")
    eq(alt?.previewPart?.partNumber, "1", "alternative preview part 1")

    let related = structure(#"(("text" "html" ("charset" "utf-8") NIL NIL "7bit" 300 10 NIL NIL NIL NIL)("image" "png" ("name" "logo.png") "<logo@x>" NIL "base64" 5000 NIL ("inline" ("filename" "logo.png")) NIL NIL) "related" ("boundary" "r1") NIL NIL NIL)"#)
    eq(related?.hasAttachments, false, "related inline image is not attachment")
    eq(related?.previewPart?.subtype, "html", "related preview html")

    let single = structure(#"("text" "plain" ("charset" "us-ascii") NIL NIL "7bit" 20 1 NIL NIL NIL NIL)"#)
    eq(single?.hasAttachments, false, "single text part")
    eq(single?.partNumber, "1", "single part number")

    let pdfOnly = structure(#"("application" "pdf" NIL NIL NIL "base64" 1000 NIL NIL NIL NIL)"#)
    eq(pdfOnly?.hasAttachments, true, "single application/pdf is attachment")
    eq(pdfOnly?.previewPart?.partNumber, nil, "no preview for pdf")

    // Пересланное письмо: message/rfc822 с envelope и вложенным body.
    let fwd = structure(#"(("text" "plain" ("charset" "utf-8") NIL NIL "7bit" 10 1 NIL NIL NIL NIL)("message" "rfc822" NIL NIL NIL "7bit" 500 (NIL "Fwd" NIL NIL NIL NIL NIL NIL NIL NIL) ("text" "plain" ("charset" "utf-8") NIL NIL "7bit" 5 1 NIL NIL NIL NIL) 20 NIL ("attachment" NIL) NIL NIL) "mixed" ("boundary" "m") NIL NIL NIL)"#)
    eq(fwd?.hasAttachments, true, "forwarded message is attachment")
    eq(fwd?.leaves.count, 2, "rfc822 not descended")
    eq(fwd?.leaves.last?.disposition, "attachment", "rfc822 disposition index")

    let signed = structure(#"(("text" "plain" ("charset" "utf-8") NIL NIL "7bit" 10 1 NIL NIL NIL NIL)("application" "pgp-signature" ("name" "signature.asc") NIL NIL "7bit" 300 NIL ("inline" NIL) NIL NIL) "signed" ("protocol" "application/pgp-signature") NIL NIL NIL)"#)
    eq(signed?.hasAttachments, false, "pgp signature not attachment")

    let calendar = structure(#"(("text" "plain" ("charset" "utf-8") NIL NIL "7bit" 10 1 NIL NIL NIL NIL)("text" "calendar" ("charset" "utf-8" "method" "REQUEST") NIL NIL "7bit" 900 30 NIL NIL NIL NIL) "alternative" ("boundary" "c") NIL NIL NIL)"#)
    eq(calendar?.hasAttachments, false, "calendar alternative not attachment")

    let mixedText = structure(#"(("text" "plain" ("charset" "utf-8") NIL NIL "7bit" 10 1 NIL NIL NIL NIL)("text" "plain" ("charset" "utf-8") NIL NIL "7bit" 10 1 NIL NIL NIL NIL) "mixed" ("boundary" "m") NIL NIL NIL)"#)
    eq(mixedText?.hasAttachments, false, "mixed text+footer without filename")
}

// MARK: - 7. Сценарий Dovecot (SASL-IR, LITERAL+, QRESYNC, SPECIAL-USE)

let dovecotCaps = "IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE SORT SPECIAL-USE LIST-EXTENDED LIST-STATUS MOVE UIDPLUS CONDSTORE QRESYNC LITERAL+ ESEARCH"

let dovecotSubjectLiteral = "=?UTF-8?B?0J7RgtGH0Q==?=\r\n =?UTF-8?B?kdGCINC30LAg0YHQtdC90YLRj9Cx0YDRjA==?="
let dovecotHeaders101 = "References: <a1@example.ru>\r\n <a2@example.ru>\r\nList-Unsubscribe: <mailto:unsub@example.ru>\r\nContent-Type: multipart/mixed;\r\n\tboundary=\"b1\"\r\n\r\n"
let dovecotQP = "=C7=E4=F0=E0=E2=F1=F2=E2=F3=E9=F2=E5! =C2=FB=F1=FB=EB=E0=FE =EE=F2=F7=B8=F2=\r\n =E7=E0 =F1=E5=ED=F2=FF=E1=F0=FC, =EF=EE=F1=EC=EE=F2=F0=E8=F2=E5 =EF=EE=E6=\r\n=E0=EB=F3=E9=F1=F2=E0.\r\n=D1 =F3=E2=E0=E6=E5=ED=E8=E5=EC, =C8=E2=E0=ED\r\n"
let dovecotB64 = "0JrQvtC70LvQtdCz0LgsINC90LDQv9C+0LzQuNC90LDRjiDQviDQstGB0YLRgNC10YfQtSDQsiDQv9GP0YLQvdC40YbRgyDQsiAxNTowMC4="
let dovecotHTML = "<html><head><style>p{color:red}</style></head><body><p>Привет, Иван!</p><p>Смотри &laquo;план&raquo; &amp; комментарии.</p></body></html>"
let dovecotAppendMessage = "From: ivan@example.ru\r\nTo: team@example.ru\r\nSubject: =?UTF-8?B?0J/RgNC40LLQtdGC?=\r\n\r\nТекст письма\r\n"

let dovecotFetch = lines(
    "* 2 FETCH (FLAGS (\\Seen))",
    "* 1 FETCH (UID 101 FLAGS (\\Seen \\Flagged) INTERNALDATE \"28-Sep-2026 18:04:12 +0300\" RFC822.SIZE 51234 MODSEQ (88210) "
        + "ENVELOPE (\"Mon, 28 Sep 2026 18:04:11 +0300\" " + lit(dovecotSubjectLiteral)
        + " ((\"=?windows-1251?Q?=C8=E2=E0=ED_=CF=E5=F2=F0=EE=E2?=\" NIL \"ivan.petrov\" \"example.ru\")) ((\"=?windows-1251?Q?=C8=E2=E0=ED_=CF=E5=F2=F0=EE=E2?=\" NIL \"ivan.petrov\" \"example.ru\")) NIL "
        + "((NIL NIL \"team\" \"example.ru\")(\"\\\"Мария\\\"\" NIL \"maria\" \"example.ru\")) ((NIL NIL \"undisclosed-recipients\" NIL)(NIL NIL NIL NIL)) NIL \"<prev@example.ru>\" \"<report-2026-09@example.ru>\") "
        + "BODYSTRUCTURE (((\"text\" \"plain\" (\"charset\" \"windows-1251\") NIL NIL \"quoted-printable\" 312 9 NIL NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"base64\" 1024 14 NIL NIL NIL NIL) \"alternative\" (\"boundary\" \"b2\") NIL NIL NIL)(\"application\" \"pdf\" (\"name\" \"report.pdf\") NIL NIL \"base64\" 48210 NIL (\"attachment\" (\"filename\" \"report.pdf\")) NIL NIL) \"mixed\" (\"boundary\" \"b1\") NIL NIL NIL) "
        + "BODY[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] " + lit(dovecotHeaders101) + ")",
    "* 2 FETCH (UID 102 FLAGS (\\Seen $Forwarded) INTERNALDATE \" 7-Sep-2026 09:05:01 +0000\" RFC822.SIZE 900 MODSEQ (88100) "
        + "ENVELOPE (NIL \"=?koi8-r?B?8NLJ18XU?=\" ((NIL NIL \"robot\" \"bank.ru\")) NIL NIL ((NIL NIL \"ivan\" \"example.ru\")) NIL NIL NIL \"<x@bank.ru>\") "
        + "BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\" \"FORMAT\" \"flowed\") NIL NIL \"BASE64\" 150 2 NIL NIL NIL NIL) "
        + "BODY[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] " + lit("Content-Type: text/plain; charset=UTF-8\r\n\r\n") + ")",
    "* 3 FETCH (UID 103  FLAGS ()  INTERNALDATE \"29-Sep-2026 10:15:00 +0300\" RFC822.SIZE 2048 MODSEQ (88213) "
        + "ENVELOPE (\"Tue, 29 Sep 2026 10:15:00 +0300 (MSK)\" \"Re: \\\"Q3\\\" \\\\ plan\" ((\"Anna\" nil \"anna\" \"example.com\")) nil nil ((\"Ivan\" NIL \"ivan\" \"example.ru\")) nil nil \"<report-2026-09@example.ru>\" \"<re1@example.com>\") "
        + "BODYSTRUCTURE ((\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 300 10 NIL NIL NIL NIL)(\"image\" \"png\" (\"name\" \"logo.png\") \"<logo@x>\" NIL \"base64\" 5000 NIL (\"inline\" (\"filename\" \"logo.png\")) NIL NIL) \"related\" (\"boundary\" \"r1\") NIL NIL NIL) "
        + "BODY[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] " + lit("") + ")"
)

let dovecot = FakeServer(onCommand: { server, tag, cmd in
    switch cmd {
    case _ where cmd.hasPrefix("AUTHENTICATE PLAIN "):
        let token = String(cmd.dropFirst("AUTHENTICATE PLAIN ".count))
        let decoded = Data(base64Encoded: token).map { String(decoding: $0, as: UTF8.self) }
        guard decoded == "\u{0}ivan@example.ru\u{0}pässwörd" else { return lines("\(tag) NO [AUTHENTICATIONFAILED] Authentication failed.") }
        return lines("\(tag) OK [CAPABILITY \(dovecotCaps)] Logged in")
    case "ENABLE QRESYNC CONDSTORE":
        return lines("* ENABLED QRESYNC CONDSTORE", "\(tag) OK Enabled.")
    case #"LIST "" "*" RETURN (SPECIAL-USE)"#:
        return lines(
            #"* LIST (\HasNoChildren) "/" INBOX"#,
            #"* LIST (\HasNoChildren \Sent) "/" "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-""#,
            #"* LIST (\HasNoChildren \Drafts) "/" Drafts"#,
            #"* LIST (\HasNoChildren \Trash) "/" Trash"#,
            #"* LIST (\HasNoChildren \Junk) "/" Junk"#,
            #"* LIST (\HasChildren \Archive) "/" Archive"#,
            #"* LIST (\HasNoChildren) "/" "Archive/2025""#,
            "* LIST (\\HasNoChildren) \"/\" " + lit("&BB4EQgRHBFEEQgRL- &- &BD8EOwQwBD0ESw-"),
            #"* LIST (\HasNoChildren) "/" Sent"#,
            #"* LIST (\NonExistent) "/" Ghost"#,
            "\(tag) OK List completed (0.001 + 0.000 secs).")
    case "SELECT INBOX":
        return lines(
            #"* FLAGS (\Answered \Flagged \Deleted \Seen \Draft)"#,
            #"* OK [PERMANENTFLAGS (\Answered \Flagged \Deleted \Seen \Draft \*)] Flags permitted."#,
            "* 3 EXISTS",
            "* 0 RECENT",
            "* OK [UIDVALIDITY 1727000000] UIDs valid",
            "* OK [UIDNEXT 104] Predicted next UID",
            "* OK [HIGHESTMODSEQ 88213] Highest",
            "\(tag) OK [READ-WRITE] Select completed (0.001 + 0.000 secs).")
    case "UID SEARCH SINCE 1-Sep-2026":
        return lines("* SEARCH 103 101 102", "\(tag) OK Search completed.")
    case _ where cmd.hasPrefix("UID SEARCH CHARSET UTF-8 SUBJECT {"):
        let expected = "UID SEARCH CHARSET UTF-8 SUBJECT {10+}\r\nотчёт\r\n"   // «отчёт» = 10 байт
        let full = server.fullWrites.last ?? ""
        return full == "\(tag) \(expected)" ? lines("* SEARCH 101", "\(tag) OK Search completed.") : lines("\(tag) BAD unexpected: \(full)")
    case "UID FETCH 101:103 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] MODSEQ)":
        return dovecotFetch + lines("\(tag) OK Fetch completed.")
    case "UID FETCH 103 (UID BODY.PEEK[1]<0.2048>)":
        return lines("* 3 FETCH (UID 103 BODY[1]<0> " + lit(dovecotHTML) + ")", "\(tag) OK Fetch completed.")
    case "UID FETCH 101 (UID BODY.PEEK[1.1]<0.2048>)":
        return lines("* 1 FETCH (UID 101 BODY[1.1]<0> " + lit(dovecotQP) + ")", "\(tag) OK Fetch completed.")
    case "UID FETCH 102 (UID BODY.PEEK[TEXT]<0.2048>)":
        return lines("* 2 FETCH (UID 102 BODY[TEXT]<0> " + lit(dovecotB64 + "\r\n") + ")", "\(tag) OK Fetch completed.")
    case "UID FETCH 1:* (UID FLAGS MODSEQ) (CHANGEDSINCE 88000)":
        return lines("* 1 FETCH (UID 101 FLAGS (\\Seen) MODSEQ (88214))", "* 3 FETCH (MODSEQ (88215) UID 103 FLAGS ())", "\(tag) OK Fetch completed.")
    case "UID FETCH 101 (UID FLAGS MODSEQ)":
        return lines("* 1 FETCH (UID 101 FLAGS (\\Seen) MODSEQ (88214))", "\(tag) OK Fetch completed.")
    case "UID FETCH 102 (UID FLAGS MODSEQ)":
        return lines("* 2 FETCH (UID 102 FLAGS (\\Seen $Forwarded) MODSEQ (88100))", "\(tag) OK Fetch completed.")
    case "UID STORE 101:103 +FLAGS.SILENT (\\Seen)":
        return lines("\(tag) OK Store completed.")
    case "UID STORE 102 -FLAGS.SILENT (\\Flagged $Important)":
        return lines("\(tag) OK Store completed.")
    case "UID MOVE 101,103 \"Trash\"":
        return lines("* OK [COPYUID 1727000000 101,103 1:2] Moved UIDs.", "* 3 EXPUNGE", "* 1 EXPUNGE", "\(tag) OK Move completed.")
    case "UID STORE 102 +FLAGS.SILENT (\\Deleted)":
        return lines("\(tag) OK Store completed.")
    case "UID EXPUNGE 102":
        return lines("* VANISHED 102", "\(tag) OK Expunge completed.")
    case _ where cmd.hasPrefix("APPEND \"&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-\" (\\Seen) \"29-Sep-2026 07:15:00 +0000\" {"):
        let full = server.fullWrites.last ?? ""
        let expected = "\(tag) APPEND \"&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-\" (\\Seen) \"29-Sep-2026 07:15:00 +0000\" {\(dovecotAppendMessage.utf8.count)+}\r\n\(dovecotAppendMessage)\r\n"
        return full == expected ? lines("\(tag) OK [APPENDUID 1727000000 104] Append completed.") : lines("\(tag) BAD bad append")
    case "IDLE":
        return lines("+ idling", "* 4 EXISTS", "* 1 RECENT")
    case "NOOP":
        return lines("* 5 EXISTS", "\(tag) OK NOOP completed.")
    case "LOGOUT":
        return lines("* BYE Logging out", "\(tag) OK Logout completed.")
    default:
        return lines("\(tag) BAD Unknown command: \(cmd)")
    }
}, onRaw: { server, text in
    text == "DONE\r\n" ? lines("\(server.lastTag) OK Idle completed (0.001 + 1.2 secs).") : nil
})

section("Dovecot scenario")
do {
    let transport = dovecot.makeTransport(greeting: "* OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ AUTH=PLAIN] Dovecot ready.\r\n")
    let client = IMAPClient(transport: transport)
    try await client.connect()
    check(await client.capabilities.contains("AUTH=PLAIN"), "greeting capabilities")
    eq(dovecot.commands.count, 0, "no CAPABILITY command when greeting has caps")

    try await client.login(username: "ivan@example.ru", password: "pässwörd")
    check(await client.capabilities.contains("QRESYNC"), "capabilities from login OK code")
    eq(dovecot.commands.last?.hasPrefix("AUTHENTICATE PLAIN "), true, "AUTHENTICATE PLAIN with SASL-IR")
    eq(dovecot.commands.count, 1, "no extra CAPABILITY after login")

    try await client.enableCondStore()
    eq(await client.enabledExtensions, ["QRESYNC", "CONDSTORE"], "ENABLE QRESYNC")

    let folders = try await client.listFolders()
    let byName = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0) })
    eq(folders.count, 9, "folder count (NonExistent skipped)")
    eq(byName["INBOX"]?.role, .inbox, "dovecot INBOX")
    eq(byName["Отправленные"]?.role, .sent, "dovecot \\Sent in Cyrillic")
    eq(byName["Drafts"]?.role, .drafts, "dovecot drafts")
    eq(byName["Trash"]?.role, .trash, "dovecot trash")
    eq(byName["Junk"]?.role, .spam, "dovecot junk")
    eq(byName["Archive"]?.role, .archive, "dovecot archive")
    eq(byName["Sent"].map { $0.role == nil }, true, "plain Sent has no role when \\Sent exists")
    eq(byName["Отчёты & планы"]?.delimiter, "/", "literal folder name decoded")
    eq(byName["Archive/2025"]?.displayName, "2025", "display name")

    let info = try await client.select("INBOX", readOnly: false)
    eq(info.uidValidity, 1727000000, "UIDVALIDITY")
    eq(info.uidNext, 104, "UIDNEXT")
    eq(info.exists, 3, "EXISTS")
    eq(info.highestModSeq, 88213, "HIGHESTMODSEQ")
    eq(dovecot.commands.last, "SELECT INBOX", "no (CONDSTORE) after ENABLE")

    eq(try await client.uidSearch("SINCE 1-Sep-2026"), [101, 102, 103], "UID SEARCH sorted")
    eq(try await client.uidSearch("SUBJECT \"отчёт\""), [101], "UID SEARCH Cyrillic → CHARSET + literal+")

    let summaries = try await client.fetchSummaries(uids: [101, 102, 103])
    eq(summaries.map(\.uid), [101, 102, 103], "summaries order")
    let m1 = summaries[0], m2 = summaries[1], m3 = summaries[2]
    eq(m1.envelope.subject, "Отчёт за сентябрь", "subject from literal with split RFC2047")
    eq(m1.envelope.from, [Address(name: "Иван Петров", email: "ivan.petrov@example.ru")], "from windows-1251 Q name")
    eq(m1.envelope.to, [Address(name: nil, email: "team@example.ru"), Address(name: "Мария", email: "maria@example.ru")], "to list with quoted UTF-8 name")
    eq(m1.envelope.cc, [], "group syntax skipped")
    eq(m1.envelope.replyTo, [], "NIL reply-to")
    eq(m1.envelope.inReplyTo, "<prev@example.ru>", "in-reply-to")
    eq(m1.envelope.messageID, "<report-2026-09@example.ru>", "message-id")
    eq(m1.envelope.date?.timeIntervalSince1970, 1790607851, "envelope date")
    eq(m1.internalDate?.timeIntervalSince1970, 1790607852, "internal date")
    eq(m1.flags, ["\\Seen", "\\Flagged"], "flags")
    eq(m1.size, 51234, "size")
    eq(m1.modSeq, 88210, "modseq")
    eq(m1.hasAttachments, true, "attachments m1")
    eq(m1.headers["references"], "<a1@example.ru> <a2@example.ru>", "references unfolded")
    eq(m1.headers["list-unsubscribe"], "<mailto:unsub@example.ru>", "list-unsubscribe")
    eq(m1.headers["content-type"], "multipart/mixed; boundary=\"b1\"", "content-type unfolded")
    eq(m1.preview, "Здравствуйте! Высылаю отчёт за сентябрь, посмотрите пожалуйста. С уважением, Иван", "preview QP windows-1251")
    eq(m1.gmailThreadID, nil, "no gmail thread id on dovecot")

    eq(m2.envelope.subject, "Привет", "koi8-r subject")
    eq(m2.envelope.date, nil, "NIL date")
    eq(m2.envelope.from.first?.email, "robot@bank.ru", "from without name")
    eq(m2.flags, ["\\Seen", "$Forwarded"], "flags merged with unsolicited fetch")
    eq(m2.hasAttachments, false, "plain text no attachments")
    eq(m2.preview, "Коллеги, напоминаю о встрече в пятницу в 15:00.", "preview base64 utf-8 via TEXT")
    eq(m2.internalDate?.timeIntervalSince1970, 1788771901, "internal date with leading space")

    eq(m3.envelope.subject, #"Re: "Q3" \ plan"#, "quoted subject with escapes")
    eq(m3.envelope.from.first?.name, "Anna", "lowercase nil fields")
    eq(m3.envelope.date?.timeIntervalSince1970, 1790666100, "date with (MSK) comment")
    eq(m3.flags, [], "empty flags")
    eq(m3.hasAttachments, false, "related inline image")
    eq(m3.headers, [:], "empty header literal")
    eq(m3.preview, "Привет, Иван! Смотри «план» & комментарии.", "preview from HTML")

    let changed = try await client.fetchFlags(changedSince: 88000)
    eq(changed.map(\.uid), [101, 103], "CHANGEDSINCE uids")
    eq(changed.map(\.modSeq), [88214, 88215], "CHANGEDSINCE modseq")
    eq(changed.last?.flags, [], "CHANGEDSINCE empty flags")

    // Две команды одновременно — очередь не даёт им перемешаться.
    async let a = client.fetchFlags(uids: [101])
    async let b = client.fetchFlags(uids: [102])
    let (fa, fb) = try await (a, b)
    eq(fa.first?.uid, 101, "concurrent fetch A")
    eq(fb.first?.flags, ["\\Seen", "$Forwarded"], "concurrent fetch B")

    try await client.store(uids: [103, 101, 102], flags: ["\\Seen"], add: true)
    eq(dovecot.commands.last, "UID STORE 101:103 +FLAGS.SILENT (\\Seen)", "STORE compressed set")
    try await client.store(uids: [102], flags: ["\\Flagged", "$Important"], add: false)
    eq(dovecot.commands.last, "UID STORE 102 -FLAGS.SILENT (\\Flagged $Important)", "STORE remove")

    try await client.move(uids: [103, 101], to: "Trash")
    eq(dovecot.commands.last, "UID MOVE 101,103 \"Trash\"", "UID MOVE")

    try await client.expunge(uids: [102])
    eq(Array(dovecot.commands.suffix(2)), ["UID STORE 102 +FLAGS.SILENT (\\Deleted)", "UID EXPUNGE 102"], "UID EXPUNGE with UIDPLUS")

    let appended = try await client.append(folder: "Отправленные", message: Data(dovecotAppendMessage.utf8), flags: ["\\Seen", "\\Recent"],
                                           date: Date(timeIntervalSince1970: 1790666100))
    eq(appended, 104, "APPENDUID with LITERAL+")

    let idleChanged = try await client.idle(timeout: 5)
    eq(idleChanged, true, "IDLE returns true on EXISTS")
    eq(dovecot.rawWrites.last, "DONE\r\n", "DONE sent after EXISTS")

    try await client.noop()
    let immediate = try await client.idle(timeout: 5)
    eq(immediate, true, "IDLE returns immediately after NOOP saw EXISTS")
    eq(dovecot.commands.last, "NOOP", "no IDLE sent when changes pending")

    await client.logout()
    eq(dovecot.commands.last, "LOGOUT", "LOGOUT")
} catch {
    check(false, "Dovecot scenario threw \(error)")
}

// MARK: - 8. Сценарий Gmail (CAPABILITY после приветствия, AUTHENTICATE с «+», X-GM-EXT-1, LITERAL-)

let gmailCaps = "IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 UIDPLUS COMPRESS=DEFLATE ENABLE MOVE CONDSTORE ESEARCH UTF8=ACCEPT LIST-EXTENDED LIST-STATUS LITERAL- SPECIAL-USE APPENDLIMIT=35651584"
let gmailBigBody = String(repeating: "Строка письма с кириллицей и цифрами 0123456789.\r\n", count: 150)
let gmailRaw = "Delivered-To: me@gmail.com\r\nSubject: =?UTF-8?B?0J/RgNC40LLQtdGC?=\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + gmailBigBody
let gmailDraft = String(repeating: "x", count: 5000)
let gmailHeaders3000 = "List-Unsubscribe: <https://news.example.com/u/123>, <mailto:u@news.example.com>\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\nContent-Type: multipart/alternative; boundary=\"000\"\r\n\r\n"

let gmail = FakeServer(onCommand: { server, tag, cmd in
    switch cmd {
    case "CAPABILITY":
        return lines("* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 XYZZY SASL-IR-NOT AUTH=XOAUTH2 AUTH=PLAIN AUTH=PLAIN-CLIENTTOKEN AUTH=OAUTHBEARER", "\(tag) OK Thats all she wrote! a1mb")
    case "AUTHENTICATE PLAIN":
        return "+ \r\n"
    case "ENABLE CONDSTORE":
        return lines("* ENABLED CONDSTORE", "\(tag) OK Success")
    case #"LIST "" "*" RETURN (SPECIAL-USE)"#:
        return lines(
            #"* LIST (\HasNoChildren) "/" "INBOX""#,
            #"* LIST (\HasChildren \Noselect) "/" "[Gmail]""#,
            #"* LIST (\All \HasNoChildren) "/" "[Gmail]/&BBIEQQRP- &BD8EPgRHBEIEMA-""#,
            #"* LIST (\Drafts \HasNoChildren) "/" "[Gmail]/&BCcENQRABD0EPgQyBDgEOgQ4-""#,
            #"* LIST (\HasNoChildren \Important) "/" "[Gmail]/&BBIEMAQ2BD0EPgQ1-""#,
            #"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-""#,
            #"* LIST (\HasNoChildren \Junk) "/" "[Gmail]/&BCEEPwQwBDw-""#,
            #"* LIST (\Flagged \HasNoChildren) "/" "[Gmail]/&BB8EPgQ8BDUERwQ1BD0EPQRLBDU-""#,
            #"* LIST (\HasNoChildren \Trash) "/" "[Gmail]/&BBoEPgRABDcEOAQ9BDA-""#,
            #"* LIST (\HasNoChildren) "/" "&BCAEMAQxBD4EQgQw-/Q3""#,
            "\(tag) OK Success")
    case #"EXAMINE "[Gmail]/&BBIEQQRP- &BD8EPgRHBEIEMA-""#:
        return lines(
            #"* FLAGS (\Answered \Flagged \Draft \Deleted \Seen $NotPhishing $Phishing)"#,
            #"* OK [PERMANENTFLAGS ()] Flags permitted."#,
            "* OK [UIDVALIDITY 11] UIDs valid.",
            "* 25 EXISTS",
            "* 0 RECENT",
            "* OK [UIDNEXT 3001] Predicted next UID.",
            "* OK [HIGHESTMODSEQ 4611686]",
            "\(tag) OK [READ-ONLY] [Gmail]/Вся почта selected. (Success)")
    case _ where cmd.hasPrefix("UID SEARCH CHARSET UTF-8 X-GM-RAW {"):
        let expected = "\(tag) UID SEARCH CHARSET UTF-8 X-GM-RAW {25+}\r\nhas:attachment отчёт\r\n"   // LITERAL-: мелкий литерал без ожидания
        return server.fullWrites.last == expected ? lines("* SEARCH 2999 3000", "\(tag) OK SEARCH completed (Success)") : lines("\(tag) BAD \(server.fullWrites.last ?? "")")
    case "UID FETCH 2999:3000 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] MODSEQ X-GM-THRID X-GM-LABELS)":
        return lines(
            "* 24 FETCH (X-GM-THRID 1812345678901234567 X-GM-LABELS (\\Inbox \"&BCAEMAQxBD4EQgQw-/Q3\" Receipts) UID 2999 MODSEQ (4611600) FLAGS () INTERNALDATE \"06-Sep-2026 21:00:00 +0000\" RFC822.SIZE 9000 "
                + "ENVELOPE (\"Sun, 6 Sep 2026 21:00:00 +0000\" \"Fwd: =?UTF-8?B?0J/RgNC40LLQtdGC?=\" ((\"Petr\" NIL \"petr\" \"gmail.com\")) ((\"Petr\" NIL \"petr\" \"gmail.com\")) ((\"Petr\" NIL \"petr\" \"gmail.com\")) ((NIL NIL \"me\" \"gmail.com\")) NIL NIL NIL \"<CAF=abc@mail.gmail.com>\") "
                + "BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 20 1 NIL NIL NIL)(\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" 500 (NIL \"Old\" NIL NIL NIL NIL NIL NIL NIL NIL) (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 5 1 NIL NIL NIL) 20 NIL (\"ATTACHMENT\" NIL) NIL) \"MIXED\" (\"BOUNDARY\" \"m1\") NIL NIL) "
                + "BODY[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] " + lit("Content-Type: multipart/mixed; boundary=\"m1\"\r\n\r\n") + ")",
            "* 25 FETCH (X-GM-THRID 1812345678901234999 X-GM-LABELS (\\Important \\Inbox) UID 3000 MODSEQ (4611685) FLAGS (\\Seen) INTERNALDATE \"07-Sep-2026 09:05:01 +0000\" RFC822.SIZE 48213 "
                + "ENVELOPE (\"Mon, 07 Sep 2026 09:05:01 +0000\" \"Weekly digest\" ((\"News\" NIL \"news\" \"news.example.com\")) NIL NIL ((NIL NIL \"me\" \"gmail.com\")) NIL NIL NIL \"<d1@news.example.com>\") "
                + "BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"BASE64\" 150 2 NIL NIL NIL)(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 900 12 NIL NIL NIL) \"ALTERNATIVE\" (\"BOUNDARY\" \"000\") NIL NIL) "
                + "BODY[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] " + lit(gmailHeaders3000) + ")",
            "\(tag) OK Success")
    case "UID FETCH 2999:3000 (UID BODY.PEEK[1]<0.2048>)":
        return lines("* 24 FETCH (UID 2999 BODY[1]<0> " + lit("Смотри!") + ")", "* 25 FETCH (UID 3000 BODY[1]<0> " + lit(dovecotB64) + ")", "\(tag) OK Success")
    case _ where cmd.hasPrefix("APPEND \"[Gmail]/&BCcENQRABD0EPgQyBDgEOgQ4-\" (\\Draft \\Seen) {5000}"):
        return "+ go ahead\r\n"
    case "UID FETCH 3000 (UID BODY.PEEK[])":
        return lines("* 25 FETCH (UID 3000 BODY[] " + lit(gmailRaw) + " FLAGS (\\Seen))", "\(tag) OK Success")
    case "UID FETCH 2999 (UID BODY.PEEK[2])":
        return lines("* 24 FETCH (UID 2999 BODY[2] ~{5}", "hello)", "\(tag) OK Success")
    case "UID FETCH 1 (UID BODY.PEEK[])":
        return lines("\(tag) OK Success")
    case "IDLE":
        return lines("+ idling")
    default:
        return lines("\(tag) BAD Unknown: \(cmd)")
    }
}, onRaw: { server, text in
    if text == Data("\u{0}me@gmail.com\u{0}app-password".utf8).base64EncodedString() + "\r\n" {
        return lines("* CAPABILITY \(gmailCaps)", "\(server.lastTag) OK me@gmail.com authenticated (Success)")
    }
    if text == gmailDraft + "\r\n" { return lines("\(server.lastTag) OK [APPENDUID 11 3001] (Success)") }
    if text == "DONE\r\n" { return lines("\(server.lastTag) OK IDLE terminated (Success)") }
    return lines("\(server.lastTag) BAD unexpected raw write")
})

section("Gmail scenario")
do {
    let client = IMAPClient(transport: gmail.makeTransport(greeting: "* OK Gimap ready for requests from 203.0.113.5 a1mb12345678ljb\r\n"))
    try await client.connect()
    eq(gmail.commands.first, "CAPABILITY", "CAPABILITY requested after bare greeting")
    try await client.login(username: "me@gmail.com", password: "app-password")
    eq(gmail.commands.last, "AUTHENTICATE PLAIN", "AUTHENTICATE PLAIN without SASL-IR")
    check(await client.capabilities.contains("X-GM-EXT-1"), "capabilities from untagged CAPABILITY during login")
    check(!(await client.capabilities.contains("AUTH=PLAIN")), "post-login capabilities replaced")
    eq(gmail.commands.filter { $0 == "CAPABILITY" }.count, 1, "no extra CAPABILITY after login")

    try await client.enableCondStore()
    eq(gmail.commands.last, "ENABLE CONDSTORE", "ENABLE CONDSTORE (no QRESYNC)")

    let folders = try await client.listFolders()
    let byName = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0) })
    eq(byName["[Gmail]/Вся почта"]?.role, .archive, "gmail \\All → archive")
    eq(byName["[Gmail]/Черновики"]?.role, .drafts, "gmail drafts")
    eq(byName["[Gmail]/Отправленные"]?.role, .sent, "gmail sent")
    eq(byName["[Gmail]/Спам"]?.role, .spam, "gmail spam")
    eq(byName["[Gmail]/Помеченные"]?.role, .flagged, "gmail flagged")
    eq(byName["[Gmail]/Корзина"]?.role, .trash, "gmail trash")
    eq(byName["[Gmail]/Важное"].map { $0.role == nil }, true, "gmail important no role")
    eq(byName["[Gmail]"]?.isSelectable, false, "gmail parent not selectable")
    eq(byName["Работа/Q3"]?.displayName, "Q3", "gmail user label")

    let info = try await client.select("[Gmail]/Вся почта", readOnly: true)
    eq(info.uidValidity, 11, "gmail UIDVALIDITY")
    eq(info.exists, 25, "gmail EXISTS")
    eq(info.highestModSeq, 4611686, "gmail HIGHESTMODSEQ")
    eq(await client.selectedFolder, "[Gmail]/Вся почта", "selected folder")

    eq(try await client.uidSearch("X-GM-RAW \"has:attachment отчёт\""), [2999, 3000], "X-GM-RAW with Cyrillic")

    let s = try await client.fetchSummaries(uids: [3000, 2999, 3000])
    eq(s.map(\.uid), [3000, 2999], "order preserved, duplicates removed")
    eq(s[0].gmailThreadID, 1812345678901234999, "X-GM-THRID")
    eq(s[0].gmailLabels, ["\\Important", "\\Inbox"], "X-GM-LABELS atoms")
    eq(s[1].gmailLabels, ["\\Inbox", "Работа/Q3", "Receipts"], "X-GM-LABELS mUTF-7")
    eq(s[0].headers["list-unsubscribe-post"], "List-Unsubscribe=One-Click", "one-click header")
    eq(s[0].headers["list-unsubscribe"], "<https://news.example.com/u/123>, <mailto:u@news.example.com>", "list-unsubscribe")
    eq(s[0].hasAttachments, false, "gmail alternative")
    eq(s[1].hasAttachments, true, "gmail forwarded rfc822")
    eq(s[1].envelope.subject, "Fwd: Привет", "gmail subject partial RFC2047")
    eq(s[1].envelope.replyTo.first?.email, "petr@gmail.com", "reply-to")
    eq(s[0].preview, "Коллеги, напоминаю о встрече в пятницу в 15:00.", "gmail preview base64")
    eq(s[1].preview, "Смотри!", "gmail preview 7bit")
    eq(s[0].modSeq, 4611685, "gmail modseq")

    let draftUID = try await client.append(folder: "[Gmail]/Черновики", message: Data(gmailDraft.utf8), flags: ["\\Draft", "\\Seen"], date: nil)
    eq(draftUID, 3001, "APPEND with sync literal (> 4096 under LITERAL-)")

    let full = try await client.fetchMessage(uid: 3000)
    eq(full.count, gmailRaw.utf8.count, "fetchMessage size (\(gmailRaw.utf8.count) bytes)")
    eq(full, Data(gmailRaw.utf8), "fetchMessage bytes")

    let part = try await client.fetchPart(uid: 2999, section: "2")
    eq(String(decoding: part, as: UTF8.self), "hello", "fetchPart literal8")

    await expectError("missing message", { if case IMAPError.unexpected = $0 { return true }; return false }) {
        _ = try await client.fetchMessage(uid: 1)
    }

    let started = Date()
    let changed = try await client.idle(timeout: 0.05)
    eq(changed, false, "IDLE timeout without changes")
    check(Date().timeIntervalSince(started) < 1, "IDLE timeout honoured")
    eq(gmail.rawWrites.last, "DONE\r\n", "DONE after timeout")
} catch {
    check(false, "Gmail scenario threw \(error)")
}

// MARK: - 9. Сценарий Exchange (LOGIN, синхронные литералы, без MOVE/SPECIAL-USE/CONDSTORE)

let exchangeCaps = "* CAPABILITY IMAP4 IMAP4rev1 AUTH=NTLM AUTH=GSSAPI CHILDREN IDLE NAMESPACE UIDPLUS ID UNSELECT"
let exchangeHTML = "<html><body><p>=C4=EE=E1=F0=FB=E9 =E4=E5=ED=FC!</p>\r\n<p>=CE=F2=F7=E5=F2 =E2=EE =E2=EB=EE=E6=E5=ED=E8=E8.</p></body></html>"

let exchange = FakeServer(onCommand: { server, tag, cmd in
    switch cmd {
    case "CAPABILITY":
        return lines(exchangeCaps, "\(tag) OK CAPABILITY completed.")
    case "LOGIN \"CORP\\\\ivanov\" {16}":
        return "+ Ready for additional command text.\r\n"
    case "LOGIN \"CORP\\\\ivanov\" \"wrong\"":
        return lines("\(tag) NO LOGIN failed.")
    case #"LIST "" "*""#:
        return lines(
            #"* LIST (\Marked \HasNoChildren) "/" Archive"#,
            #"* LIST (\HasChildren) "/" Calendar"#,
            #"* LIST (\HasNoChildren) "/" "Calendar/Birthdays""#,
            #"* LIST (\HasNoChildren) "/" Contacts"#,
            #"* LIST (\Marked \HasNoChildren) "/" "Deleted Items""#,
            #"* LIST (\HasNoChildren) "/" Drafts"#,
            #"* LIST (\Marked \HasChildren) "/" INBOX"#,
            #"* LIST (\HasNoChildren) "/" "INBOX/Sent""#,
            #"* LIST (\HasNoChildren) "/" "Junk E-mail""#,
            #"* LIST (\HasNoChildren) "/" Outbox"#,
            #"* LIST (\HasNoChildren) "/" "Sent Items""#,
            #"* LIST (\HasNoChildren) "/" Tasks"#,
            "\(tag) OK LIST completed.")
    case "SELECT \"Sent Items\"":
        return lines(
            "* 12 EXISTS",
            "* 0 RECENT",
            #"* FLAGS (\Seen \Answered \Flagged \Deleted \Draft $MDNSent)"#,
            #"* OK [PERMANENTFLAGS (\Seen \Answered \Flagged \Deleted \Draft $MDNSent)] Permanent flags"#,
            "* OK [UNSEEN 3] Is the first unseen message",
            "* OK [UIDVALIDITY 14] UIDVALIDITY value",
            "* OK [UIDNEXT 250] The next unique identifier value",
            "\(tag) OK [READ-WRITE] SELECT completed.")
    case "UID FETCH 240 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)])":
        return lines(
            "* 12 fetch (uid 240 flags (\\Seen \\Answered) internaldate \"29-Sep-2026 10:15:00 +0300\" rfc822.size 4096 "
                + "envelope (\"Tue, 29 Sep 2026 10:15:00 +0300\" \"=?koi8-r?B?8NLJ18XU?= =?windows-1251?Q?=2C_=EA=EE=EB=EB=E5=E3=E8?=\" "
                + "((\"=?windows-1251?B?yOLg7e7iIMji4O0=?=\" NIL \"ivanov\" \"corp.local\")) NIL NIL ((\"Team\" NIL \"team\" \"corp.local\")) "
                + "((\"=?utf-8?Q?=D0=91=D0=BE=D1=81=D1=81?=\" NIL \"boss\" \"corp.local\")) NIL NIL \"<ABC123@EX01.corp.local>\") "
                + "bodystructure (\"text\" \"html\" (\"charset\" \"windows-1251\") NIL NIL \"quoted-printable\" 4096 20 NIL NIL NIL NIL) "
                + "body[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST CONTENT-TYPE)] " + lit("Content-Type: text/html; charset=\"windows-1251\"\r\n\r\n") + ")",
            "\(tag) OK FETCH completed.")
    case "UID FETCH 240 (UID BODY.PEEK[TEXT]<0.2048>)":
        return lines("* 12 FETCH (UID 240 BODY[TEXT]<0> " + lit(exchangeHTML) + ")", "\(tag) OK FETCH completed.")
    case "UID COPY 240 \"Deleted Items\"":
        return lines("\(tag) OK [COPYUID 9 240 77] COPY completed.")
    case "UID STORE 240 +FLAGS.SILENT (\\Deleted)":
        return lines("\(tag) OK STORE completed.")
    case "UID EXPUNGE 240":
        return lines("* 12 EXPUNGE", "\(tag) OK EXPUNGE completed.")
    case "APPEND \"Sent Items\" (\\Seen) {19}":
        return "+ Ready for additional command text.\r\n"
    case "UID SEARCH UNSEEN":
        return lines("* SEARCH", "\(tag) OK SEARCH completed.")
    case "IDLE":
        return lines("+ IDLE accepted, awaiting DONE command.")
    case "NOOP":
        return lines("* BYE Connection is closed. 13")
    default:
        return lines("\(tag) BAD Command Error. 10 (\(cmd))")
    }
}, onRaw: { server, text in
    switch text {
    case "Пароль!123\r\n":   // 16 байт UTF-8
        return lines("\(server.lastTag) OK LOGIN completed.")
    case "Subject: test\r\n\r\nhi\r\n":
        return lines("\(server.lastTag) OK [APPENDUID 14 251] APPEND completed.")
    case "DONE\r\n":
        return lines("* 13 EXISTS", "\(server.lastTag) OK IDLE completed.")
    default:
        return lines("\(server.lastTag) BAD unexpected raw \(text)")
    }
})

section("Exchange scenario")
do {
    let greeting = "* OK The Microsoft Exchange IMAP4 service is ready. [TQBXADIAUABSADAAMQBDAEEAMAAwADAANQAuAG4AYQBtAHAAcgBkADAAMQAuAHAAcgBvAGQA]\r\n"

    // Неверный пароль → authenticationFailed.
    let bad = IMAPClient(transport: exchange.makeTransport(greeting: greeting))
    try await bad.connect()
    await expectError("LOGIN NO → authenticationFailed", { if case IMAPError.authenticationFailed(let s) = $0 { return s == "LOGIN failed." }; return false }) {
        try await bad.login(username: "CORP\\ivanov", password: "wrong")
    }

    let client = IMAPClient(transport: exchange.makeTransport(greeting: greeting))
    try await client.connect()
    try await client.login(username: "CORP\\ivanov", password: "Пароль!123")
    eq(exchange.commands.suffix(2).first, "LOGIN \"CORP\\\\ivanov\" {16}", "LOGIN with escaped backslash and sync literal")
    eq(exchange.commands.last, "CAPABILITY", "CAPABILITY refreshed after LOGIN")

    try await client.enableCondStore()   // нет ENABLE — ничего не отправляется
    eq(exchange.commands.last, "CAPABILITY", "enableCondStore no-op without ENABLE")

    let folders = try await client.listFolders()
    let roles = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0.role) })
    eq(roles["Sent Items"]!, .sent, "Exchange Sent Items")
    eq(roles["Deleted Items"]!, .trash, "Exchange Deleted Items")
    eq(roles["Junk E-mail"]!, .spam, "Exchange Junk E-mail")
    eq(roles["Drafts"]!, .drafts, "Exchange Drafts")
    eq(roles["Archive"]!, .archive, "Exchange Archive")
    eq(roles["INBOX"]!, .inbox, "Exchange INBOX")
    eq(roles["INBOX/Sent"]!, nil, "Exchange INBOX/Sent not sent")
    eq(roles["Calendar"]!, nil, "Exchange Calendar")

    let info = try await client.select("Sent Items", readOnly: false)
    eq(info.uidValidity, 14, "Exchange UIDVALIDITY")
    eq(info.uidNext, 250, "Exchange UIDNEXT")
    eq(info.exists, 12, "Exchange EXISTS")
    eq(info.highestModSeq, nil, "Exchange no HIGHESTMODSEQ")

    eq(try await client.uidSearch("UNSEEN"), [], "empty SEARCH")

    let s = try await client.fetchSummaries(uids: [240])
    eq(s.count, 1, "Exchange summary (lowercase fetch keywords)")
    eq(s.first?.envelope.subject, "Привет, коллеги", "subject koi8-r + windows-1251 words")
    eq(s.first?.envelope.from.first?.name, "Иванов Иван", "from windows-1251 B")
    eq(s.first?.envelope.cc.first?.name, "Босс", "cc utf-8 Q")
    eq(s.first?.flags, ["\\Seen", "\\Answered"], "Exchange flags")
    eq(s.first?.headers["content-type"], "text/html; charset=\"windows-1251\"", "Exchange content-type")
    eq(s.first?.preview, "Добрый день! Отчет во вложении.", "Exchange HTML QP windows-1251 preview")
    eq(s.first?.hasAttachments, false, "Exchange single html")
    eq(s.first?.modSeq, nil, "Exchange no modseq")

    try await client.move(uids: [240], to: "Deleted Items")
    eq(Array(exchange.commands.suffix(3)), ["UID COPY 240 \"Deleted Items\"", "UID STORE 240 +FLAGS.SILENT (\\Deleted)", "UID EXPUNGE 240"], "MOVE fallback: COPY + STORE + UID EXPUNGE")

    let uid = try await client.append(folder: "Sent Items", message: Data("Subject: test\r\n\r\nhi".utf8), flags: ["\\Seen"], date: nil)
    eq(uid, 251, "APPEND sync literal (no LITERAL+)")

    // IDLE: изменения, пришедшие уже после DONE, тоже учитываются.
    let changed = try await client.idle(timeout: 0.05)
    eq(changed, true, "EXISTS between DONE and tagged OK counts")

    await expectError("BYE → unexpected", { if case IMAPError.unexpected(let s) = $0 { return s.contains("Connection is closed") }; return false }) {
        try await client.noop()
    }
} catch {
    check(false, "Exchange scenario threw \(error)")
}

// MARK: - 10. STARTTLS и LOGINDISABLED

section("STARTTLS")
do {
    let server = FakeServer(onCommand: { _, tag, cmd in
        switch cmd {
        case "STARTTLS": return lines("\(tag) OK Begin TLS negotiation now.")
        case "CAPABILITY": return lines("* CAPABILITY IMAP4rev1 AUTH=PLAIN IDLE", "\(tag) OK Pre-login capabilities listed, post-login capabilities have more.")
        case "AUTHENTICATE PLAIN": return "+\r\n"
        default: return lines("\(tag) BAD \(cmd)")
        }
    }, onRaw: { server, text in
        text == Data("\u{0}u\u{0}p".utf8).base64EncodedString() + "\r\n"
            ? lines("\(server.lastTag) NO [AUTHENTICATIONFAILED] Authentication failed.")
            : "+ \r\n"
    })
    let transport = server.makeTransport(greeting: "* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] ready\r\n")
    let client = IMAPClient(transport: transport)
    try await client.connect()
    await expectError("LOGINDISABLED without AUTH=PLAIN", { if case IMAPError.authenticationFailed = $0 { return true }; return false }) {
        try await client.login(username: "u", password: "p")
    }
    try await client.startTLS()
    check(transport.tlsStarted, "transport TLS started")
    eq(await client.capabilities, ["IMAP4REV1", "AUTH=PLAIN", "IDLE"], "capabilities refreshed after STARTTLS")
    await expectError("AUTHENTICATE NO → authenticationFailed", { if case IMAPError.authenticationFailed = $0 { return true }; return false }) {
        try await client.login(username: "u", password: "p")
    }
} catch {
    check(false, "STARTTLS scenario threw \(error)")
}

// MARK: - 11. Кавычки и аргументы

section("Arguments")
do {
    if case .text(let s) = IMAPClient.astring(#"pa"ss\word"#) { eq(s, #""pa\"ss\\word""#, "quoted escapes") } else { check(false, "astring quoted") }
    if case .literal(let d) = IMAPClient.astring("пароль") { eq(d, Data("пароль".utf8), "non-ASCII → literal") } else { check(false, "astring literal") }
    if case .literal = IMAPClient.astring("a\r\nb") { check(true, "CRLF → literal") } else { check(false, "CRLF → literal") }
    if case .text(let s) = IMAPClient.mailbox("inbox") { eq(s, "INBOX", "INBOX unquoted") } else { check(false, "mailbox INBOX") }
    if case .text(let s) = IMAPClient.mailbox("Отправленные") { eq(s, "\"&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-\"", "mailbox mUTF-7 quoted") } else { check(false, "mailbox") }
    let (parts, charset) = IMAPClient.searchParts("FROM \"ivan\" SUBJECT \"отчёт\" SINCE 1-Sep-2026")
    eq(charset, true, "search needs charset")
    eq(parts.count, 3, "search parts split")
    if case .text(let first) = parts[0] { eq(first, "FROM \"ivan\" SUBJECT ", "search ascii prefix") }
    if case .literal(let lit) = parts[1] { eq(lit, Data("отчёт".utf8), "search literal") }
}

// MARK: - Итог

print("\n\(passed) passed, \(failed.count) failed")
if !failed.isEmpty {
    print("Failures:")
    for f in failed { print("  - \(f)") }
    exit(1)
}
