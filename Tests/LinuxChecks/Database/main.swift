import Foundation
import SQLite3

// Проверки MailDatabase на Linux (swiftc 6.0.3, -swift-version 5).
// Сборка из корня проекта:
//   swiftc -swift-version 5 -I Tests/LinuxChecks/Database \
//     Sources/UniMail/Core/Models/*.swift Sources/UniMail/Core/Store/Database/*.swift \
//     Tests/LinuxChecks/Database/main.swift -o dbtest && ./dbtest

// MARK: - Мини-фреймворк

var passed = 0
var failed = 0

func check(_ condition: @autoclosure () throws -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    do {
        if try condition() {
            passed += 1
            print("PASS  \(name)")
        } else {
            failed += 1
            print("FAIL  \(name)  (line \(line))")
        }
    } catch {
        failed += 1
        print("FAIL  \(name) — threw \(error)  (line \(line))")
    }
}

func checkEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, _ name: String, line: Int = #line) {
    do {
        let value = try actual()
        if value == expected {
            passed += 1
            print("PASS  \(name)")
        } else {
            failed += 1
            print("FAIL  \(name)  (line \(line))\n      expected: \(expected)\n      actual:   \(value)")
        }
    } catch {
        failed += 1
        print("FAIL  \(name) — threw \(error)  (line \(line))")
    }
}

func checkThrows(_ body: () throws -> Void, _ name: String, line: Int = #line) {
    do {
        try body()
        failed += 1
        print("FAIL  \(name) — expected an error  (line \(line))")
    } catch {
        passed += 1
        print("PASS  \(name)  [\(error)]")
    }
}

func section(_ title: String) { print("\n== \(title) ==") }

func must<T>(_ body: @autoclosure () throws -> T, line: Int = #line) -> T {
    do { return try body() } catch {
        print("FATAL (line \(line)): \(error)")
        exit(2)
    }
}

// MARK: - Данные

let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("unimail-dbtest-\(UUID().uuidString)", isDirectory: true)

let accountA = UUID()
let accountB = UUID()
let base = Date(timeIntervalSince1970: 1_790_000_000)

func makeMessage(
    id: String,
    account: UUID = accountA,
    subject: String = "Тема",
    body: String = "Текст",
    from: Address = Address(name: "Иван Петров", email: "ivan@example.com"),
    to: [Address] = [Address(name: "Анна", email: "anna@example.org")],
    date: Date = base,
    role: MailboxRole = .inbox,
    isRead: Bool = false
) -> Message {
    Message(
        id: id, accountID: account, threadID: "t-\(id)", role: role,
        from: from, to: to, subject: subject, body: body, date: date, isRead: isRead)
}

/// Письмо со всеми необязательными полями.
func makeFullMessage(id: String) -> Message {
    var m = makeMessage(id: id, subject: "Полное письмо", body: "Тело\n\nвторой абзац")
    m.cc = [Address(name: nil, email: "cc@example.com"), Address(name: "Бухгалтерия", email: "buh@corp.ru")]
    m.htmlBody = "<p>Тело</p>"
    m.isFlagged = true
    m.attachments = [
        Attachment(id: UUID(), filename: "Договор.pdf", size: 123_456, mimeType: "application/pdf",
                   partID: "1.2", contentID: "cid-1", localPath: "/tmp/a.pdf"),
        Attachment(filename: "photo.jpg", size: 10, mimeType: "image/jpeg"),
    ]
    m.category = .newsletters
    m.snoozedUntil = base.addingTimeInterval(3600)
    m.scheduledAt = base.addingTimeInterval(7200)
    m.invite = Invite(title: "Созвон", start: base.addingTimeInterval(86_400),
                      end: base.addingTimeInterval(90_000), location: "Zoom")
    m.oneTimeCode = "123 456"
    m.folder = "INBOX"
    m.uid = 4_000_000_000
    m.headerMessageID = "<abc@example.com>"
    m.inReplyToHeader = "<prev@example.com>"
    m.references = ["<r1@example.com>", "<r2@example.com>"]
    m.listUnsubscribe = "<https://example.com/unsub>"
    m.listUnsubscribePost = true
    m.labels = ["\\Important", "Работа"]
    m.bodyPending = false
    m.followUpAt = base.addingTimeInterval(3 * 86_400)
    m.noReplyNotice = true
    return m
}

