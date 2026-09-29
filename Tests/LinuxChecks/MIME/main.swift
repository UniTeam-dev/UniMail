// Linux-проверки MIME / SMTP / ICS. Запуск:
//   swiftc -swift-version 5 Sources/UniMail/Core/Models/*.swift Sources/UniMail/Core/Mail/Transport.swift \
//     Sources/UniMail/Core/Mail/{MIME,SMTP,ICS}/*.swift Tests/LinuxChecks/MIME/*.swift -o /tmp/mimetest && /tmp/mimetest
import Foundation

// MARK: - Мини-фреймворк

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "", line: Int = #line) {
    if condition {
        passed += 1
        print("PASS  \(name)")
    } else {
        failed += 1
        let d = detail()
        print("FAIL  \(name) (line \(line))\(d.isEmpty ? "" : " — " + d)")
    }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ name: String, line: Int = #line) {
    check(a == b, name, "got \(String(reflecting: a)), expected \(String(reflecting: b))", line: line)
}

func section(_ title: String) { print("\n== \(title)") }

func crlf(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

let utc = TimeZone(identifier: "UTC")!
func utcDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

// MARK: - Кодировки

section("TextEncodings")
eq(TextEncodings.decode(Data([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x20, 0xB8, 0xA8, 0xB9]), charset: "windows-1251"), "Привет ёЁ№", "windows-1251")
eq(TextEncodings.decode(Data([0xCF, 0xF0, 0xE8]), charset: "CP1251"), "При", "cp1251 alias, регистр")
eq(TextEncodings.decode(Data([0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4, 0xA3, 0xB3]), charset: "koi8-r"), "ПриветёЁ", "koi8-r")
eq(TextEncodings.decode(Data([0xA4, 0xA6, 0xA7, 0xAD, 0xB4]), charset: "koi8-u"), "єіїґЄ", "koi8-u")
eq(TextEncodings.decode(Data([0xBF, 0xE0, 0xD8, 0xD2, 0xD5, 0xE2, 0xF0, 0xA1]), charset: "iso-8859-5"), "Привет№Ё", "iso-8859-5")
eq(TextEncodings.decode(Data([0x80, 0x93, 0x94, 0xE9]), charset: "windows-1252"), "€“”é", "windows-1252")
eq(TextEncodings.decode(Data([0x63, 0x61, 0x66, 0xE9]), charset: "iso-8859-1"), "café", "iso-8859-1")
eq(TextEncodings.decode(Data([0xFF, 0xFE, 0x1F, 0x04, 0x40, 0x04]), charset: "utf-16"), "Пр", "utf-16 с BOM")
eq(TextEncodings.decode(Data([0x04, 0x1F, 0x04, 0x40]), charset: "utf-16be"), "Пр", "utf-16be")
eq(TextEncodings.decode(Data("Привет".utf8), charset: "us-ascii"), "Привет", "us-ascii с 8-битным UTF-8")
eq(TextEncodings.decode(Data("Привет".utf8), charset: "\"UTF-8\""), "Привет", "utf-8 в кавычках")
eq(TextEncodings.decode(Data([0x41, 0xFF, 0x42]), charset: "utf-8"), "A\u{FFFD}B", "битый UTF-8 — lossy")
eq(TextEncodings.decode(Data([0x41, 0xE9]), charset: "x-unknown-charset"), "Aé", "неизвестная кодировка → latin1")
eq(TextEncodings.decode(Data("ok".utf8), charset: nil), "ok", "без charset")

section("Base64 / QP")
eq(MIMECodec.decodeBase64(Array("0J/RgNC4\r\n0LLQtdGC".utf8)), Array("Привет".utf8), "base64 с переносами")
eq(MIMECodec.decodeBase64(Array("0J/RgA".utf8)), Array("Пр".utf8), "base64 без паддинга")
eq(MIMECodec.decodeQuotedPrintable(Array("a=3Db=\r\nc  \r\nd=ZZ".utf8)), Array("a=bc\r\nd=ZZ".utf8), "QP: мягкий перенос, хвостовые пробелы, битый =ZZ")
let qpSample = "Строка ✓ = \"тест\"\r\nВторая строка, достаточно длинная, чтобы её пришлось переносить мягким переносом quoted-printable.\r\n.точка"
let qpEncoded = MIMECodec.encodeQuotedPrintable(Array(qpSample.utf8))
check(qpEncoded.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 }, "QP: строки ≤ 76")
eq(String(decoding: MIMECodec.decodeQuotedPrintable(Array(qpEncoded.utf8)), as: UTF8.self), qpSample, "QP: кодирование туда-обратно")

// MARK: - RFC 2047

