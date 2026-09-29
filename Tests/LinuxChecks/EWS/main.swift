// Проверка EWSProvider на Linux: фейковый сервер Exchange (SOAP), настоящая база SQLite.
//
// Сборка из корня проекта:
//   swiftc -swift-version 5 -I Tests/LinuxChecks/Database \
//     Sources/UniMail/Core/Models/*.swift Sources/UniMail/Core/Mail/*.swift Sources/UniMail/Core/Mail/*/*.swift \
//     Sources/UniMail/Core/Store/Database/*.swift Sources/UniMail/Core/Providers/*.swift Sources/UniMail/Core/Render/*.swift \
//     Tests/LinuxChecks/EWS/main.swift -o ewstest && ./ewstest

import Foundation

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed: [String] = []

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition { passed += 1; print("PASS \(name)") } else { failed.append("\(name) (line \(line))"); print("FAIL \(name)") }
}

// MARK: - Фейковый Exchange

struct FakeItem {
    var id: String
    var subject: String
    var received: String
    var fromName: String
    var fromEmail: String
    var routing: String
    var isRead: Bool
    var flagged = false
    var conversation: String
    var headers: [(String, String)] = []
    var mime: String
}

final class FakeExchange: @unchecked Sendable {
    let lock = NSLock()
    var folders: [String: [FakeItem]] = ["inbox": [], "sentitems": [], "drafts": [], "junkemail": [], "deleteditems": [], "ARCH": []]
    var requests: [String] = []
    var password = "secret"
    var sent: [String] = []
    var calendarRequests: [String] = []

    let ns = "xmlns:m=\"http://schemas.microsoft.com/exchange/services/2006/messages\" xmlns:t=\"http://schemas.microsoft.com/exchange/services/2006/types\""

    func envelope(_ body: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Header/><s:Body>\(body)</s:Body></s:Envelope>".utf8)
    }

    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    func folder(of request: String) -> String {
        if let r = request.range(of: "<m:ParentFolderIds>") ?? request.range(of: "<m:ToFolderId>") {
            let tail = request[r.upperBound...]
            if let idRange = tail.range(of: "Id=\"") {
                let rest = tail[idRange.upperBound...]
                return String(rest.prefix { $0 != "\"" })
            }
        }
        return "inbox"
    }

    func itemIDs(_ request: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(request)
        while let r = rest.range(of: "<t:ItemId Id=\"") {
            let tail = rest[r.upperBound...]
            ids.append(String(tail.prefix { $0 != "\"" }))
            rest = tail
        }
        return ids
    }

    func itemXML(_ item: FakeItem, detail: Bool) -> String {
        var x = "<t:Message><t:ItemId Id=\"\(item.id)\" ChangeKey=\"CK\"/><t:ItemClass>IPM.Note</t:ItemClass>"
        x += "<t:Subject>\(esc(item.subject))</t:Subject><t:DateTimeReceived>\(item.received)</t:DateTimeReceived>"
        x += "<t:HasAttachments>\(item.mime.contains("attachment"))</t:HasAttachments>"
        x += "<t:From><t:Mailbox><t:Name>\(esc(item.fromName))</t:Name><t:EmailAddress>\(esc(item.fromEmail))</t:EmailAddress><t:RoutingType>\(item.routing)</t:RoutingType></t:Mailbox></t:From>"
        x += "<t:IsRead>\(item.isRead)</t:IsRead><t:Flag><t:FlagStatus>\(item.flagged ? "Flagged" : "NotFlagged")</t:FlagStatus></t:Flag>"
        x += "<t:ConversationId Id=\"\(item.conversation)\"/>"
        if detail {
            x += "<t:ToRecipients><t:Mailbox><t:Name>Илья</t:Name><t:EmailAddress>/O=EXAMPLE/CN=ILYA</t:EmailAddress><t:RoutingType>EX</t:RoutingType></t:Mailbox></t:ToRecipients>"
            x += "<t:InternetMessageId>&lt;\(item.id.lowercased())@example.com&gt;</t:InternetMessageId>"
            x += "<t:Preview>Превью \(esc(item.subject))</t:Preview>"
            if !item.headers.isEmpty {
                x += "<t:InternetMessageHeaders>" + item.headers.map {
                    "<t:InternetMessageHeader HeaderName=\"\($0.0)\">\(esc($0.1))</t:InternetMessageHeader>"
                }.joined() + "</t:InternetMessageHeaders>"
            }
        }
        return x + "</t:Message>"
    }

