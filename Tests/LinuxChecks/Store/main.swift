// Проверка MailStore поверх фейкового IMAP/SMTP: синхронизация, база, ленивые тела, действия с «Отменить»,
// журнал офлайн-действий, отправка и «нет ответа», запланированные письма, поиск.
//
// Сборка из корня проекта (HOME подменяется, чтобы база и настройки легли во временную папку):
//   swiftc -swift-version 5 -I Tests/LinuxChecks/Database \
//     Sources/UniMail/Core/Models/*.swift Sources/UniMail/Core/Mail/*.swift Sources/UniMail/Core/Mail/*/*.swift \
//     Sources/UniMail/Core/Store/Database/*.swift Sources/UniMail/Core/Providers/*.swift Sources/UniMail/Core/Render/*.swift \
//     Sources/UniMail/Core/Automation/*.swift Sources/UniMail/Core/Store/*.swift \
//     Tests/LinuxChecks/Provider/FakeServers.swift Tests/LinuxChecks/Store/*.swift -o storetest
//   HOME=$(mktemp -d) ./storetest

import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed: [String] = []

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition { passed += 1; print("PASS \(name)") } else { failed.append("\(name) (line \(line))"); print("FAIL \(name)") }
}

@MainActor
func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

let imap = FakeIMAP()
imap.folders["INBOX"] = [mail1, mail2]
let smtp = FakeSMTP()
let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unimail-store-\(UUID().uuidString)")
let factory: TransportFactory = { host, _, _, _ in
    if imap.lock.withLock({ imap.offline }) { throw MailTransportError.connect("offline") }
    return host.hasPrefix("imap") ? imap.transport() : smtp.transport()
}

UserDefaults.standard.set(1.0, forKey: "undoSeconds")

let store = MailStore()
check(store.accounts.count == 3 && store.accounts.allSatisfy { $0.kind == .demo }, "demo accounts on first run")

var account = Account(displayName: "Работа", email: "me@example.com", kind: .imap, tint: .green)
account.server = ServerSettings(imapHost: "imap.example.com", imapPort: 993, smtpHost: "smtp.example.com",
                                smtpPort: 465, username: "me@example.com")
let accountID = account.id
store.addAccount(account, secret: "secret")
let database = ProviderFactory.database!
store.installProvider(IMAPProvider(account: account, database: database, transportFactory: factory,
                                   password: { "secret" }, cacheDirectory: cache), for: accountID)

// 1. Первая синхронизация.
check(await waitUntil { store.messages.values.filter { $0.accountID == accountID }.count == 2 }, "synced 2 messages")
await store.refresh(accountID: accountID)
let inbox = store.threads(in: .account(accountID, .inbox))
check(inbox.count == 1 && inbox.first?.count == 2, "one thread of two messages in inbox")
check(store.accountErrors[accountID] == nil, "no account error")
let threadID = inbox.first?.id ?? ""

// 2. Хранение.
store.flushPersistence(wait: true)
let stored = try database.allMessages().filter { $0.accountID == accountID }
check(stored.count == 2, "messages persisted")

// 3. Ленивая загрузка тел при открытии треда.
store.select(scope: .account(accountID, .inbox))
store.selectedThreadID = threadID
store.openThread(threadID)
check(await waitUntil { store.thread(threadID).allSatisfy { $0.bodyPending == false } }, "bodies loaded")
let reply = store.thread(threadID).first { $0.uid == 2 }
check(reply?.invite?.title == "Созвон по отчёту", "invite available after body load")
check(reply?.htmlBody?.contains("data:image/png") == true, "html with inline image")
check(reply?.attachments.first?.filename == "report.pdf", "attachment metadata")
check(store.thread(threadID).allSatisfy(\.isRead), "thread marked read")
check(await waitUntil { imap.lock.withLock { imap.log.contains { $0.contains("+FLAGS.SILENT (\\Seen)") } } }, "read flag pushed to server")
store.flushPersistence(wait: true)
check((try database.body(for: reply?.id ?? ""))?.html?.contains("Смотрите") == true, "body stored in database")
check(try database.message(id: reply?.id ?? "")?.htmlBody == nil, "database row keeps only preview")