// MARK: - Схема

section("Схема")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
let dbURL = tmpDir.appendingPathComponent("nested/dir/mail.sqlite")
var db: MailDatabase! = must(try MailDatabase(url: dbURL))
check(FileManager.default.fileExists(atPath: dbURL.path), "файл базы создан (включая промежуточные папки)")

let inspector = must(try DatabaseConnection(path: dbURL.path))
func tableNames() throws -> Set<String> {
    Set(try inspector.query("SELECT name FROM sqlite_master WHERE type IN ('table','index')") { $0.text(0) ?? "" })
}
let names = must(try tableNames())
for table in ["messages", "bodies", "messages_fts", "sync_state", "pending_actions",
              "idx_messages_account_role_date", "idx_messages_thread"] {
    check(names.contains(table), "объект схемы \(table) существует")
}
checkEqual(try inspector.pragmaInt("user_version"), MailDatabase.schemaVersion, "user_version = schemaVersion")
checkEqual(try inspector.queryFirst("PRAGMA journal_mode") { $0.text(0) } ?? nil, "wal", "journal_mode = WAL")
check(try inspector.queryFirst("SELECT sqlite_compileoption_used('ENABLE_FTS5')") { $0.int64(0) } == 1
      || names.contains("messages_fts"), "FTS5 доступен в системном SQLite")
print("      SQLite \(String(cString: sqlite3_libversion()))")

// MARK: - Round-trip

section("Upsert / load")
let full = makeFullMessage(id: "full-1")
must(try db.upsert([full]))
let loaded = must(try db.message(id: "full-1"))
checkEqual(loaded, full, "round-trip сохраняет все поля Message (включая optional)")
checkEqual(loaded?.invite, full.invite, "invite сохранён")
checkEqual(loaded?.attachments, full.attachments, "attachments сохранены")
checkEqual(loaded?.uid, 4_000_000_000, "uid (UInt32 > Int32.max) сохранён")
checkEqual(loaded?.references ?? [], full.references ?? [], "references сохранены")
checkEqual(loaded?.cc.count, 2, "cc сохранён")

let minimal = makeMessage(id: "min-1")
must(try db.upsert([minimal]))
let loadedMin = must(try db.message(id: "min-1"))
checkEqual(loadedMin, minimal, "round-trip письма без optional-полей")
check(loadedMin?.invite == nil && loadedMin?.folder == nil && loadedMin?.uid == nil, "nil-поля остаются nil")

// Дата с дробной частью (секунды с 1970 в Double).
var fractional = makeMessage(id: "frac-1")
fractional.date = Date(timeIntervalSince1970: 1_790_000_000.123)
must(try db.upsert([fractional]))
let fracLoaded = must(try db.message(id: "frac-1"))
check(abs((fracLoaded?.date.timeIntervalSince1970 ?? 0) - 1_790_000_000.123) < 1e-6, "дробная дата сохраняется с точностью < 1 мкс")

checkEqual(try db.message(id: "missing"), nil, "message(id:) для неизвестного id — nil")

// Детерминированность JSON: одно и то же письмо → одинаковые байты.
let blob1 = must(try inspector.queryFirst("SELECT data FROM messages WHERE id = 'full-1'") { $0.blob(0) } ?? nil)
must(try db.upsert([full]))
let blob2 = must(try inspector.queryFirst("SELECT data FROM messages WHERE id = 'full-1'") { $0.blob(0) } ?? nil)
check(blob1 != nil && blob1 == blob2, "JSON детерминирован (sortedKeys, secondsSince1970)")

section("Обновление")
var updated = full
updated.subject = "Изменённая тема"
updated.isRead = true
updated.role = .archive
updated.labels = nil
must(try db.upsert([updated]))
checkEqual(try db.message(id: "full-1"), updated, "upsert обновляет существующее письмо")
checkEqual(try db.allMessages().filter { $0.id == "full-1" }.count, 1, "обновление не создаёт дубликат")
checkEqual(try inspector.queryFirst("SELECT is_read || role FROM messages WHERE id = 'full-1'") { $0.text(0) } ?? nil,
           "1archive", "денормализованные колонки обновлены")