    func success(_ op: String, _ inner: String = "") -> String {
        "<m:\(op)Response \(ns)><m:ResponseMessages><m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage></m:ResponseMessages></m:\(op)Response>"
    }

    func respond(_ data: Data) -> (Int, Data) {
        let request = String(decoding: data, as: UTF8.self)
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        if password != "secret" { return (401, Data()) }

        if request.contains("<m:GetFolder") && request.components(separatedBy: "DistinguishedFolderId").count > 2 {
            // Несколько стандартных папок сразу: id вида D-<имя>.
            var names: [String] = []
            var rest = Substring(request)
            while let r = rest.range(of: "<t:DistinguishedFolderId Id=\"") {
                let tail = rest[r.upperBound...]
                names.append(String(tail.prefix { $0 != "\"" }))
                rest = tail
            }
            let messages = names.map { name in
                name == "conversationhistory"
                    ? "<m:GetFolderResponseMessage ResponseClass=\"Error\"><m:ResponseCode>ErrorFolderNotFound</m:ResponseCode></m:GetFolderResponseMessage>"
                    : "<m:GetFolderResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode><m:Folders><t:Folder><t:FolderId Id=\"D-\(name)\"/></t:Folder></m:Folders></m:GetFolderResponseMessage>"
            }.joined()
            return (200, envelope("<m:GetFolderResponse \(ns)><m:ResponseMessages>\(messages)</m:ResponseMessages></m:GetFolderResponse>"))
        }
        if request.contains("<m:FindFolder Traversal=\"Deep\"") {
            func f(_ id: String, _ name: String, _ parent: String, _ cls: String = "IPF.Note", tag: String = "Folder", unread: Int = 0) -> String {
                "<t:\(tag)><t:FolderId Id=\"\(id)\"/><t:ParentFolderId Id=\"\(parent)\"/><t:FolderClass>\(cls)</t:FolderClass><t:DisplayName>\(name)</t:DisplayName><t:TotalCount>5</t:TotalCount><t:UnreadCount>\(unread)</t:UnreadCount></t:\(tag)>"
            }
            let tree = [
                f("D-inbox", "Входящие", "D-msgfolderroot", unread: 3),
                f("PROJ", "Проекты", "D-inbox", unread: 2),
                f("PROJ-B", "Бета", "PROJ"),
                f("PROJ-A", "Альфа", "PROJ"),
                f("ARCH", "Архив", "D-msgfolderroot"),
                f("D-deleteditems", "Удалённые", "D-msgfolderroot"),
                f("TRASHSUB", "Старое", "D-deleteditems"),
                f("CAL", "Календарь", "D-msgfolderroot", "IPF.Appointment", tag: "CalendarFolder"),
                f("RSS", "RSS-каналы", "D-msgfolderroot", "IPF.Note.OutlookHomepage"),
                f("CLIENTS", "Клиенты", "D-msgfolderroot"),
            ].joined()
            return (200, envelope(success("FindFolder", "<m:RootFolder TotalItemsInView=\"10\" IncludesLastItemInRange=\"true\"><t:Folders>\(tree)</t:Folders></m:RootFolder>")))
        }
        if request.contains("<m:GetInboxRules") {
            let rule = "<t:Rule><t:RuleId>R1</t:RuleId><t:DisplayName>Jira в Проекты</t:DisplayName><t:Priority>1</t:Priority><t:IsEnabled>true</t:IsEnabled>"
                + "<t:Conditions><t:FromAddresses><t:Address><t:EmailAddress>jira@example.com</t:EmailAddress></t:Address></t:FromAddresses>"
                + "<t:ContainsSubjectStrings><t:String>PI</t:String></t:ContainsSubjectStrings></t:Conditions>"
                + "<t:Actions><t:MoveToFolder><t:FolderId Id=\"PROJ\"/></t:MoveToFolder><t:MarkAsRead>true</t:MarkAsRead></t:Actions></t:Rule>"
            let off = "<t:Rule><t:RuleId>R2</t:RuleId><t:DisplayName>Старое</t:DisplayName><t:Priority>2</t:Priority><t:IsEnabled>false</t:IsEnabled><t:Actions><t:Delete>true</t:Delete></t:Actions></t:Rule>"
            return (200, envelope("<m:GetInboxRulesResponse \(ns) ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode><m:OutlookRuleBlobExists>true</m:OutlookRuleBlobExists><m:InboxRules>\(off)\(rule)</m:InboxRules></m:GetInboxRulesResponse>"))
        }
        if request.contains("<m:GetFolder") {
            return (200, envelope(success("GetFolder", "<m:Folders><t:Folder><t:FolderId Id=\"INBOXID\"/><t:DisplayName>Входящие</t:DisplayName></t:Folder></m:Folders>")))
        }
        if request.contains("<m:FindFolder") {
            return (200, envelope(success("FindFolder", "<m:RootFolder TotalItemsInView=\"2\" IncludesLastItemInRange=\"true\"><t:Folders><t:Folder><t:FolderId Id=\"INBOXID\"/><t:DisplayName>Входящие</t:DisplayName></t:Folder><t:Folder><t:FolderId Id=\"ARCH\"/><t:DisplayName>Архив</t:DisplayName></t:Folder></t:Folders></m:RootFolder>")))
        }
        if request.contains("<m:CalendarView") {
            let items = """
            <t:CalendarItem><t:ItemId Id="CAL1" ChangeKey="K1"/><t:Subject>PI Planning 4Q</t:Subject>\
            <t:Start>2026-10-01T07:00:00Z</t:Start><t:End>2026-10-01T09:00:00Z</t:End><t:IsAllDayEvent>false</t:IsAllDayEvent>\
            <t:Location>Teams</t:Location><t:Organizer><t:Mailbox><t:Name>Гаврилов</t:Name><t:EmailAddress>gaz@example.com</t:EmailAddress><t:RoutingType>SMTP</t:RoutingType></t:Mailbox></t:Organizer>\
            <t:MyResponseType>NoResponseReceived</t:MyResponseType><t:IsMeeting>true</t:IsMeeting><t:IsCancelled>false</t:IsCancelled><t:IsRecurring>false</t:IsRecurring></t:CalendarItem>\
            <t:CalendarItem><t:ItemId Id="CAL2" ChangeKey="K2"/><t:Subject>Фокус-время</t:Subject>\
            <t:Start>2026-10-02T06:00:00Z</t:Start><t:End>2026-10-02T08:00:00Z</t:End><t:IsAllDayEvent>false</t:IsAllDayEvent>\
            <t:MyResponseType>Organizer</t:MyResponseType><t:IsMeeting>false</t:IsMeeting></t:CalendarItem>
            """
            return (200, envelope(success("FindItem", "<m:RootFolder TotalItemsInView=\"2\" IncludesLastItemInRange=\"true\"><t:Items>\(items)</t:Items></m:RootFolder>")))
        }
        if request.contains("<m:GetItem") && request.contains("calendar:RequiredAttendees") {
            let item = """
            <t:CalendarItem><t:ItemId Id="CAL1" ChangeKey="K1"/><t:Subject>PI Planning 4Q</t:Subject>\
            <t:Body BodyType="Text">Повестка: планы на квартал. Ссылка: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x</t:Body>\
            <t:Start>2026-10-01T07:00:00Z</t:Start><t:End>2026-10-01T09:00:00Z</t:End><t:IsMeeting>true</t:IsMeeting>\
            <t:Organizer><t:Mailbox><t:Name>Гаврилов</t:Name><t:EmailAddress>gaz@example.com</t:EmailAddress></t:Mailbox></t:Organizer>\
            <t:MyResponseType>NoResponseReceived</t:MyResponseType>\
            <t:RequiredAttendees><t:Attendee><t:Mailbox><t:Name>Иван</t:Name><t:EmailAddress>ivan.petrov@example.com</t:EmailAddress></t:Mailbox><t:ResponseType>Accept</t:ResponseType></t:Attendee>\
            <t:Attendee><t:Mailbox><t:Name>Илья</t:Name><t:EmailAddress>/O=EXAMPLE/CN=ILYA</t:EmailAddress><t:RoutingType>EX</t:RoutingType></t:Mailbox><t:ResponseType>NoResponseReceived</t:ResponseType></t:Attendee></t:RequiredAttendees>\
            <t:OptionalAttendees><t:Attendee><t:Mailbox><t:Name>Ольга</t:Name><t:EmailAddress>olga@example.com</t:EmailAddress></t:Mailbox><t:ResponseType>Decline</t:ResponseType></t:Attendee></t:OptionalAttendees>\
            </t:CalendarItem>
            """
            return (200, envelope(success("GetItem", "<m:Items>\(item)</m:Items>")))
        }
        if request.contains("<t:CalendarItem>") || request.contains("AcceptItem>") || request.contains("DeclineItem>")
            || request.contains("calendar:Start") || request.contains("SendMeetingCancellations") {
            calendarRequests.append(request)
            if request.contains("<m:CreateItem") && request.contains("<t:CalendarItem>") {
                return (200, envelope(success("CreateItem", "<m:Items><t:CalendarItem><t:ItemId Id=\"NEWCAL\" ChangeKey=\"N\"/></t:CalendarItem></m:Items>")))
            }
            let op = request.contains("<m:UpdateItem") ? "UpdateItem" : request.contains("<m:DeleteItem") ? "DeleteItem" : "CreateItem"
            return (200, envelope(success(op)))
        }
        if request.contains("<m:FindItem") {
            let key = folder(of: request)
            var items = folders[key] ?? []
            if let q = request.range(of: "<m:QueryString>") {
                let text = request[q.upperBound...].prefix { $0 != "<" }.lowercased()
                items = items.filter { $0.subject.lowercased().contains(text) }
            }
            let xml = items.map { itemXML($0, detail: false) }.joined()
            return (200, envelope(success("FindItem", "<m:RootFolder TotalItemsInView=\"\(items.count)\" IncludesLastItemInRange=\"true\"><t:Items>\(xml)</t:Items></m:RootFolder>")))
        }
        if request.contains("<m:GetItem") {
            let ids = itemIDs(request)
            let all = folders.values.flatMap { $0 }
            if request.contains("<t:IncludeMimeContent>true") {
                guard let item = all.first(where: { $0.id == ids.first }) else {
                    return (200, envelope("<m:GetItemResponse \(ns)><m:ResponseMessages><m:GetItemResponseMessage ResponseClass=\"Error\"><m:MessageText>Нет письма</m:MessageText><m:ResponseCode>ErrorItemNotFound</m:ResponseCode></m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse>"))
                }
                let b64 = Data(item.mime.utf8).base64EncodedString()
                return (200, envelope(success("GetItem", "<m:Items><t:Message><t:MimeContent CharacterSet=\"UTF-8\">\(b64)</t:MimeContent><t:ItemId Id=\"\(item.id)\"/></t:Message></m:Items>")))
            }
            let messages = ids.map { id -> String in
                guard let item = all.first(where: { $0.id == id }) else {
                    return "<m:GetItemResponseMessage ResponseClass=\"Error\"><m:ResponseCode>ErrorItemNotFound</m:ResponseCode></m:GetItemResponseMessage>"
                }
                return "<m:GetItemResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode><m:Items>\(itemXML(item, detail: true))</m:Items></m:GetItemResponseMessage>"
            }.joined()
            return (200, envelope("<m:GetItemResponse \(ns)><m:ResponseMessages>\(messages)</m:ResponseMessages></m:GetItemResponse>"))
        }
        if request.contains("<m:ResolveNames") {
            let email = request.contains("CN=IVAN") ? "ivan.petrov@example.com" : "ilya@example.com"
            return (200, envelope(success("ResolveNames", "<m:ResolutionSet TotalItemsInView=\"1\"><t:Resolution><t:Mailbox><t:Name>Кто-то</t:Name><t:EmailAddress>\(email)</t:EmailAddress><t:RoutingType>SMTP</t:RoutingType></t:Mailbox></t:Resolution></m:ResolutionSet>")))
        }
        if request.contains("<m:UpdateItem") {
            let read = request.contains("<t:IsRead>true")
            let unread = request.contains("<t:IsRead>false")
            let flag = request.contains("<t:FlagStatus>Flagged")
            for id in itemIDs(request) {
                for key in folders.keys {
                    folders[key] = folders[key]?.map { item in
                        guard item.id == id else { return item }
                        var copy = item
                        if read { copy.isRead = true }
                        if unread { copy.isRead = false }
                        if request.contains("FlagStatus") { copy.flagged = flag }
                        return copy
                    }
                }
            }
            return (200, envelope(success("UpdateItem")))
        }
        if request.contains("<m:MoveItem") {
            let target = folder(of: request)
            let ids = Set(itemIDs(request))
            var moving: [FakeItem] = []
            for key in folders.keys {
                moving += folders[key]?.filter { ids.contains($0.id) } ?? []
                folders[key]?.removeAll { ids.contains($0.id) }
            }
            folders[target, default: []] += moving.map { var c = $0; c.id = "MOVED-" + c.id; return c }
            return (200, envelope(success("MoveItem")))
        }
        if request.contains("<m:DeleteItem") {
            let ids = Set(itemIDs(request))
            for key in folders.keys { folders[key]?.removeAll { ids.contains($0.id) } }
            return (200, envelope(success("DeleteItem")))
        }
        if request.contains("<m:CreateItem") {
            sent.append(request)
            return (200, envelope(success("CreateItem", "<m:Items/>")))
        }
        return (500, envelope("<s:Fault><faultcode>s:Client</faultcode><faultstring>Неизвестный запрос</faultstring></s:Fault>"))
    }
}