// 4. Поиск по индексу.
store.searchText = "вложение"
check(await waitUntil { !store.indexHits.isEmpty }, "full-text index hit")
check(store.canSearchServer, "server search available for IMAP account")
store.searchOnServer()
check(await waitUntil { if case .done = store.serverSearchState { return true } else { return false } }, "server search done")
store.searchText = ""

// 5. Архив с «Отменить» → сервер → синхронизация.
store.archive(threadIDs: [threadID])
check(store.threads(in: .account(accountID, .inbox)).isEmpty, "archived optimistically")
store.dismissUndo()
check(await waitUntil { imap.lock.withLock { imap.folders["Archive"]?.count == 2 } }, "moved on server")
await store.refresh(accountID: accountID)
let archived = store.messages.values.filter { $0.accountID == accountID && $0.role == .archive }
check(archived.count == 2 && archived.allSatisfy { $0.folder == "Archive" }, "archive copies synced, inbox copies removed")
check(!store.messages.values.contains { $0.accountID == accountID && $0.folder == "INBOX" }, "no stale inbox ids")

// 5a. Свои папки: список с сервера, письма по открытию, «Отметить все как прочитанные», перенос в папку.
imap.lock.withLock {
    imap.folders["Projects"] = [FakeMail(uid: 1, flags: [], modSeq: 103, raw: mail3.raw, envelope: mail3.envelope,
                                         structure: mail3.structure, headerBlock: mail3.headerBlock, text: mail3.text)]
    imap.folders["Projects/Q4"] = []
}
await store.refresh(accountID: accountID)
let customFolders = store.folders(of: accountID)
check(customFolders.map(\.id) == ["Projects", "Projects/Q4"], "custom folders listed: \(customFolders.map(\.id))")
check(customFolders.last?.name == "Q4" && customFolders.last?.depth == 1 && customFolders.last?.parentID == "Projects", "nested folder")
let projectsScope = MailScope.folder(accountID, "Projects")
store.select(scope: projectsScope)
check(store.scopeTitle == "Projects", "list title is folder name")
check(await waitUntil { store.threads(in: projectsScope).count == 1 }, "folder messages loaded on open")
check(store.unreadCount(projectsScope) == 1, "folder unread count")
store.markAllRead()
check(store.unreadCount(projectsScope) == 0, "all marked read optimistically")
store.undoLast()
check(store.unreadCount(projectsScope) == 1, "mark all read undone")
store.markAllRead()
store.dismissUndo()
check(await waitUntil { imap.lock.withLock { imap.folders["Projects"]?.first?.flags.contains("\\Seen") == true } }, "read on server")
if let projectThread = store.threads(in: projectsScope).first?.id, let q4 = customFolders.last {
    store.move(threadIDs: [projectThread], toFolder: q4, accountID: accountID)
    check(store.threads(in: projectsScope).isEmpty, "moved out of folder optimistically")
    store.dismissUndo()
    check(await waitUntil { imap.lock.withLock { imap.folders["Projects/Q4"]?.count == 1 } }, "moved to folder on server")
    await store.refreshFolder(accountID: accountID, key: "Projects/Q4")
    check(store.threads(in: .folder(accountID, "Projects/Q4")).count == 1, "message in target folder")
}
store.select(scope: .account(accountID, .inbox))

// 6. Ответ с напоминанием «если не ответят».
let source = archived.first { $0.headerMessageID == "m2@example.ru" }!
var draft = OutgoingMessage(accountID: accountID, fromAddress: "me@example.com",
                            to: [Address(name: "Иван", email: "ivan@example.ru")], cc: [], bcc: [],
                            subject: "Re: Отчёт", body: "Спасибо!")