checkEqual(try db.search("изменённая", accountID: nil, limit: 10), ["full-1"], "FTS видит новую тему")
checkEqual(try db.search("\"полное письмо\"", accountID: nil, limit: 10), [], "FTS не видит старую тему")
checkEqual(try inspector.queryFirst("SELECT count(*) FROM messages_fts WHERE id = 'full-1'") { $0.int64(0) }, 1,
           "в FTS ровно одна строка на письмо")

section("allMessages")
let all = must(try db.allMessages())
checkEqual(all.count, 3, "allMessages возвращает все письма")
check(zip(all, all.dropFirst()).allSatisfy { $0.date >= $1.date }, "allMessages отсортированы по дате (новые сверху)")

section("Удаление")
must(try db.setBody(StoredBody(text: "тело для удаления", html: nil), for: "min-1"))
must(try db.delete(ids: ["min-1", "not-existing"]))
checkEqual(try db.message(id: "min-1"), nil, "письмо удалено")
check(try db.body(for: "min-1") == nil, "тело удалено каскадом")
checkEqual(try inspector.queryFirst("SELECT count(*) FROM messages_fts WHERE id = 'min-1'") { $0.int64(0) }, 0,
           "строка FTS удалена")
checkEqual(try db.search("удаления", accountID: nil, limit: 10), [], "поиск не находит удалённое")
must(try db.delete(ids: []))

// MARK: - Поиск

section("FTS поиск")
must(try db.upsert([
    makeMessage(id: "ru-1", subject: "Договор поставки № 15", body: "Прошу подписать договор до пятницы.",
                from: Address(name: "Мария Сидорова", email: "maria@supplier.ru"), date: base.addingTimeInterval(10)),
    makeMessage(id: "ru-2", subject: "Счёт на оплату", body: "Во вложении счёт по договору поставки.",
                from: Address(name: "Бухгалтерия", email: "buh@supplier.ru"), date: base.addingTimeInterval(20)),
    makeMessage(id: "en-1", subject: "Quarterly report", body: "Please review the attached report before Monday.",
                from: Address(name: "John Smith", email: "john@acme.com"),
                to: [Address(name: "Team", email: "team@acme.com")], date: base.addingTimeInterval(30)),
    makeMessage(id: "en-2", account: accountB, subject: "Re: Report draft", body: "Looks good, reporting done.",
                from: Address(name: "Ivan", email: "ivan@acme.com"), date: base.addingTimeInterval(40)),
    makeMessage(id: "mix-1", account: accountB, subject: "Café meeting — Ёлка", body: "Встреча в кафе résumé",
                from: Address(name: "Élodie", email: "elodie@example.fr"), date: base.addingTimeInterval(50)),
]))
checkEqual(Set(try db.search("догов", accountID: nil, limit: 10)), ["ru-1", "ru-2"], "префикс «догов» находит «договор/договору»")
checkEqual(try db.search("ДОГОВОР пятницы", accountID: nil, limit: 10), ["ru-1"], "регистр не важен, термы через AND")
checkEqual(Set(try db.search("report", accountID: nil, limit: 10)), ["en-1", "en-2"], "английский префикс report* (report, reporting)")
checkEqual(try db.search("quart", accountID: nil, limit: 10), ["en-1"], "английский префикс quart*")
checkEqual(try db.search("cafe", accountID: nil, limit: 10), ["mix-1"], "remove_diacritics: cafe ≈ Café")
checkEqual(try db.search("resume", accountID: nil, limit: 10), ["mix-1"], "remove_diacritics: resume ≈ résumé")
checkEqual(try db.search("поставки", accountID: nil, limit: 10).first, "ru-1", "bm25: совпадение в теме выше, чем в теле")
checkEqual(try db.search("report", accountID: nil, limit: 1).count, 1, "limit соблюдается")
checkEqual(try db.search("report", accountID: nil, limit: 0).count, 2, "limit 0 — без ограничения")