// MARK: - Данные

let now = Date()
let iso = ISO8601DateFormatter()
func ago(_ hours: Double) -> String { iso.string(from: now.addingTimeInterval(-hours * 3600)) }

let internalMime = "From: Ivan <ivan.petrov@example.com>\r\nTo: ilya@example.com\r\nSubject: Отчёт\r\nMessage-ID: <aaa1@example.com>\r\n"
    + "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b\"\r\n\r\n"
    + "--b\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nПривет! Отчёт во вложении.\r\n"
    + "--b\r\nContent-Type: application/pdf; name=\"q3.pdf\"\r\nContent-Disposition: attachment; filename=\"q3.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\nJVBERi0xLjQK\r\n--b--\r\n"

let fake = FakeExchange()
fake.folders["inbox"] = [
    FakeItem(id: "AAA1", subject: "Отчёт", received: ago(2), fromName: "Иван Петров",
             fromEmail: "/O=EXAMPLE/OU=EXCHANGE/CN=RECIPIENTS/CN=IVAN", routing: "EX", isRead: false,
             conversation: "CONV1", mime: internalMime),
    FakeItem(id: "AAA2", subject: "Дайджест недели", received: ago(5), fromName: "Рассылка",
             fromEmail: "news@digest.ru", routing: "SMTP", isRead: false, conversation: "CONV2",
             headers: [("From", "Рассылка <news@digest.ru>"), ("To", "ilya@example.com"),
                       ("List-Unsubscribe", "<https://digest.ru/u?1>"), ("List-Unsubscribe-Post", "List-Unsubscribe=One-Click"),
                       ("List-Id", "digest.digest.ru")],
             mime: "From: news@digest.ru\r\nSubject: Дайджест\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Новости</p>\r\n"),
]