draft.threadID = source.threadID
draft.inReplyTo = source.id
draft.remindIfNoReply = true
store.send(draft, requestID: UUID())
store.dismissUndo()
check(await waitUntil { store.messages.values.contains { $0.id.contains("|local-sent|") } }, "local sent copy")
let sentData = smtp.lock.withLock { smtp.messages.last ?? "" }
check(sentData.contains("In-Reply-To: <m2@example.ru>"), "reply threaded by header")
check(sentData.contains("References: <m1@example.ru> <m2@example.ru>"), "references chain")
await store.refresh(accountID: accountID)
let sentCopies = store.messages.values.filter { $0.accountID == accountID && $0.role == .sent }
check(sentCopies.count == 1 && sentCopies.first?.folder == "Sent", "local sent replaced by server copy")
check(sentCopies.first?.followUpAt != nil, "follow-up carried to server copy")
check(sentCopies.first?.threadID == source.threadID, "server sent copy in same thread")

// 7. Нет ответа → тред во «Входящих».
if let sent = sentCopies.first {
    store.remindIfNoReply(messageID: sent.id, at: Date.distantPast.addingTimeInterval(1))
    // Письмо из треда старше ответа — ответом не считается.
    store.checkFollowUps()
    check(store.isAwaitingReply(threadID: sent.threadID), "no-reply notice set")
    check(store.threads(in: .account(accountID, .inbox)).contains { $0.id == sent.threadID }, "reminder visible in inbox")
    store.archive(threadIDs: [sent.threadID])
    check(store.messages[sent.id]?.role == .sent && store.messages[sent.id]?.noReplyNotice == nil, "archiving reminder only clears it")
    store.dismissUndo()
}

// 8. Без связи — действие в журнал, потом повтор.
imap.lock.withLock { imap.offline = true }
store.select(scope: .account(accountID, .archive))
let archivedThread = store.threads(in: .account(accountID, .archive)).first!.id
store.toggleFlag(threadIDs: [archivedThread])
check(await waitUntil(8) { ((try? database.pendingActions(accountID: accountID)) ?? []).count == 1 }, "offline action journaled")
imap.lock.withLock { imap.offline = false }
await store.refresh(accountID: accountID)
check(((try? database.pendingActions(accountID: accountID)) ?? []).isEmpty, "journal replayed")
check(imap.lock.withLock { imap.folders["Archive"]?.allSatisfy { $0.flags.contains("\\Flagged") } == true }, "flag applied after reconnect")

// 9. Запланированное письмо переживает перезапуск и уходит по команде.
var later = draft
later.remindIfNoReply = false
later.sendAt = Date().addingTimeInterval(3600)
let scheduledRequest = UUID()
store.send(later, requestID: scheduledRequest)
store.dismissUndo()
let scheduledID = "scheduled-\(scheduledRequest.uuidString)"
check(store.messages[scheduledID]?.role == .scheduled, "scheduled message listed")
check(ScheduledDraftsFile.load()[scheduledID] != nil, "scheduled draft saved to file")
let smtpBefore = smtp.lock.withLock { smtp.messages.count }
store.sendScheduledNow(messageID: scheduledID)
check(await waitUntil { smtp.lock.withLock { smtp.messages.count } == smtpBefore + 1 }, "scheduled sent now")
check(ScheduledDraftsFile.load()[scheduledID] == nil, "scheduled file cleared")