section("Фильтр аккаунта")
checkEqual(try db.search("report", accountID: accountA, limit: 10), ["en-1"], "accountID фильтрует результаты")
checkEqual(try db.search("report", accountID: accountB, limit: 10), ["en-2"], "другой аккаунт")
checkEqual(try db.search("договор", accountID: accountB, limit: 10), [], "нет совпадений в аккаунте B")

section("Токены from:/subject:/to:")
checkEqual(Set(try db.search("from:supplier", accountID: nil, limit: 10)), ["ru-1", "ru-2"], "from: по домену")
checkEqual(try db.search("from:мари", accountID: nil, limit: 10), ["ru-1"], "from: по имени с префиксом")
checkEqual(try db.search("from:maria@supplier.ru", accountID: nil, limit: 10), ["ru-1"], "from: полный email")
checkEqual(try db.search("From:\"Мария Сидорова\"", accountID: nil, limit: 10), ["ru-1"], "from: с фразой в кавычках, регистр оператора")
checkEqual(Set(try db.search("from:ivan", accountID: nil, limit: 10)), ["full-1", "frac-1", "en-2"], "from: ищет по отправителю")
checkEqual(try db.search("from:anna", accountID: nil, limit: 10), [], "from: не ищет по получателям")
checkEqual(try db.search("subject:договор", accountID: nil, limit: 10), ["ru-1"], "subject: только по теме")
checkEqual(Set(try db.search("договор", accountID: nil, limit: 10)), ["ru-1", "ru-2"], "без subject: — по всем колонкам")
checkEqual(try db.search("subject:report from:john", accountID: nil, limit: 10), ["en-1"], "комбинация subject: и from:")
checkEqual(try db.search("to:team", accountID: nil, limit: 10), ["en-1"], "to: по получателям")
checkEqual(try db.search("счёт is:unread has:attachment", accountID: nil, limit: 10), ["ru-2"], "is:/has: игнорируются FTS")

section("Безопасность ввода")
let failedBeforeHostile = failed
for hostile in ["\"", "\"\"\"", "AND", "OR NOT", "NEAR(a b)", "*", "a*b\"c", "subject:", "from:\"", "( ) : ^ - +",
                "договор\" OR \"x", "' ; DROP TABLE messages; --", "{sender}:x", "col:x", "   ", "",
                "\u{0}", "a:b:c", "report AND"] {
    do {
        _ = try db.search(hostile, accountID: nil, limit: 10)
    } catch {
        failed += 1
        print("FAIL  search(\(hostile.debugDescription)) threw \(error)")
    }
}
check(failed == failedBeforeHostile, "враждебный ввод не приводит к ошибкам FTS5")
checkEqual(try db.search("AND", accountID: nil, limit: 10), [], "слово AND ищется как текст, а не оператор")
checkEqual(try db.search("договор\" OR \"report", accountID: nil, limit: 10), [], "кавычки не дают внедрить OR")
checkEqual(try db.allMessages().count, 7, "таблица messages цела после «DROP TABLE» во вводе")
checkEqual(MailFTS.matchExpression(for: "from:ivan догов \"точная фраза\""),
           "sender : \"ivan\"* AND \"догов\"* AND \"точная фраза\"", "вид выражения MATCH")
checkEqual(MailFTS.matchExpression(for: "- * ::"), nil, "только пунктуация → nil")

section("Тело письма (setBody)")
must(try db.upsert([makeMessage(id: "html-1", subject: "Уведомление", body: "")]))
must(try db.setBody(StoredBody(text: nil, html: """
    <html><head><title>ignored title</title><style>.x{color:red} .секрет{}</style></head>
    <body><script>var hiddenScript = "скрытыйскрипт";</script>
    <p>Код&nbsp;активации: <b>ZX</b>91 &laquo;Облако&raquo; &#1076;&#x43E;ступ</p><!-- комментарийхтмл -->
    <a href="https://example.com/?a=1&b=2" title="атрибутсекрет">ссылка</a> 5 &lt; 6</body></html>
    """), for: "html-1"))