let database = try! MailDatabase.inMemory()
var account = Account(displayName: "Работа", email: "ilya@example.com", kind: .outlook, tint: .blue)
account.senderName = "Илья Баландин"
account.exchange = ExchangeSettings(server: "mail.example.com", username: "EXAMPLE\\ilya")
let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unimail-ews-\(UUID().uuidString)")
let provider = EWSProvider(account: account, database: database,
                           post: { body in fake.respond(body) }, cacheDirectory: cache)

check(EWSEndpoint.url(for: "mail.example.com")?.absoluteString == "https://mail.example.com/EWS/Exchange.asmx", "endpoint from host")
check(EWSEndpoint.url(for: "https://x.ru/EWS/Exchange.asmx")?.host == "x.ru", "endpoint as url")

// 1. Первая синхронизация.
let first = try await provider.sync(cursor: nil)
let inbox = first.upserted.filter { $0.role == .inbox }.sorted { $0.date > $1.date }
check(inbox.count == 2, "two inbox messages")
let report = inbox.first { $0.subject == "Отчёт" }
let digest = inbox.first { $0.subject == "Дайджест недели" }
check(report?.from.email == "ivan.petrov@example.com" && report?.from.name == "Иван Петров", "EX sender resolved to SMTP")
check(report?.to.first?.email == "ilya@example.com", "EX recipient resolved")
check(report?.threadID == "\(account.id.uuidString)-cCONV1", "thread from ConversationId")
check(report?.headerMessageID == "aaa1@example.com", "internet message id")
check(report?.body == "Превью Отчёт" && report?.bodyPending == true, "preview, body pending")
check(report?.attachmentHint == true, "attachment hint")
check(digest?.from.email == "news@digest.ru", "sender from headers")
check(digest?.listUnsubscribe?.contains("https://digest.ru/u?1") == true && digest?.listUnsubscribePost == true, "unsubscribe headers")
check(first.headers[digest?.id ?? ""]?["list-id"] == "digest.digest.ru", "raw headers for categorizer")
check(fake.lock.withLock { fake.requests.filter { $0.contains("<m:ResolveNames") }.count } == 2, "EX addresses resolved once each")
check(EWSProvider.location(of: report?.id ?? "")?.item == "AAA1", "id round-trip")
try database.upsert(first.upserted)