// 9a. Подписи: полная — в новые письма, короткая — в ответы.
if let index = store.accounts.firstIndex(where: { $0.id == accountID }) {
    let full = MailSignature(name: "Полная", text: "Анна Волкова\nСеверлаб")
    let short = MailSignature(name: "Короткая", text: "А.")
    store.accounts[index].signatures = [full, short]
    store.accounts[index].newMailSignatureID = full.id
    store.accounts[index].replySignatureID = short.id
    store.select(scope: .account(accountID, .inbox))
    store.compose(.new)
    check(store.composeQueue.last?.draft.body == "\n\n--\nАнна Волкова\nСеверлаб", "new mail gets full signature")
    store.compose(.reply, from: source.id)
    let replyBody = store.composeQueue.last?.draft.body ?? ""
    check(replyBody.hasPrefix("\n\n--\nА.\n") && replyBody.contains("> "), "reply gets short signature above quote")
    store.accounts[index].replySignatureID = nil
    store.compose(.forward, from: source.id)
    check(store.composeQueue.last?.draft.body.hasPrefix("\n\n--\n") == false, "no signature when disabled for replies")
    var legacy = Account(displayName: "Старый", email: "old@example.com", kind: .imap, tint: .red, signature: "Иван")
    legacy.migrateSignatures()
    check(legacy.signatureText(for: .newMail) == "Иван" && legacy.signatureText(for: .reply) == "Иван", "legacy signature migrated")
}

// 10. Черновик с HTML сохраняется и открывается тем же окном.
var htmlDraft = draft
htmlDraft.htmlBody = "<p><b>Жирный</b> текст</p>"
let draftRequest = UUID()
store.saveDraft(htmlDraft, requestID: draftRequest)
store.compose(.draft, from: "draft-\(draftRequest.uuidString)")
check(store.composeQueue.last?.id == draftRequest, "draft reopened with same request id")
check(store.composeQueue.last?.draft.htmlBody == htmlDraft.htmlBody, "draft keeps formatting")

// 10a. Приглашение из письма — встреча в «Расписании»; ответ уходит письмом с iCalendar REPLY.
let inviteDay = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
if let archivedInvite = store.messages.values.first(where: { $0.accountID == accountID && $0.headerMessageID == "m2@example.ru" }) {
    store.loadBodies(threadID: archivedInvite.threadID)
    _ = await waitUntil { store.messages[archivedInvite.id]?.invite != nil }
}
let inviteEvents = store.mailCalendarEvents(from: inviteDay, to: inviteDay.addingTimeInterval(86400), accountFilter: accountID)
check(inviteEvents.count == 1 && inviteEvents.first?.source == .mail && inviteEvents.first?.needsResponse == true, "invite shown as meeting")
check(inviteEvents.first?.organizer?.email == "ivan@example.ru" && inviteEvents.first?.location == "Zoom", "invite organizer and place")
check(store.calendarAccountIDs.isEmpty, "IMAP account has no server calendar")
if let inviteEvent = inviteEvents.first {
    let sentBefore = smtp.lock.withLock { smtp.messages.count }
    check(await store.respond(to: inviteEvent, .accepted), "invite accepted")
    check(store.messages[inviteEvent.remoteID]?.invite?.response == "ACCEPTED", "response stored on message")
    check(await waitUntil { smtp.lock.withLock { smtp.messages.count } > sentBefore }, "REPLY sent by mail")
    check(smtp.lock.withLock { smtp.messages.last?.lowercased().contains("method=reply") == true }, "iCalendar REPLY with ACCEPTED")
    check(store.mailCalendarEvents(from: inviteDay, to: inviteDay.addingTimeInterval(86400), accountFilter: accountID).first?.myResponse == .accepted, "meeting shows accepted")
}

// 11. Перезапуск: письма из базы.
store.flushPersistence(wait: true)
let reopened = MailStore()
check(reopened.messages.values.filter { $0.accountID == accountID }.count >= 3, "messages restored from database on launch")

// 12. Удаление ящика.
store.removeAccount(accountID)
store.flushPersistence(wait: true)
_ = await waitUntil { ((try? database.allMessages()) ?? []).allSatisfy { $0.accountID != accountID } }
check(((try? database.allMessages()) ?? []).allSatisfy { $0.accountID != accountID }, "account data removed from database")

print("\n\(passed) passed, \(failed.count) failed")
for f in failed { print("  FAIL \(f)") }
try? FileManager.default.removeItem(at: cache)
exit(failed.isEmpty ? 0 : 1)