checkEqual(try db.search("активации", accountID: nil, limit: 10), ["html-1"], "текст из HTML индексирован")
checkEqual(try db.search("ZX91", accountID: nil, limit: 10), ["html-1"], "инлайн-теги не разрывают слово")
checkEqual(try db.search("облако доступ", accountID: nil, limit: 10), ["html-1"], "сущности декодированы")
checkEqual(try db.search("hiddenScript", accountID: nil, limit: 10), [], "содержимое <script> не индексируется")
checkEqual(try db.search("секрет", accountID: nil, limit: 10), [], "стили и атрибуты не индексируются")
checkEqual(try db.search("комментарийхтмл", accountID: nil, limit: 10), [], "комментарии не индексируются")
checkEqual(try db.search("href", accountID: nil, limit: 10), [], "имена тегов/атрибутов не индексируются")
checkEqual(try db.search("subject:уведомление", accountID: nil, limit: 10), ["html-1"], "тема сохранилась после setBody")
check(try db.body(for: "html-1")?.html?.contains("<script>") == true, "body(for:) возвращает исходный HTML")

must(try db.setBody(StoredBody(text: "Полный текст с расшифровкой протокола", html: "<p>другое</p>"), for: "ru-1"))
checkEqual(try db.search("расшифров", accountID: nil, limit: 10), ["ru-1"], "текстовое тело индексировано")
checkEqual(try db.search("другое", accountID: nil, limit: 10), [], "при наличии text HTML не индексируется")
checkEqual(try db.search("пятницы", accountID: nil, limit: 10), ["ru-1"], "Message.body остаётся в индексе вместе с телом")
checkEqual(try db.body(for: "ru-1"), StoredBody(text: "Полный текст с расшифровкой протокола", html: "<p>другое</p>"), "body(for:) round-trip")

// Upsert после setBody сохраняет тело и его индексацию.
var ru1 = must(try db.message(id: "ru-1"))!
ru1.isRead = true
must(try db.upsert([ru1]))
check(try db.body(for: "ru-1") != nil, "upsert не удаляет скачанное тело")
checkEqual(try db.search("расшифров", accountID: nil, limit: 10), ["ru-1"], "upsert сохраняет тело в FTS")
checkThrows({ try db.setBody(StoredBody(text: "x", html: nil), for: "no-such-message") }, "setBody для несуществующего письма — ошибка FK")
checkEqual(try db.body(for: "nope"), nil, "body(for:) для неизвестного id — nil")

section("HTML → текст")
checkEqual(MailFTS.plainText(fromHTML: "<div>a</div><div>b</div>"), "a b", "блочные теги разделяют слова")
checkEqual(MailFTS.plainText(fromHTML: "a < b &amp; c > d"), "a < b & c > d", "одиночный < не считается тегом")
checkEqual(MailFTS.plainText(fromHTML: "<img alt=\"x > y\" src=a>текст"), " текст".trimmingCharacters(in: .whitespaces), "> внутри атрибута")
checkEqual(MailFTS.plainText(fromHTML: "&unknown; &#128512;"), "&unknown; 😀", "неизвестная сущность остаётся, числовая декодируется")

// MARK: - Sync state

section("Состояние синхронизации")
checkEqual(try db.syncState(accountID: accountA, folder: "INBOX"), nil, "нет состояния — nil")
let st1 = FolderSyncState(accountID: accountA, folder: "INBOX", uidValidity: 4_294_967_295,
                          highestModSeq: 9_000_000_000_000_000_001, lastUID: 3_000_000_000)
must(try db.setSyncState(st1))
checkEqual(try db.syncState(accountID: accountA, folder: "INBOX"), st1, "сохранение и чтение (большие UInt32/UInt64)")
var st2 = st1
st2.highestModSeq = nil
st2.lastUID = 42
must(try db.setSyncState(st2))
checkEqual(try db.syncState(accountID: accountA, folder: "INBOX"), st2, "обновление, highestModSeq = nil")
let st3 = FolderSyncState(accountID: accountA, folder: "[Gmail]/Отправленные", uidValidity: 1, highestModSeq: 5, lastUID: 7)
must(try db.setSyncState(st3))
checkEqual(try db.syncState(accountID: accountA, folder: "[Gmail]/Отправленные"), st3, "вторая папка (Юникод в имени)")
checkEqual(try db.syncState(accountID: accountB, folder: "INBOX"), nil, "состояния разделены по аккаунтам")
must(try db.setSyncState(FolderSyncState(accountID: accountB, folder: "INBOX", uidValidity: 2, highestModSeq: nil, lastUID: 1)))