// 1a. Свои папки: дерево без системных, календаря, RSS и содержимого корзины; архив UniMail не дублируется.
let folderList = first.folders ?? []
check(folderList.map(\.name) == ["Клиенты", "Проекты", "Альфа", "Бета"], "custom folders in tree order: \(folderList.map(\.name))")
check(folderList.map(\.depth) == [0, 0, 1, 1], "folder depth")
check(folderList.first { $0.id == "PROJ-A" }?.parentID == "PROJ", "folder parent")
check(folderList.first { $0.id == "PROJ" }?.unread == 2 && folderList.first?.total == 5, "server counters")

// 1b. Письма своей папки — по запросу.
fake.lock.withLock {
    fake.folders["PROJ"] = [FakeItem(id: "P1", subject: "PI Planning", received: ago(1), fromName: "Jira",
                                     fromEmail: "jira@example.com", routing: "SMTP", isRead: false, conversation: "CP1",
                                     headers: [("From", "Jira <jira@example.com>")], mime: "Subject: PI\r\n\r\nx")]
}
let projects = try await provider.syncFolder("PROJ")
check(projects.upserted.count == 1 && projects.upserted.first?.role == .custom && projects.upserted.first?.folder == "PROJ", "custom folder synced")
check(fake.lock.withLock { fake.requests.last { $0.contains("<m:FindItem") }?.contains("<t:FolderId Id=\"PROJ\"/>") == true }, "FindItem by folder id")
try database.upsert(projects.upserted)
if let p1 = projects.upserted.first {
    try await provider.apply(.moveToFolder(ids: [p1.id], folder: "CLIENTS"))
    check(fake.lock.withLock { fake.folders["CLIENTS"]?.count == 1 && fake.folders["PROJ"]?.isEmpty == true }, "moved to custom folder")
    let again = try await provider.syncFolder("PROJ")
    check(again.deletedIDs == [p1.id], "moved message leaves source folder")
    try database.delete(ids: again.deletedIDs)
}