section("RFC 2047")
eq(RFC2047.decode("=?windows-1251?B?zvL3uPIg5+Ag8eXt8v/h8Pw=?="), "Отчёт за сентябрь", "B windows-1251")
eq(RFC2047.decode("=?koi8-r?Q?=F3=CF=D7=C5=DD=C1=CE=C9=C5_=D7_=D0=D1=D4=CE=C9=C3=D5?="), "Совещание в пятницу", "Q koi8-r")
eq(RFC2047.decode("=?UTF-8?B?0J/RgNC4?= =?UTF-8?B?0LLQtdGC?="), "Привет", "соседние слова без пробела")
eq(RFC2047.decode("=?UTF-8?B?0J/R?=\r\n =?UTF-8?B?gNC40LLQtdGC?="), "Привет", "UTF-8 символ разрезан между словами")
eq(RFC2047.decode("Re: =?utf-8?Q?caf=C3=A9?= ok"), "Re: café ok", "текст вокруг encoded-word")
eq(RFC2047.decode("=?utf-8?q?a?= b =?utf-8?q?c?="), "a b c", "обычный текст между словами сохраняется")
eq(RFC2047.decode("=?utf-8*ru?B?0JTQsA==?="), "Да", "charset с языком RFC 2231")
eq(RFC2047.decode("=?broken"), "=?broken", "незавершённое слово — как есть")
let longSubject = "Очень длинная тема письма про квартальный отчёт, бюджет и планы на следующий год — ✓"
let encodedSubject = RFC2047.encode(longSubject)
check(encodedSubject.split(separator: " ").allSatisfy { $0.count <= 75 && $0.hasPrefix("=?UTF-8?B?") }, "encode: слова ≤ 75")
eq(RFC2047.decode(encodedSubject), longSubject, "encode → decode")
eq(RFC2047.encode("Plain ASCII"), "Plain ASCII", "ASCII не кодируется")

// MARK: - Адреса