// MARK: - Pending actions

section("Очередь действий")
let payload = Data("{\"uids\":[1,2,3]}".utf8)
let act1 = PendingActionRecord(id: UUID(), accountID: accountA, kind: "markRead", payload: payload,
                               createdAt: Date(timeIntervalSince1970: 1_790_000_100), attempts: 0)
let act2 = PendingActionRecord(id: UUID(), accountID: accountA, kind: "move", payload: Data(),
                               createdAt: Date(timeIntervalSince1970: 1_790_000_050), attempts: 1)
let act3 = PendingActionRecord(id: UUID(), accountID: accountB, kind: "send", payload: Data([0, 1, 2, 255]),
                               createdAt: Date(timeIntervalSince1970: 1_790_000_200), attempts: 0)
must(try db.enqueue(act1))
must(try db.enqueue(act2))
must(try db.enqueue(act3))
checkEqual(try db.pendingActions(accountID: accountA), [act2, act1], "фильтр по аккаунту и порядок по created_at")
checkEqual(try db.pendingActions(accountID: nil), [act2, act1, act3], "все действия")
checkEqual(try db.pendingActions(accountID: nil).first?.payload, Data(), "пустой payload сохраняется как пустой")
var act1b = act1
act1b.attempts = 3
act1b.payload = Data("retry".utf8)
must(try db.updateAction(act1b))
checkEqual(try db.pendingActions(accountID: accountA).last, act1b, "updateAction")
must(try db.enqueue(act1b))
checkEqual(try db.pendingActions(accountID: accountA).count, 2, "повторный enqueue того же id не дублирует")
must(try db.removeAction(id: act2.id))
checkEqual(try db.pendingActions(accountID: accountA), [act1b], "removeAction")
must(try db.updateAction(PendingActionRecord(id: UUID(), accountID: accountA, kind: "x", payload: Data(), createdAt: base, attempts: 0)))
checkEqual(try db.pendingActions(accountID: accountA).count, 1, "updateAction для неизвестного id ничего не добавляет")

// MARK: - Битые строки

section("Битые строки пропускаются")
must(try db.upsert([makeMessage(id: "broken-1", subject: "сломанное")]))
_ = must(try inspector.run("UPDATE messages SET data = x'7B6E6F74206A736F6E' WHERE id = 'broken-1'"))
let countWithBroken = must(try inspector.queryFirst("SELECT count(*) FROM messages") { $0.int64(0) }) ?? 0
checkEqual(Int64(must(try db.allMessages()).count), countWithBroken - 1, "allMessages пропускает недекодируемую строку")
checkEqual(try db.message(id: "broken-1"), nil, "message(id:) для битой строки — nil")
must(try db.delete(ids: ["broken-1"]))

// MARK: - deleteAccount

section("deleteAccount")
must(try db.setBody(StoredBody(text: "тело B", html: nil), for: "en-2"))
let beforeA = must(try db.allMessages()).filter { $0.accountID == accountA }.count
must(try db.deleteAccount(accountB))
checkEqual(try db.allMessages().filter { $0.accountID == accountB }.count, 0, "письма аккаунта удалены")
checkEqual(try db.allMessages().filter { $0.accountID == accountA }.count, beforeA, "письма другого аккаунта целы")
checkEqual(try db.body(for: "en-2"), nil, "тела аккаунта удалены")
checkEqual(try db.search("reporting", accountID: nil, limit: 10), [], "FTS-строки аккаунта удалены")
checkEqual(try inspector.queryFirst("SELECT count(*) FROM messages_fts") { $0.int64(0) },
           try inspector.queryFirst("SELECT count(*) FROM messages") { $0.int64(0) }, "FTS и messages согласованы")