// 1c. Правила сервера.
let rules = try await provider.serverRules()
check(rules.map(\.name) == ["Jira в Проекты", "Старое"], "rules by priority")
check(rules.first?.conditions == ["от jira@example.com", "тема содержит «PI»"], "rule conditions: \(rules.first?.conditions ?? [])")
check(rules.first?.actions == ["переместить в папку «Проекты»", "отметить прочитанным"], "rule actions with folder name: \(rules.first?.actions ?? [])")
check(rules.last?.isEnabled == false && rules.last?.actions == ["удалить"], "disabled rule")

// 2. Изменения на сервере.
fake.lock.withLock {
    fake.folders["inbox"]?[0].isRead = true
    fake.folders["inbox"]?.remove(at: 1)
}
let second = try await provider.sync(cursor: nil)
check(second.upserted.count == 1 && second.upserted.first?.isRead == true, "read state from server")
check(second.deletedIDs == [digest?.id ?? ""], "deleted on server")
try database.upsert(second.upserted)
try database.delete(ids: second.deletedIDs)

// 3. Тело письма из MIME.
if let report {
    let content = try await provider.fetchContent(for: report)
    check(content.text?.contains("Отчёт во вложении") == true, "body text from MIME")
    check(content.attachments.first?.filename == "q3.pdf", "attachment from MIME")
    check(content.attachments.first?.localPath.map { FileManager.default.fileExists(atPath: $0) } == true, "attachment cached")
}

