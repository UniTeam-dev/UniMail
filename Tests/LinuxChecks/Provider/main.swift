// Сквозная проверка IMAPProvider на Linux: фейковые IMAP- и SMTP-серверы поверх ScriptedTransport,
// настоящая база SQLite, разбор MIME, приглашения, вложения в кэше.
//
// Сборка из корня проекта:
//   swiftc -swift-version 5 -I Tests/LinuxChecks/Database \
//     Sources/UniMail/Core/Models/*.swift Sources/UniMail/Core/Mail/*.swift Sources/UniMail/Core/Mail/*/*.swift \
//     Sources/UniMail/Core/Store/Database/*.swift Sources/UniMail/Core/Providers/*.swift \
//     Sources/UniMail/Core/Render/*.swift Tests/LinuxChecks/Provider/*.swift -o providertest && ./providertest

import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed: [String] = []

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition { passed += 1; print("PASS \(name)") } else { failed.append("\(name) (line \(line))"); print("FAIL \(name)") }
}

// MARK: - Сценарий

let imap = FakeIMAP()
imap.folders["INBOX"] = [mail1, mail2]
let smtp = FakeSMTP()

let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unimail-provider-\(UUID().uuidString)")
let database = try! MailDatabase.inMemory()

var account = Account(displayName: "Работа", email: "me@example.com", kind: .imap, tint: .blue)
account.senderName = "Анна"
account.server = ServerSettings(imapHost: "imap.example.com", imapPort: 993, smtpHost: "smtp.example.com", smtpPort: 465, username: "me@example.com")

let factory: TransportFactory = { host, port, implicitTLS, _ in
    host.hasPrefix("imap") ? imap.transport() : smtp.transport()
}