checkEqual(try db.syncState(accountID: accountB, folder: "INBOX"), nil, "sync_state аккаунта удалён")
checkEqual(try db.pendingActions(accountID: accountB), [], "pending_actions аккаунта удалены")
checkEqual(try db.syncState(accountID: accountA, folder: "INBOX"), st2, "sync_state другого аккаунта цел")
checkEqual(try db.pendingActions(accountID: accountA).count, 1, "pending_actions другого аккаунта целы")
checkEqual(try db.search("договор", accountID: nil, limit: 10).count, 2, "поиск по оставшемуся аккаунту работает")

// MARK: - Потоки

section("Параллельный доступ")
let concurrentErrors = NSLock()
var concurrentFailures = 0
DispatchQueue.concurrentPerform(iterations: 8) { worker in
    do {
        let batch = (0..<50).map { makeMessage(id: "cc-\(worker)-\($0)", subject: "параллельно \(worker)") }
        try db.upsert(batch)
        _ = try db.search("параллельно", accountID: nil, limit: 5)
        _ = try db.allMessages()
    } catch {
        concurrentErrors.lock(); concurrentFailures += 1; concurrentErrors.unlock()
    }
}
checkEqual(concurrentFailures, 0, "параллельные upsert/search/load без ошибок")
checkEqual(try db.search("параллельно", accountID: nil, limit: 0).count, 400, "все 400 параллельных писем на месте")

// MARK: - Производительность

section("Производительность")
let bulk: [Message] = (0..<10_000).map { i in
    var m = makeMessage(id: "bulk-\(i)", account: i % 2 == 0 ? accountA : accountB,
                        subject: "Пакетное письмо номер \(i) invoice",
                        body: "Текст письма \(i). Lorem ipsum dolor sit amet, договор поставки, счёт \(i % 97).",
                        date: base.addingTimeInterval(Double(i)))
    m.folder = "INBOX"; m.uid = UInt32(i + 1); m.references = ["<\(i)@x>"]
    return m
}
var t0 = Date()
must(try db.upsert(bulk))
let insertTime = Date().timeIntervalSince(t0)
print(String(format: "      вставка 10 000: %.3f s", insertTime))
check(insertTime < 3.0, "upsert 10 000 новых писем < 3 с")

t0 = Date()
must(try db.upsert(bulk.map { var m = $0; m.isRead = true; return m }))
let updateTime = Date().timeIntervalSince(t0)
print(String(format: "      обновление 10 000: %.3f s", updateTime))
check(updateTime < 3.0, "upsert 10 000 существующих писем < 3 с")

t0 = Date()
let loadedAll = must(try db.allMessages())
let loadTime = Date().timeIntervalSince(t0)
print(String(format: "      allMessages (%d): %.3f s", loadedAll.count, loadTime))
check(loadTime < 3.0, "allMessages по 10k+ писем < 3 с")

t0 = Date()
let bulkHits = must(try db.search("пакетн invoice", accountID: accountA, limit: 50))
let searchTime = Date().timeIntervalSince(t0)
print(String(format: "      search: %.4f s", searchTime))
checkEqual(bulkHits.count, 50, "поиск по 10k писем с фильтром аккаунта")
check(searchTime < 0.5, "поиск по 10k писем < 0.5 с")
checkEqual(try db.search("номер 4242", accountID: nil, limit: 5).first, "bulk-4242", "точный поиск среди 10k")

// MARK: - Повторное открытие и миграции

section("Повторное открытие")
let countBefore = must(try db.allMessages()).count
let fullBefore = must(try db.message(id: "full-1"))
db = nil   // закрываем
db = must(try MailDatabase(url: dbURL))
checkEqual(try db.allMessages().count, countBefore, "данные на месте после повторного открытия")
checkEqual(try db.message(id: "full-1"), fullBefore, "письмо со всеми полями на месте")
checkEqual(try db.search("расшифров", accountID: nil, limit: 10), ["ru-1"], "FTS на месте")
checkEqual(try db.syncState(accountID: accountA, folder: "INBOX"), st2, "sync_state на месте")
checkEqual(try db.pendingActions(accountID: accountA), [act1b], "pending_actions на месте")
must(try db.upsert([makeMessage(id: "after-reopen", subject: "новое после открытия")]))
checkEqual(try db.search("открытия", accountID: nil, limit: 10), ["after-reopen"], "новые doc не конфликтуют со старыми")
checkEqual(try inspector.queryFirst("SELECT count(*) FROM messages_fts") { $0.int64(0) },
           try inspector.queryFirst("SELECT count(*) FROM messages") { $0.int64(0) }, "FTS и messages согласованы после открытия")