// 4. Действия.
if let report {
    try await provider.apply(.markRead(ids: [report.id], read: false))
    check(fake.lock.withLock { fake.requests.last?.contains("<t:IsRead>false</t:IsRead>") == true }, "UpdateItem IsRead")
    try await provider.apply(.flag(ids: [report.id], flagged: true))
    check(fake.lock.withLock { fake.folders["inbox"]?.first?.flagged == true }, "flag set")
    try await provider.apply(.move(ids: [report.id], to: .archive))
    check(fake.lock.withLock { fake.folders["ARCH"]?.count == 1 && fake.folders["inbox"]?.isEmpty == true }, "moved to archive folder")
    let third = try await provider.sync(cursor: nil)
    check(third.deletedIDs.contains(report.id), "old inbox id removed after move")
    check(third.upserted.contains { $0.role == .archive && $0.folder == "archive" && $0.subject == "Отчёт" }, "archive copy synced")
}

// 5. Поиск на сервере.
let found = try await provider.serverSearch("отчёт")
check(found.contains { $0.subject == "Отчёт" }, "server search")
check(fake.lock.withLock { fake.requests.contains { $0.contains("<m:QueryString>отчёт</m:QueryString>") } }, "QueryString sent")

// 6. Отправка.
var outgoing = OutgoingMessage(accountID: account.id, fromAddress: account.email,
                               to: [Address(name: "Иван", email: "ivan.petrov@example.com")], cc: [],
                               bcc: [Address(name: nil, email: "boss@example.com")], subject: "Re: Отчёт", body: "Спасибо!")
outgoing.inReplyToHeader = "aaa1@example.com"
outgoing.referenceHeaders = ["aaa1@example.com"]
let sent = try await provider.send(outgoing)
let createItem = fake.lock.withLock { fake.sent.last ?? "" }
check(createItem.contains("MessageDisposition=\"SendAndSaveCopy\""), "send and save copy")
check(createItem.contains("<t:BccRecipients><t:Mailbox><t:EmailAddress>boss@example.com"), "bcc passed separately")
if let r = createItem.range(of: "CharacterSet=\"UTF-8\">"), let end = createItem[r.upperBound...].range(of: "</t:MimeContent>") {
    let mime = String(decoding: Data(base64Encoded: String(createItem[r.upperBound..<end.lowerBound])) ?? Data(), as: UTF8.self)
    check(mime.contains("In-Reply-To: <aaa1@example.com>") && !mime.lowercased().contains("bcc:"), "MIME with thread headers, no Bcc header")
} else {
    check(false, "MIME in CreateItem")
}
check(sent.role == .sent && sent.id.contains("|local-sent|"), "local sent copy")