section("Адреса")
do {
    let list = MIMEParser.parseAddressList(#""Иванов, Иван" <ivan@x.ru>, petr@y.ru, =?utf-8?B?0J/QtdGC0YA=?= <p@z.ru>"#)
    eq(list.count, 3, "три адреса")
    eq(list.first?.name, "Иванов, Иван", "запятая в кавычках")
    eq(list.first?.email, "ivan@x.ru", "email в <>")
    eq(list[1].name, nil, "адрес без имени")
    eq(list[1].email, "petr@y.ru", "адрес без скобок")
    eq(list[2].name, "Петр", "encoded-word в имени")

    let group = MIMEParser.parseAddressList(#"Команда: a@b.ru, "B, C" <b@c.ru>;, d@e.ru"#)
    eq(group.map(\.email), ["a@b.ru", "b@c.ru", "d@e.ru"], "группа")
    eq(group[1].name, "B, C", "имя в группе")
    eq(MIMEParser.parseAddressList("undisclosed-recipients:;"), [], "пустая группа")

    let tricky = MIMEParser.parseAddressList(#""Quote \"Nick\" Name" <q@x.com>, user@x.com (John Doe), <bare@x.com>, 'Outlook Name' <o@x.com>"#)
    eq(tricky.map(\.email), ["q@x.com", "user@x.com", "bare@x.com", "o@x.com"], "сложные адреса: email")
    eq(tricky.map(\.name), [#"Quote "Nick" Name"#, "John Doe", nil, "Outlook Name"], "сложные адреса: имена")
    let quotedEncoded = MIMEParser.parseAddressList(#""=?utf-8?B?0JDQvdC90LA=?=" <anna@x.ru>, "=?windows-1251?B?yOLg7Q==?=" <ivan@x.ru>"#)
    eq(quotedEncoded.map(\.name), ["Анна", "Иван"], "encoded-word внутри кавычек")
    eq(MIMEParser.parseAddressList(""), [], "пустая строка")
    eq(MIMEParser.parseAddressList("Name <weird@x.ru"), [Address(name: "Name", email: "weird@x.ru")], "незакрытая <")
    eq(MIMEParser.parseAddressList("same@x.ru <same@x.ru>").first?.name, nil, "имя = email → nil")
}

// MARK: - Даты

section("Даты")
let expected = utcDate(2026, 9, 29, 7, 15)
eq(MIMEParser.parseDate("Tue, 29 Sep 2026 10:15:00 +0300 (MSK)"), expected, "RFC 5322 + комментарий (MSK)")
eq(MIMEParser.parseDate("29 Sep 2026 10:15 +0300"), expected, "без дня недели и секунд")
eq(MIMEParser.parseDate("Tue, 29 Sep 26 07:15:00 GMT"), expected, "двузначный год, GMT")
eq(MIMEParser.parseDate("Tue, 29 Sep 2026 10:15:00 MSK"), expected, "буквенная зона MSK")
eq(MIMEParser.parseDate("Tue, 29 Sep 2026 03:15:00 EDT"), expected, "EDT")
eq(MIMEParser.parseDate("Tue Sep 29 07:15:00 2026"), expected, "asctime")
eq(MIMEParser.parseDate("Tue,  29  Sep  2026  07:15:00  -0000"), expected, "лишние пробелы, -0000")
eq(MIMEParser.parseDate("Tuesday, 29-Sep-2026"), nil, "непонятный формат → nil без падения")
eq(MIMEParser.parseDate("2026-09-29T10:15:00+03:00"), expected, "ISO 8601")
eq(MIMEParser.parseDate("garbage"), nil, "мусор → nil")

// MARK: - Outlook / Exchange

section("Outlook: cp1251, koi8-r, related + cid")
do {
    let m = MIMEParser.parse(crlf(Fixtures.outlook))
    eq(m.subject, "Отчёт за сентябрь", "тема windows-1251")
    eq(m.from, [Address(name: "Иванов Иван Иванович", email: "ivanov@corp.ru")], "From windows-1251")
    eq(m.to.map(\.name), ["Петров Пётр", "Сидорова, Анна"], "To: koi8-r Q + raw UTF-8 в кавычках, свёрнутый заголовок")
    eq(m.cc, [Address(name: "Бухгалтерия", email: "buh@corp.ru")], "Cc в стиле Outlook ('...')")
    eq(m.date, expected, "Date")
    eq(m.messageID, "AM0PR01MB1234ABCD@AM0PR01MB1234.eurprd01.prod.outlook.com", "Message-ID без <>")
    eq(m.textBody, "Коллеги, добрый день!\n\nОтчёт во вложении — смотрите картинку ниже.\n\nС уважением,\nИван", "text/plain cp1251 QP")
    check(m.htmlBody?.contains("cid:image001.png@01DB1234.56789AB0") == true, "HTML с cid")
    check(m.htmlBody?.contains("С уважением, Иван") == true, "HTML cp1251")
    eq(m.attachments.count, 1, "одно вложение")
    if let img = m.attachments.first {
        eq(img.filename, "image001.png", "имя картинки")
        eq(img.contentID, "image001.png@01DB1234.56789AB0", "Content-ID без <>")
        eq(img.isInline, true, "встроенная")
        eq(img.partID, "2", "partID картинки")
        eq(img.mimeType, "image/png", "mime картинки")
        eq(img.data.base64EncodedString(), Fixtures.outlookPNGBase64, "данные картинки")
    }
    eq(m.headers["thread-index"], "AdtCmxYzAbCdEfGh", "заголовки без учёта регистра")
    eq(m.headers.all("received").count, 1, "all()")
    check(m.headers["received"]?.contains("for <petrov@example.ru>") == true, "развёртка Received")
    eq(m.listUnsubscribe, nil, "нет List-Unsubscribe")
}

// MARK: - mixed(alternative, pdf RFC 2231)

section("multipart/mixed + alternative + PDF (RFC 2231)")
do {
    let m = MIMEParser.parse(crlf(Fixtures.mixed))
    eq(m.subject, "Совещание в пятницу", "тема koi8-r Q")
    eq(m.from.first?.name, #"Бухгалтерия ООО "Ромашка""#, "имя с экранированными кавычками")
    eq(m.date, utcDate(2026, 9, 28, 15, 0), "Date с (MSK)")
    eq(m.textBody, Fixtures.mixedText, "QP UTF-8 тело")
    eq(m.htmlBody, Fixtures.mixedHTML, "base64 HTML")
    eq(m.attachments.count, 1, "одно вложение")
    if let pdf = m.attachments.first {
        eq(pdf.filename, Fixtures.pdfName, "имя PDF из filename*0*/filename*1*")
        eq(pdf.mimeType, "application/pdf", "mime PDF")
        eq(pdf.partID, "2", "partID PDF")
        eq(pdf.isInline, false, "PDF не встроенный")
        eq(pdf.data.base64EncodedString(), Fixtures.mixedPDFBase64, "данные PDF")
    }
    // Номера частей в alternative: 1.1 и 1.2 — проверяем через вложения во вложенной структуре.
    let nested = """
    Content-Type: multipart/mixed; boundary=a

    --a
    Content-Type: multipart/alternative; boundary=b

    --b
    Content-Type: text/plain

    t
    --b
    Content-Type: multipart/related; boundary=c

    --c
    Content-Type: text/html

    <img src="cid:x@y">
    --c
    Content-Type: image/gif
    Content-ID: <x@y>
    Content-Transfer-Encoding: base64

    R0lGODlhAQABAAAAACw=
    --c--
    --b--
    --a
    Content-Type: application/octet-stream

    bin
    --a--
    """
    let n = MIMEParser.parse(crlf(nested))
    eq(n.attachments.map(\.partID), ["1.2.2", "2"], "IMAP-нумерация вложенных частей")
    eq(n.attachments.first?.isInline, true, "картинка в related — встроенная")
    eq(n.textBody, "t", "текст из alternative")
    eq(n.attachments.last?.filename, "part-2.bin", "сгенерированное имя")
}

// MARK: - Gmail

section("Gmail")
do {
    let m = MIMEParser.parse(crlf(Fixtures.gmail))
    eq(m.subject, Fixtures.gmailSubject, "тема: UTF-8 символ разрезан между encoded-words")
    eq(m.to, [Address(name: "Мой Ящик", email: "me@gmail.com")], "To UTF-8 B")
    eq(m.messageID, "CAE+0kX=Y1a2b3c4d5e6f7g8h9-Q@mail.gmail.com", "Message-ID")
    eq(m.inReplyTo, "CAD9999xyz@mail.gmail.com", "In-Reply-To без <>")
    eq(m.references, ["CAB1234abc@mail.gmail.com", "CAC5678def@mail.gmail.com", "CAD9999xyz@mail.gmail.com"], "References (свёрнутые, с табом)")
    eq(m.listUnsubscribe, "https://list.example.com/unsub?id=42&t=abc", "List-Unsubscribe: https приоритетнее")
    eq(m.listUnsubscribePost, true, "One-Click")
    eq(m.textBody, Fixtures.gmailText, "text/plain")
    eq(m.htmlBody, Fixtures.gmailHTML, "text/html")
    eq(m.date, utcDate(2026, 9, 29, 11, 0, 51), "Date")
    eq(m.attachments.count, 0, "без вложений")
    let mailtoOnly = MIMEParser.parse(crlf("List-Unsubscribe: <mailto:u@x.ru>\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\n\nhi"))
    eq(mailtoOnly.listUnsubscribe, "mailto:u@x.ru", "List-Unsubscribe: mailto")
}

// MARK: - Приглашения

section("text/calendar")
do {
    let m = MIMEParser.parse(crlf(Fixtures.invite))
    eq(m.from.first?.name, "Петров, Пётр", "From с запятой в encoded-word")
    check(m.calendar?.contains("BEGIN:VEVENT") == true, "calendar захвачен")
    eq(m.attachments.count, 0, "календарь в alternative — не вложение")
    eq(m.textBody, "Повестка: итоги квартала", "текст рядом с календарём")
    let events = ICSParser.parse(m.calendar ?? "")
    eq(events.count, 1, "одно событие")
    eq(events.first?.start, utcDate(2026, 10, 5, 7, 0), "TZID Russian Standard Time → UTC+3")

    // Gmail: календарь в alternative + application/ics вложением.
    let gmailInvite = """
    Subject: Invitation
    Content-Type: multipart/mixed; boundary="m"

    --m
    Content-Type: multipart/alternative; boundary="a"

    --a
    Content-Type: text/plain; charset="UTF-8"

    Invitation
    --a
    Content-Type: text/calendar; charset="UTF-8"; method=REQUEST

    BEGIN:VCALENDAR
    METHOD:REQUEST
    BEGIN:VEVENT
    DTSTART:20261005T070000Z
    DTEND:20261005T080000Z
    UID:abc@google.com
    SUMMARY:Sync
    END:VEVENT
    END:VCALENDAR
    --a--
    --m
    Content-Type: application/ics; name="invite.ics"
    Content-Disposition: attachment; filename="invite.ics"
    Content-Transfer-Encoding: base64

    QkVHSU46VkNBTEVOREFSDQpFTkQ6VkNBTEVOREFSDQo=
    --m--
    """
    let g = MIMEParser.parse(crlf(gmailInvite))
    eq(g.attachments.map(\.filename), ["invite.ics"], "invite.ics вложением")
    eq(ICSParser.parse(g.calendar ?? "").first?.uid, "abc@google.com", "календарь из alternative приоритетнее")
}

// MARK: - Прочие структуры

section("Прочие структуры и устойчивость")
do {
    // message/rfc822 вложение, signed, flowed, сырые 8-битные заголовки, RFC 2231 с windows-1251.
    let fwd = """
    Subject: Fwd
    Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha-256; boundary="s"

    --s
    Content-Type: multipart/mixed; boundary="m"

    --m
    Content-Type: text/plain; charset=utf-8; format=flowed; delsp=yes

    Это длинная строка, которая была разбита\u{20}
    по правилам format=flowed.
    > цитата\u{20}
    > продолжается
    --m
    Content-Type: message/rfc822

    Subject: =?utf-8?B?0JjRgdGF0L7QtNC90L7QtQ==?=
    From: a@b.ru

    body
    --m
    Content-Type: application/vnd.ms-excel
    Content-Disposition: attachment; filename*=windows-1251''%D2%E0%E1%EB%E8%F6%E0.xls

    xls
    --m--
    --s
    Content-Type: application/pkcs7-signature; name="smime.p7s"
    Content-Disposition: attachment; filename="smime.p7s"

    sig
    --s--
    """
    let m = MIMEParser.parse(crlf(fwd))
    eq(m.textBody, "Это длинная строка, которая была разбитапо правилам format=flowed.\n> цитатапродолжается", "format=flowed, delsp=yes")
    eq(m.attachments.map(\.filename), ["Исходное.eml", "Таблица.xls"], "rfc822 → .eml, RFC 2231 windows-1251, подпись скрыта")
    eq(m.attachments.map(\.partID), ["1.2", "1.3"], "partID внутри signed")

    // Сырой cp1251 в заголовках без кодирования (старые почтовики) — подсказка из charset.
    var raw = Data("Subject: ".utf8)
    raw.append(contentsOf: [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2])
    raw.append(Data("\r\nContent-Type: text/plain; charset=koi8-r\r\n\r\n".utf8))
    raw.append(contentsOf: [0xF0, 0xD2, 0xC9])
    let rm = MIMEParser.parse(raw)
    check(rm.subject.count == 6, "сырые 8-битные заголовки не ломают разбор", rm.subject)
    eq(rm.textBody, "При", "тело koi8-r без CTE")
    eq(TextEncodings.decode(Data([0xCF, 0xF0]), charset: nil).isEmpty, false, "nil charset не падает")

    // Имя файла в RFC 2047 внутри кавычек (Outlook/1С) и Content-Type name вместо filename.
    let outlookName = """
    Content-Type: multipart/mixed; boundary=x

    --x
    Content-Type: application/pdf; name="=?utf-8?B?0JTQvtCz0L7QstC+0YAucGRm?="
    Content-Transfer-Encoding: base64

    JVBERg==
    --x--
    """
    let on = MIMEParser.parse(crlf(outlookName))
    eq(on.attachments.first?.filename, "Договор.pdf", "RFC 2047 в name=")
    eq(on.attachments.first?.data, Data("%PDF".utf8), "base64 данных")

    // LF-окончания, нет закрывающей границы, пустое письмо, только заголовки.
    let lf = MIMEParser.parse(Data("Subject: LF\nContent-Type: multipart/alternative; boundary=q\n\n--q\nContent-Type: text/plain\n\nline1\nline2\n--q\nContent-Type: text/html\n\n<b>x</b>".utf8))
    eq(lf.subject, "LF", "LF-заголовки")
    eq(lf.textBody, "line1\nline2", "LF-тело")
    eq(lf.htmlBody, "<b>x</b>", "нет закрывающей границы")
    eq(MIMEParser.parse(Data()).subject, "", "пустые данные")
    eq(MIMEParser.parse(Data("Subject: only headers".utf8)).subject, "only headers", "только заголовки")
    eq(MIMEParser.parse(Data("Content-Type: multipart/mixed\r\n\r\nno boundary".utf8)).textBody, "no boundary", "multipart без boundary → текст")

    // Фаззинг: случайные байты и обрезки реальных писем не роняют парсер.
    var rng = SystemRandomNumberGenerator()
    var survived = 0
    for i in 0..<300 {
        var bytes = [UInt8]((0..<Int.random(in: 0...600, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        if i % 3 == 0 {
            let src = Array(crlf([Fixtures.outlook, Fixtures.mixed, Fixtures.gmail, Fixtures.invite][i % 4]))
            bytes = Array(src.prefix(Int.random(in: 0...src.count, using: &rng)))
            if !bytes.isEmpty { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
        }
        _ = MIMEParser.parse(Data(bytes))
        _ = ICSParser.parse(String(decoding: bytes, as: UTF8.self))
        _ = MIMEParser.parseAddressList(String(decoding: bytes.prefix(200), as: UTF8.self))
        _ = RFC2047.decode(String(decoding: bytes.prefix(200), as: UTF8.self))
        survived += 1
    }
    eq(survived, 300, "фаззинг 300 входов без падений")
}

// MARK: - Сборка писем

section("MIMEBuilder")
do {
    var rng = SystemRandomNumberGenerator()
    let binary = Data((0..<1500).map { _ in UInt8.random(in: 0...255, using: &rng) })
    let longName = "Коммерческое предложение ООО «Ромашка» на поставку оборудования 2026.pdf"
    let sent = OutgoingMIME(
        from: Address(name: "Илья Петров", email: "ilya@example.ru"),
        to: [Address(name: "Иванов, Иван", email: "ivan@x.ru"), Address(name: nil, email: "plain@x.ru")],
        cc: [Address(name: "Anna \"Ann\" Smith", email: "anna@x.com")],
        bcc: [Address(name: "Скрытый", email: "secret@x.ru")],
        subject: "Re: Очень длинная тема письма про квартальный отчёт, бюджет и планы — ✓",
        textBody: "Привет!\n.строка с точкой\n\nДлинная строка текста, которая точно превысит семьдесят шесть символов и будет перенесена.\nПока.",
        htmlBody: "<p>Привет!</p><p>Пока.</p>",
        attachments: [
            OutgoingAttachment(filename: longName, mimeType: "application/pdf", data: binary),
            OutgoingAttachment(filename: "report.txt", mimeType: "text/plain", data: Data("hello".utf8)),
        ],
        messageID: MIMEBuilder.makeMessageID(domain: "example.ru"),
        inReplyTo: "<orig@x.ru>",
        references: ["root@x.ru", "<orig@x.ru>"],
        date: utcDate(2026, 9, 29, 7, 15),
        extraHeaders: [("X-Mailer", "UniMail"), ("Bcc", "leak@x.ru"), ("Reply-To", MIMEBuilder.formatAddress(Address(name: "Илья", email: "reply@example.ru")))]
    )
    let data = MIMEBuilder.build(sent)
    let text = String(decoding: data, as: UTF8.self)
    let bytes = [UInt8](data)
    var bareLF = false
    for i in bytes.indices where bytes[i] == 10 && (i == 0 || bytes[i - 1] != 13) { bareLF = true }
    check(!bareLF, "только CRLF")
    check(bytes.allSatisfy { $0 < 0x80 }, "7-битный результат")
    let lines = text.components(separatedBy: "\r\n")
    check(lines.allSatisfy { $0.count <= 998 }, "строки ≤ 998")
    let headerLines = lines.prefix { !$0.isEmpty }
    check(headerLines.allSatisfy { $0.count <= 78 }, "заголовки ≤ 78", headerLines.filter { $0.count > 78 }.joined(separator: " | "))
    check(!headerLines.contains { $0.lowercased().hasPrefix("bcc:") } && !text.contains("secret@x.ru") && !text.contains("leak@x.ru"), "Bcc нет в заголовках")
    check(text.contains("MIME-Version: 1.0"), "MIME-Version")
    check(text.contains("Content-Type: multipart/mixed"), "multipart/mixed")
    check(text.contains("multipart/alternative"), "multipart/alternative")
    check(text.contains("filename*0*=utf-8''"), "RFC 2231 продолжения для длинного имени")
    check(text.contains("In-Reply-To: <orig@x.ru>"), "In-Reply-To со скобками")
    check(text.contains("References: <root@x.ru> <orig@x.ru>"), "References со скобками")
    check(text.contains("Date: Tue, 29 Sep 2026"), "Date en_US_POSIX")
    check(!sent.messageID.contains("<") && sent.messageID.hasSuffix("@example.ru"), "makeMessageID без <>")

    let back = MIMEParser.parse(data)
    eq(back.subject, sent.subject, "round-trip: тема")
    eq(back.from, [sent.from], "round-trip: from")
    eq(back.to, sent.to, "round-trip: to (запятая в имени)")
    eq(back.cc, sent.cc, "round-trip: cc (кавычки в имени)")
    eq(back.replyTo, [Address(name: "Илья", email: "reply@example.ru")], "round-trip: Reply-To")
    eq(back.messageID, sent.messageID, "round-trip: Message-ID")
    eq(back.inReplyTo, "orig@x.ru", "round-trip: In-Reply-To")
    eq(back.references, ["root@x.ru", "orig@x.ru"], "round-trip: References")
    eq(back.date, sent.date, "round-trip: дата")
    eq(back.textBody, sent.textBody, "round-trip: текст (QP, точка в начале строки)")
    eq(back.htmlBody, sent.htmlBody, "round-trip: HTML")
    eq(back.attachments.map(\.filename), [longName, "report.txt"], "round-trip: имена вложений")
    eq(back.attachments.first?.data, binary, "round-trip: бинарные данные")
    eq(back.attachments.first?.mimeType, "application/pdf", "round-trip: mime")
    eq(back.attachments.map(\.partID), ["2", "3"], "round-trip: partID")
    eq(back.headers["x-mailer"], "UniMail", "extraHeaders")
    check(text.components(separatedBy: "\r\n").filter { $0.count == 76 }.count >= 10, "base64 по 76 символов")

    // Только текст — без multipart.
    let simple = OutgoingMIME(from: Address(name: nil, email: "a@b.ru"), to: [Address(name: nil, email: "c@d.ru")],
                              subject: "Hi", textBody: "Just text", messageID: "<id1@b.ru>")
    let simpleText = String(decoding: MIMEBuilder.build(simple), as: UTF8.self)
    check(simpleText.contains("Content-Type: text/plain; charset=utf-8") && !simpleText.contains("multipart"), "только text/plain")
    check(simpleText.contains("Message-ID: <id1@b.ru>") && !simpleText.contains("<<"), "Message-ID нормализован")
    eq(MIMEParser.parse(MIMEBuilder.build(simple)).textBody, "Just text", "простое письмо туда-обратно")

    // Ответ на приглашение.
    let event = ICSParser.parse(Fixtures.outlookICS)[0]
    let ics = ICSBuilder.reply(to: event, attendee: Address(name: "Иванов Иван", email: "ivanov@corp.ru"), status: .accepted)
    let reply = OutgoingMIME(from: Address(name: "Иванов Иван", email: "ivanov@corp.ru"), to: [event.organizer!],
                             subject: "Принято: " + event.summary, textBody: "Иванов Иван принял приглашение.",
                             messageID: MIMEBuilder.makeMessageID(domain: "corp.ru"), calendar: (method: "REPLY", ics: ics))
    let replyData = MIMEBuilder.build(reply)
    let replyText = String(decoding: replyData, as: UTF8.self)
    check(replyText.contains("text/calendar; charset=utf-8; method=REPLY"), "text/calendar; method=REPLY")
    check(replyText.contains("multipart/alternative"), "календарь внутри alternative")
    let parsedReply = MIMEParser.parse(replyData)
    let replyEvents = ICSParser.parse(parsedReply.calendar ?? "")
    eq(replyEvents.first?.method, "REPLY", "METHOD:REPLY после round-trip")
    eq(replyEvents.first?.uid, event.uid, "UID после round-trip")
    eq(parsedReply.attachments.count, 0, "календарь не вложение")
}

// MARK: - SMTP

section("SMTP")

final class SMTPServerScript: @unchecked Sendable {
    var tls = false
    var authOK = false
    var loginStep = 0
    let advertise: String
    init(advertise: String) { self.advertise = advertise }

    func respond(_ s: String) -> String? {
        if s.hasPrefix("EHLO ") {
            var r = "250-smtp.test Hello [10.0.0.1]\r\n250-SIZE 35882577\r\n250-8BITMIME\r\n"
            if !tls { r += "250-STARTTLS\r\n" }
            r += "250-\(advertise)\r\n250-ENHANCEDSTATUSCODES\r\n250 SMTPUTF8\r\n"
            return r
        }
        if s == "STARTTLS\r\n" { tls = true; return "220 2.0.0 Ready to start TLS\r\n" }
        if s.hasPrefix("AUTH PLAIN ") {
            let token = s.dropFirst(11).trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedToken = Data([0] + Array("user@test.ru".utf8) + [0] + Array("пароль".utf8)).base64EncodedString()
            authOK = token == expectedToken
            return authOK ? "235 2.7.0 Accepted\r\n" : "535 5.7.8 Username and Password not accepted\r\n"
        }
        if s == "AUTH LOGIN\r\n" { loginStep = 1; return "334 VXNlcm5hbWU6\r\n" }
        if loginStep == 1 { loginStep = 2; return s == Data("user@test.ru".utf8).base64EncodedString() + "\r\n" ? "334 UGFzc3dvcmQ6\r\n" : "535 bad user\r\n" }
        if loginStep == 2 { loginStep = 0; return s == Data("пароль".utf8).base64EncodedString() + "\r\n" ? "235 ok\r\n" : "535 5.7.8 bad password\r\n" }
        if s.hasPrefix("MAIL FROM:") { return "250 2.1.0 OK\r\n" }
        if s.hasPrefix("RCPT TO:<bad") { return "550-5.1.1 The email account that you tried to reach does not exist.\r\n550 5.1.1 Please try again.\r\n" }
        if s.hasPrefix("RCPT TO:") { return "250 2.1.5 OK\r\n" }
        if s == "DATA\r\n" { return "354 Go ahead\r\n" }
        if s == "RSET\r\n" { return "250 OK\r\n" }
        if s == "QUIT\r\n" { return "221 2.0.0 closing connection\r\n" }
        if s.hasSuffix("\r\n.\r\n") { return "250 2.0.0 OK 1727600000 queued\r\n" }
        return "500 unknown\r\n"
    }
}

do {
    let server = SMTPServerScript(advertise: "AUTH LOGIN PLAIN XOAUTH2")
    let transport = ScriptedTransport(greeting: "220 smtp.test ESMTP ready\r\n", responder: server.respond)
    let client = SMTPClient(transport: transport, heloName: "mac.local")
    do {
        try await client.connect()
        let caps = try await client.ehlo()
        check(caps.contains("STARTTLS") && caps.contains("8BITMIME") && caps.contains("AUTH=PLAIN"), "EHLO: многострочные расширения", "\(caps)")
        eq(await client.maxMessageSize, 35882577, "SIZE")
        try await client.startTLS()
        check(transport.tlsStarted, "transport.startTLS вызван")
        let caps2 = await client.capabilities
        check(!caps2.contains("STARTTLS") && caps2.contains("AUTH=LOGIN"), "повторный EHLO после TLS")
        try await client.authenticate(username: "user@test.ru", password: "пароль")
        check(server.authOK, "AUTH PLAIN \\0user\\0pass")

        let message = "Subject: test\r\n\r\nline1\r\n.leading dot\r\n..two dots\nbare LF line\r\n."
        try await client.send(from: "user@test.ru", recipients: ["a@x.ru", "b@y.ru"], data: Data(message.utf8))
        let sentLines = transport.sent
        check(sentLines.contains("EHLO mac.local\r\n"), "EHLO с heloName")
        check(sentLines.contains { $0.hasPrefix("MAIL FROM:<user@test.ru> SIZE=") }, "MAIL FROM с SIZE")
        check(sentLines.contains("RCPT TO:<a@x.ru>\r\n") && sentLines.contains("RCPT TO:<b@y.ru>\r\n"), "RCPT TO для всех")
        let dataBlock = sentLines.first { $0.hasPrefix("Subject: test") } ?? ""
        eq(dataBlock, "Subject: test\r\n\r\nline1\r\n..leading dot\r\n...two dots\r\nbare LF line\r\n..\r\n.\r\n", "dot-stuffing, CRLF, завершающая точка")
        await client.quit()
        check(transport.sent.last == "QUIT\r\n", "QUIT")
    } catch {
        check(false, "SMTP-сессия", "\(error)")
    }
}

do {
    // AUTH LOGIN, когда PLAIN не объявлен; отказ получателя.
    let server = SMTPServerScript(advertise: "AUTH LOGIN")
    let transport = ScriptedTransport(greeting: "220-smtp.test first line\r\n220 ready\r\n", responder: server.respond)
    let client = SMTPClient(transport: transport)
    do {
        try await client.connect()
        try await client.ehlo()
        try await client.authenticate(username: "user@test.ru", password: "пароль")
        check(transport.sent.contains("AUTH LOGIN\r\n"), "AUTH LOGIN")
        do {
            try await client.send(from: "user@test.ru", recipients: ["ok@x.ru", "bad@x.ru"], data: Data("x".utf8))
            check(false, "отказ RCPT должен бросать")
        } catch let SMTPError.rejected(code, message) {
            eq(code, 550, "SMTPError.rejected(550)")
            check(message.contains("bad@x.ru") && message.contains("does not exist"), "текст отказа многострочный", message)
            check(transport.sent.contains("RSET\r\n"), "RSET после отказа")
        }
    } catch {
        check(false, "SMTP LOGIN-сессия", "\(error)")
    }
}

do {
    let server = SMTPServerScript(advertise: "AUTH PLAIN")
    let client = SMTPClient(transport: ScriptedTransport(greeting: "220 ok\r\n", responder: server.respond))
    do {
        try await client.connect()
        try await client.ehlo()
        try await client.authenticate(username: "user@test.ru", password: "wrong")
        check(false, "неверный пароль должен бросать")
    } catch SMTPError.authenticationFailed(let msg) {
        check(msg.contains("not accepted"), "535 → authenticationFailed", msg)
    } catch {
        check(false, "535 → authenticationFailed", "\(error)")
    }
    let bad = SMTPClient(transport: ScriptedTransport(greeting: "554 go away\r\n", responder: { _ in nil }))
    do {
        try await bad.connect()
        check(false, "554 при подключении должен бросать")
    } catch SMTPError.rejected(let code, _) {
        eq(code, 554, "приветствие 554 → rejected")
    } catch {
        check(false, "приветствие 554", "\(error)")
    }
}

// MARK: - ICS

section("ICS")
do {
    let events = ICSParser.parse(Fixtures.outlookICS)
    eq(events.count, 1, "одно VEVENT")
    let e = events[0]
    eq(e.method, "REQUEST", "METHOD")
    eq(e.uid, "040000008200E00074C5B7101A82E00800000000A1B2C3D4E5F6D901000000000000000010000000" + "1234567890ABCDEF", "UID со свёрткой")
    eq(e.summary, "Планёрка отдела", "SUMMARY с LANGUAGE")
    eq(e.start, utcDate(2026, 10, 5, 7, 0), "DTSTART TZID=Russian Standard Time")
    eq(e.end, utcDate(2026, 10, 5, 8, 30), "DTEND")
    eq(e.allDay, false, "не весь день")
    eq(e.location, "Переговорная 5, 3 этаж", "LOCATION с \\,")
    eq(e.organizer, Address(name: "Петров, Пётр", email: "petrov@corp.ru"), "ORGANIZER с CN в кавычках")
    eq(e.attendees.map(\.email), ["ivanov@corp.ru", "sidorova@corp.ru"], "ATTENDEE (свёрнутая строка)")
    eq(e.attendees.first?.name, "Иванов Иван", "CN участника")
    eq(e.sequence, 2, "SEQUENCE")

    let moscow = ICSParser.parse("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:m\r\nDTSTART;TZID=Europe/Moscow:20261005T100000\r\nDURATION:PT45M\r\nSUMMARY:a\\nb\\;c\\\\d\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    eq(moscow.first?.start, utcDate(2026, 10, 5, 7, 0), "TZID=Europe/Moscow")
    eq(moscow.first?.end, utcDate(2026, 10, 5, 7, 45), "DURATION PT45M")
    eq(moscow.first?.summary, "a\nb;c\\d", "unescape \\n \\; \\\\")
    eq(moscow.first?.method, nil, "без METHOD")

    let allDay = ICSParser.parse("BEGIN:VCALENDAR\nMETHOD:PUBLISH\nBEGIN:VEVENT\nUID:d\nDTSTART;VALUE=DATE:20261005\nSUMMARY:День\nEND:VEVENT\nEND:VCALENDAR")
    eq(allDay.first?.allDay, true, "VALUE=DATE → allDay")
    if let s = allDay.first?.start, let en = allDay.first?.end {
        eq(en.timeIntervalSince(s), 86_400, "весь день без DTEND — сутки")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        eq(cal.dateComponents([.year, .month, .day, .hour], from: s), DateComponents(year: 2026, month: 10, day: 5, hour: 0), "полночь в текущем поясе")
    }

    let zulu = ICSParser.parse("BEGIN:VEVENT\nUID:z\nDTSTART:20261005T070000Z\nDTEND:20261005T080000Z\nEND:VEVENT")
    eq(zulu.first?.start, utcDate(2026, 10, 5, 7, 0), "UTC (Z)")
    let floating = ICSParser.parse("BEGIN:VEVENT\nUID:f\nDTSTART:20261005T100000\nEND:VEVENT")
    var localCal = Calendar(identifier: .gregorian); localCal.timeZone = .current
    eq(floating.first.map { localCal.component(.hour, from: $0.start) }, 10, "плавающее время → текущий пояс")
    let windowsLabel = ICSParser.parse("BEGIN:VEVENT\nUID:w\nDTSTART;TZID=\"(UTC+03:00) Moscow, St. Petersburg\":20261005T100000\nEND:VEVENT")
    eq(windowsLabel.first?.start, utcDate(2026, 10, 5, 7, 0), "TZID «(UTC+03:00) Moscow…»")
    let mozilla = ICSParser.parse("BEGIN:VEVENT\nUID:w\nDTSTART;TZID=/mozilla.org/20050126_1/Europe/Moscow:20261005T100000\nEND:VEVENT")
    eq(mozilla.first?.start, utcDate(2026, 10, 5, 7, 0), "TZID Mozilla")
    let custom = ICSParser.parse("BEGIN:VCALENDAR\nBEGIN:VTIMEZONE\nTZID:Customized Time Zone\nBEGIN:STANDARD\nTZOFFSETTO:+0500\nEND:STANDARD\nEND:VTIMEZONE\nBEGIN:VEVENT\nUID:c\nDTSTART;TZID=Customized Time Zone:20261005T120000\nEND:VEVENT\nEND:VCALENDAR")
    eq(custom.first?.start, utcDate(2026, 10, 5, 7, 0), "TZID из VTIMEZONE (TZOFFSETTO)")
    for (win, iana) in [("Russian Standard Time", "Europe/Moscow"), ("UTC", "UTC"), ("W. Europe Standard Time", "Europe/Berlin"), ("Pacific Standard Time", "America/Los_Angeles")] {
        eq(ICSParser.timeZone(for: win).identifier, TimeZone(identifier: iana)!.identifier, "Windows TZ \(win)")
    }
    eq(ICSParser.parseDuration("P1DT2H30M"), 95_400, "DURATION P1DT2H30M")
    eq(ICSParser.parseDuration("-PT15M"), -900, "DURATION -PT15M")
    eq(ICSParser.parseDuration("P1W"), 604_800, "DURATION P1W")
    eq(ICSParser.parse("BEGIN:VEVENT\nSUMMARY:no start\nEND:VEVENT").count, 0, "без DTSTART — пропуск")

    let now = utcDate(2026, 9, 29, 8, 0)
    let reply = ICSBuilder.reply(to: e, attendee: Address(name: "Иванов Иван", email: "ivanov@corp.ru"), status: .accepted, now: now)
    for needle in ["BEGIN:VCALENDAR\r\n", "PRODID:-//UniMail//RU", "VERSION:2.0", "METHOD:REPLY", "SEQUENCE:2", "DTSTAMP:20260929T080000Z",
                   "DTSTART:20261005T070000Z", "DTEND:20261005T083000Z", "ORGANIZER;CN=\"Петров, Пётр\":mailto:petrov@corp.ru",
                   "ATTENDEE;PARTSTAT=ACCEPTED;CN=\"Иванов Иван\":mailto:ivanov@corp.ru", "SUMMARY:Планёрка отдела", "END:VCALENDAR\r\n"] {
        check(reply.replacingOccurrences(of: "\r\n ", with: "").contains(needle), "reply содержит \(needle.trimmingCharacters(in: .newlines))")
    }
    check(reply.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 }, "reply: строки ≤ 75 октетов")
    let reparsed = ICSParser.parse(reply)
    eq(reparsed.first?.uid, e.uid, "reply → parse: UID (свёрнутый)")
    eq(reparsed.first?.start, e.start, "reply → parse: DTSTART")
    eq(reparsed.first?.end, e.end, "reply → parse: DTEND")
    eq(reparsed.first?.method, "REPLY", "reply → parse: METHOD")
    eq(reparsed.first?.attendees, [Address(name: "Иванов Иван", email: "ivanov@corp.ru")], "reply → parse: ATTENDEE")
    let declined = ICSBuilder.reply(to: allDay[0], attendee: Address(name: nil, email: "x@y.ru"), status: .declined)
    check(declined.contains("DTSTART;VALUE=DATE:20261005") && declined.contains("ATTENDEE;PARTSTAT=DECLINED:mailto:x@y.ru"), "reply на событие на весь день")
}

// MARK: - Итог

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