section("Миграции")
let migrationConn = must(try DatabaseConnection(path: dbURL.path))
must(try MailDatabase.migrate(migrationConn))
must(try MailDatabase.migrate(migrationConn))
checkEqual(try migrationConn.pragmaInt("user_version"), MailDatabase.schemaVersion, "повторная миграция не меняет версию")
checkEqual(try db.allMessages().count, countBefore + 1, "повторная миграция не трогает данные")
db = nil
db = must(try MailDatabase(url: dbURL))
checkEqual(try db.allMessages().count, countBefore + 1, "третье открытие — данные на месте")

// Пустая база v0 → v1 в памяти, затем повторно.
let fresh = must(try DatabaseConnection(path: ":memory:"))
checkEqual(try fresh.pragmaInt("user_version"), 0, "новая база — версия 0")
must(try MailDatabase.migrate(fresh))
checkEqual(try fresh.pragmaInt("user_version"), MailDatabase.schemaVersion, "миграция 0 → текущая")
must(try MailDatabase.migrate(fresh))
checkEqual(try fresh.pragmaInt("user_version"), MailDatabase.schemaVersion, "миграция идемпотентна")

// База от будущей версии не открывается.
let futureURL = tmpDir.appendingPathComponent("future.sqlite")
do {
    let c = must(try DatabaseConnection(path: futureURL.path))
    must(try c.execute("PRAGMA user_version = 99"))
    c.close()
}
checkThrows({ _ = try MailDatabase(url: futureURL) }, "база новее поддерживаемой схемы — ошибка")

section("In-memory")
let mem = must(try MailDatabase.inMemory())
must(try mem.upsert([makeFullMessage(id: "m1")]))
checkEqual(try mem.message(id: "m1"), makeFullMessage(id: "m1").withSameAttachmentIDs(as: try mem.message(id: "m1")),
           "inMemory: round-trip")
checkEqual(try mem.search("полное", accountID: nil, limit: 10), ["m1"], "inMemory: FTS")
check(mem.url == nil, "inMemory: url == nil")

// Транзакционность: ошибка внутри пакета откатывает весь пакет.
section("Транзакции")
let txConn = must(try DatabaseConnection(path: ":memory:"))
must(try txConn.execute("CREATE TABLE t (x INTEGER PRIMARY KEY)"))
checkThrows({
    try txConn.transaction {
        try txConn.run("INSERT INTO t VALUES (1)")
        try txConn.run("INSERT INTO t VALUES (1)")   // конфликт PK
    }
}, "ошибка в транзакции пробрасывается")
checkEqual(try txConn.queryFirst("SELECT count(*) FROM t") { $0.int64(0) }, 0, "транзакция откатилась")
must(try txConn.transaction {
    try txConn.run("INSERT INTO t VALUES (1)")
    _ = try? txConn.transaction { try txConn.run("INSERT INTO t VALUES (1)") }   // вложенная — откат только её
    try txConn.run("INSERT INTO t VALUES (2)")
})
checkEqual(try txConn.queryFirst("SELECT count(*) FROM t") { $0.int64(0) }, 2, "вложенная транзакция (SAVEPOINT) откатывается отдельно")

extension Message {
    /// В makeFullMessage у второго вложения случайный UUID — выравниваем для сравнения.
    func withSameAttachmentIDs(as other: Message?) -> Message {
        guard let other, other.attachments.count == attachments.count else { return self }
        var copy = self
        for i in copy.attachments.indices { copy.attachments[i].id = other.attachments[i].id }
        return copy
    }
}

// MARK: - Итог

print("\n\(passed) passed, \(failed) failed")
inspector.close()
db = nil
try? FileManager.default.removeItem(at: tmpDir)
exit(failed == 0 ? 0 : 1)