// 6a. Календарь Exchange.
check(await provider.hasServerCalendar, "EWS has server calendar")
let windowStart = iso.date(from: "2026-09-28T00:00:00Z")!
let events = try await provider.calendarEvents(from: windowStart, to: windowStart.addingTimeInterval(7 * 86400))
check(events.count == 2, "calendar view items")
let pi = events.first { $0.title == "PI Planning 4Q" }
check(pi?.source == .exchange && pi?.remoteID == "CAL1" && pi?.id == "\(account.id.uuidString)|CAL1", "event ids")
check(pi?.myResponse == EventResponse.none && pi?.needsResponse == true && pi?.canEdit == false, "invite awaiting response")
check(pi?.organizer?.email == "gaz@example.com" && pi?.location == "Teams" && pi?.detailsPending == true, "organizer and location")
check(events.first { $0.title == "Фокус-время" }?.myResponse == .organizer, "own event")
check(fake.lock.withLock { fake.requests.last { $0.contains("<m:CalendarView") }?.contains("StartDate=\"2026-09-28T00:00:00Z\"") == true }, "calendar view range")
if let pi {
    let detailed = try await provider.calendarEventDetails(pi)
    check(detailed.attendees.count == 3 && detailed.detailsPending == false, "attendees loaded")
    check(detailed.attendees.contains { $0.email == "ilya@example.com" && $0.response == EventResponse.none }, "EX attendee resolved")
    check(detailed.attendees.contains { $0.email == "olga@example.com" && $0.optional && $0.response == .declined }, "optional declined")
    check(detailed.meetingURL?.host == "teams.microsoft.com", "Teams link from body")
    try await provider.respondToEvent(remoteID: pi.remoteID, response: .accepted, comment: nil)
    check(fake.lock.withLock { fake.calendarRequests.last?.contains("<t:AcceptItem><t:ReferenceItemId Id=\"CAL1\"/></t:AcceptItem>") == true }, "AcceptItem sent")
    try await provider.respondToEvent(remoteID: pi.remoteID, response: .declined, comment: "Отпуск")
    check(fake.lock.withLock { fake.calendarRequests.last?.contains("<t:DeclineItem><t:Body BodyType=\"Text\">Отпуск</t:Body><t:ReferenceItemId") == true }, "DeclineItem with comment")
}
var newEvent = EventDraft(start: iso.date(from: "2026-10-05T07:00:00Z")!, duration: 1800)
newEvent.title = "Созвон & ретро"
newEvent.location = "Переговорная 5"
newEvent.attendees = [Address(name: "Иван", email: "ivan.petrov@example.com")]
let created = try await provider.saveEvent(newEvent)
let createXML = fake.lock.withLock { fake.calendarRequests.last ?? "" }
check(created == "NEWCAL", "created event id")
check(createXML.contains("SendMeetingInvitations=\"SendToAllAndSaveCopy\"") && createXML.contains("<t:Subject>Созвон &amp; ретро</t:Subject>"), "create with invitations")
check(createXML.range(of: "<t:Subject>")!.lowerBound < createXML.range(of: "<t:Start>")!.lowerBound
      && createXML.range(of: "<t:Start>")!.lowerBound < createXML.range(of: "<t:Location>")!.lowerBound
      && createXML.range(of: "<t:Location>")!.lowerBound < createXML.range(of: "<t:RequiredAttendees>")!.lowerBound, "schema order")
check(createXML.contains("<t:Start>2026-10-05T07:00:00Z</t:Start><t:End>2026-10-05T07:30:00Z</t:End>"), "UTC times")
var edit = newEvent
edit.remoteID = "NEWCAL"
edit.attendeesChanged = false
_ = try await provider.saveEvent(edit)
let updateXML = fake.lock.withLock { fake.calendarRequests.last ?? "" }
check(updateXML.contains("<m:UpdateItem") && updateXML.contains("FieldURI=\"calendar:Start\"") && !updateXML.contains("RequiredAttendees"), "update keeps attendees")
try await provider.deleteEvent(remoteID: "NEWCAL")
check(fake.lock.withLock { fake.calendarRequests.last?.contains("SendMeetingCancellations=\"SendToAllAndSaveCopy\"") == true }, "delete sends cancellations")
check(try await provider.respondToInvite(messageID: "\(account.id.uuidString)|ews|inbox|MR1", response: .tentative), "invite answered by server")
check(fake.lock.withLock { fake.calendarRequests.last?.contains("<t:TentativelyAcceptItem><t:ReferenceItemId Id=\"MR1\"/>") == true }, "TentativelyAcceptItem on meeting request")

// 7. Неверный пароль.
fake.lock.withLock { fake.password = "changed" }
do {
    try await provider.verifyLogin()
    check(false, "401 → authentication failed")
} catch MailProviderError.loginRejected(let server, _) {
    check(server == "Exchange mail.example.com", "401 → authentication failed")
}

print("\n\(passed) passed, \(failed.count) failed")
for f in failed { print("  FAIL \(f)") }
try? FileManager.default.removeItem(at: cache)
exit(failed.isEmpty ? 0 : 1)