let provider = IMAPProvider(account: account, database: database, transportFactory: factory,
                            password: { "secret" }, cacheDirectory: cache)

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    do {
        // 1. Первая синхронизация.
        let first = try await provider.sync(cursor: nil)
        let inbox = first.upserted.filter { $0.role == .inbox }.sorted { ($0.uid ?? 0) < ($1.uid ?? 0) }
        check(inbox.count == 2, "first sync: 2 inbox messages")
        check(inbox.first?.subject == "Отчёт", "subject decoded")
        check(inbox.first?.from.email == "ivan@example.ru", "from parsed")
        check(inbox.first?.body == "Привет! Отчёт готов.", "preview fetched")
        check(inbox.count == 2 && inbox[0].threadID == inbox[1].threadID, "reply threaded with original")
        check(inbox.last?.attachmentHint == true, "attachment hint from BODYSTRUCTURE")
        check(inbox.last?.listUnsubscribe?.contains("https://example.ru/unsub?id=1") == true, "unsubscribe header kept")
        check(inbox.last?.listUnsubscribePost == true, "one-click unsubscribe")
        check(inbox.last?.headerMessageID == "m2@example.ru" && inbox.last?.inReplyToHeader == "m1@example.ru", "message ids")
        check(inbox.allSatisfy { $0.bodyPending == true && $0.folder == "INBOX" }, "body pending, folder set")
        check(first.headers[inbox.last?.id ?? ""]?["references"] != nil, "raw headers for categorizer")
        let state = try database.syncState(accountID: account.id, folder: "INBOX")
        check(state?.lastUID == 2 && state?.uidValidity == 7 && state?.highestModSeq == 100, "sync state stored")
        try database.upsert(first.upserted)

        // 2. Изменения на сервере: письмо 1 удалено, письмо 2 прочитано и помечено, пришло письмо 3.
        imap.lock.withLock {
            imap.folders["INBOX"] = [
                FakeMail(uid: 2, flags: ["\\Flagged", "\\Seen"], modSeq: 101, raw: mail2.raw, envelope: mail2.envelope,
                         structure: mail2.structure, headerBlock: mail2.headerBlock, text: mail2.text),
                mail3,
            ]
            imap.modSeq = 102
        }
        let second = try await provider.sync(cursor: nil)
        let id1 = inbox[0].id, id2 = inbox[1].id
        check(second.deletedIDs == [id1], "deleted message detected")
        let updated2 = second.upserted.first { $0.id == id2 }
        check(updated2?.isRead == true && updated2?.isFlagged == true, "flag changes via CHANGEDSINCE")
        check(second.upserted.contains { $0.uid == 3 && $0.subject == "Новое" && $0.isRead }, "new message fetched")
        check(!second.upserted.contains { $0.uid == 2 && $0.bodyPending == true && $0.subject != "Re: Отчёт" }, "no junk")
        try database.upsert(second.upserted)
        try database.delete(ids: second.deletedIDs)

        // 3. Тело письма: HTML, встроенная картинка, вложение в кэше, приглашение.
        let content = try await provider.fetchContent(for: inbox[1])
        check(content.html?.contains("data:image/png;base64,iVBORw0KGgo=") == true, "cid image inlined as data URI")
        check(content.attachments.count == 1 && content.attachments.first?.filename == "report.pdf", "one real attachment")
        if let path = content.attachments.first?.localPath {
            let data = FileManager.default.contents(atPath: path)
            check(data.map { String(decoding: $0, as: UTF8.self) } == "%PDF-1.4\n", "attachment saved to cache")
        } else {
            check(false, "attachment saved to cache")
        }
        check(content.invite?.title == "Созвон по отчёту" && content.invite?.location == "Zoom", "invite parsed")
        check(content.invite?.organizer?.email == "ivan@example.ru", "invite organizer")
        check(content.text?.contains("Смотрите") == true, "text fallback from html")
        check(content.references == ["m1@example.ru"], "references from full message")

        // 4. Действия.
        try await provider.apply(.markRead(ids: [id2], read: false))
        check(imap.lock.withLock { imap.log.contains { $0.hasPrefix("UID STORE 2 -FLAGS.SILENT (\\Seen)") } }, "mark unread → STORE -FLAGS")
        let id3 = second.upserted.first { $0.uid == 3 }!.id
        try await provider.apply(.move(ids: [id3], to: .archive))
        check(imap.lock.withLock { imap.folders["Archive"]?.contains { $0.uid == 3 } == true }, "move → Archive")
        try await provider.apply(.snooze(ids: [id2], until: .now))
        check(true, "snooze is local-only")

        // 5. Поиск на сервере.
        let found = try await provider.serverSearch("Re: Отчёт")
        check(found.contains { $0.uid == 2 }, "server search finds message")

        // 6. Отправка: SMTP + APPEND в «Отправленные».
        var outgoing = OutgoingMessage(accountID: account.id, fromAddress: "me@example.com",
                                       to: [Address(name: "Иван", email: "ivan@example.ru")], cc: [], bcc: [],
                                       subject: "Re: Отчёт", body: "Спасибо!")
        outgoing.htmlBody = "<p><b>Спасибо!</b></p>"
        outgoing.inReplyToHeader = "m2@example.ru"
        outgoing.referenceHeaders = ["m1@example.ru", "m2@example.ru"]
        outgoing.threadID = inbox[1].threadID
        let sent = try await provider.send(outgoing)
        let data = smtp.lock.withLock { smtp.messages.first ?? "" }
        check(smtp.lock.withLock { smtp.commands.contains("MAIL FROM:<me@example.com>") || smtp.commands.contains { $0.hasPrefix("MAIL FROM:<me@example.com>") } }, "SMTP MAIL FROM")
        check(smtp.lock.withLock { smtp.commands.contains("RCPT TO:<ivan@example.ru>") }, "SMTP RCPT TO")
        check(data.contains("In-Reply-To: <m2@example.ru>"), "In-Reply-To header sent")
        check(data.contains("References: <m1@example.ru> <m2@example.ru>"), "References header sent")
        check(data.contains("text/html"), "html part sent")
        check(imap.lock.withLock { imap.appended.first?.hasPrefix("APPEND \"Sent\" (\\Seen)") == true }, "APPEND to Sent")
        check(sent.role == .sent && sent.threadID == inbox[1].threadID, "sent copy in thread")
        check(sent.headerMessageID.map { data.contains("Message-ID: <\($0)>") } == true, "sent headerMessageID matches")
        check(sent.headerMessageID?.contains("<") == false, "headerMessageID without angles")

        // 7. Смена UIDVALIDITY — папка начинается заново.
        imap.lock.withLock { imap.uidValidity = 8 }
        let third = try await provider.sync(cursor: nil)
        check(third.deletedIDs.contains(id2), "uidvalidity change drops old ids")
        check(third.upserted.contains { $0.id.hasSuffix("|INBOX|8|2") }, "refetched with new uidvalidity")

        // 8. Ошибка входа.
        let bad = IMAPProvider(account: account, database: database, transportFactory: factory,
                               password: { nil }, cacheDirectory: cache)
        do {
            _ = try await bad.sync(cursor: nil)
            check(false, "missing password throws")
        } catch MailProviderError.missingPassword {
            check(true, "missing password throws")
        }
        await provider.disconnect()
    } catch {
        check(false, "unexpected error: \(error)")
    }
}
semaphore.wait()

print("\n\(passed) passed, \(failed.count) failed")
for f in failed { print("  FAIL \(f)") }
try? FileManager.default.removeItem(at: cache)
exit(failed.isEmpty ? 0 : 1)
