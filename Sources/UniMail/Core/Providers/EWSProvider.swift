import Foundation

/// Провайдер Exchange Web Services — для корпоративного Exchange, где IMAP выключен (как у Outlook для Mac).
///
/// Синхронизация без состояния на сервере: на каждую папку — FindItem за последние 30 дней (не больше 400),
/// сверка с базой (новые, удалённые, флаги), новые письма дочитываются GetItem. Тело — MIME целиком.
/// Идентификатор письма: `"<accountID>|ews|<папка>|<ItemId>"`.
actor EWSProvider: MailProvider {
    nonisolated let accountID: UUID
    private let account: Account
    private let database: MailDatabase
    private let client: EWSClient
    private let cacheDirectory: URL

    private var archiveFolder: EWSFolderRef?
    /// Id стандартных папок Exchange (inbox → AAMk…), чтобы отличать их от своих.
    private var distinguished: [String: String]?
    /// Имена своих папок по id — для текста серверных правил.
    private var folderNames: [String: String] = [:]
    /// Внутренние адреса Exchange (/O=…) → SMTP.
    private var resolved: [String: Address] = [:]

    var initialDays = 30
    var initialLimit = 400
    /// Как часто опрашивать сервер (IDLE в EWS нет — есть push/streaming, опрос проще и надёжнее).
    var pollInterval: TimeInterval = 60

    init(account: Account, database: MailDatabase, post: @escaping EWSPost, cacheDirectory: URL) {
        self.accountID = account.id
        self.account = account
        self.database = database
        self.client = EWSClient(post: post)
        self.cacheDirectory = cacheDirectory
    }

    /// Папки UniMail ↔ папки Exchange. Ключ папки хранится в `Message.folder`.
    static let folders: [(role: MailboxRole, key: String)] = [
        (.inbox, "inbox"), (.sent, "sentitems"), (.drafts, "drafts"),
        (.archive, "archive"), (.spam, "junkemail"), (.trash, "deleteditems"),
    ]

    // MARK: Идентификаторы

    func messageID(folder: String, item: String) -> String {
        "\(accountID.uuidString)|ews|\(folder)|\(item)"
    }

    nonisolated static func location(of id: String) -> (folder: String, item: String)? {
        let parts = id.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[1] == "ews" else { return nil }
        return (String(parts[2]), String(parts[3]))
    }

    // MARK: Папки

    static let distinguishedKeys: Set<String> = ["inbox", "sentitems", "drafts", "junkemail", "deleteditems"]

    private func folderRef(_ key: String, create: Bool = false) async throws -> EWSFolderRef? {
        if Self.distinguishedKeys.contains(key) { return .distinguished(key) }
        guard key == "archive" else { return .id(key) }
        if let archiveFolder { return archiveFolder }
        let folders = try await client.findFolders(parent: .distinguished("msgfolderroot"))
        if let found = folders.first(where: { ["архив", "archive"].contains($0.name.lowercased()) }) {
            archiveFolder = .id(found.id)
            return archiveFolder
        }
        guard create else { return nil }
        let created = try await client.createFolder(name: "Архив", parent: .distinguished("msgfolderroot"))
        archiveFolder = .id(created.id)
        return archiveFolder
    }

    private static func key(for role: MailboxRole) -> String? {
        folders.first { $0.role == role }?.key
    }

    // MARK: Синхронизация

    func sync(cursor: String?) async throws -> SyncResult {
        try await mapped {
            var result = SyncResult(upserted: [], deletedIDs: [], cursor: nil)
            for (role, key) in Self.folders {
                guard let folder = try await folderRef(key) else { continue }
                let part = try await syncFolder(folder, key: key, role: role)
                result.upserted += part.upserted
                result.deletedIDs += part.deletedIDs
                result.headers.merge(part.headers) { a, _ in a }
            }
            // Список своих папок не критичен: если сервер его не отдал, почта всё равно синхронизирована.
            result.folders = try? await customFolders()
            return result
        }
    }

    /// Своя папка (открыта в боковой панели): письма за то же окно, что и у стандартных.
    func syncFolder(_ key: String) async throws -> SyncResult {
        try await mapped {
            guard let folder = try await folderRef(key) else { return SyncResult(upserted: [], deletedIDs: [], cursor: nil) }
            let role = Self.folders.first { $0.key == key }?.role ?? .custom
            return try await syncFolder(folder, key: key, role: role)
        }
    }

    /// Системные папки, которые не показываем среди своих (вместе с вложенными).
    static let hiddenDistinguished = ["msgfolderroot", "inbox", "sentitems", "drafts", "deleteditems", "junkemail",
                                      "outbox", "syncissues", "conflicts", "localfailures", "serverfailures",
                                      "conversationhistory"]
    static let hiddenSubtrees: Set<String> = ["deleteditems", "junkemail", "outbox", "syncissues", "conversationhistory"]
    static let hiddenNames: Set<String> = ["yammer root", "files", "externalcontacts", "personmetadata",
                                           "rss feeds", "rss-каналы", "quick step settings"]

    /// Свои почтовые папки ящика в порядке дерева: куда раскладывают правила Outlook и пользователь.
    private func customFolders() async throws -> [MailFolder] {
        if distinguished == nil {
            distinguished = try await client.distinguishedFolderIDs(Self.hiddenDistinguished)
        }
        let known = distinguished ?? [:]
        let all = try await client.findAllFolders()
        for folder in all { folderNames[folder.id] = folder.name }

        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let hiddenIDs = Set(known.values)
        let hiddenRoots = Set(Self.hiddenSubtrees.compactMap { known[$0] })
        let rootID = known["msgfolderroot"]
        if archiveFolder == nil,
           let archive = all.first(where: { $0.parentID == rootID && ["архив", "archive"].contains($0.name.lowercased()) }) {
            archiveFolder = .id(archive.id)
        }
        let archiveID: String? = if case .id(let id) = archiveFolder { id } else { nil }

        func isMail(_ folder: EWSFolderInfo) -> Bool {
            let cls = folder.folderClass ?? "IPF.Note"
            return (cls == "IPF.Note" || cls.hasPrefix("IPF.Note.")) && cls != "IPF.Note.OutlookHomepage"
                && !Self.hiddenNames.contains(folder.name.lowercased())
        }
        func underHidden(_ folder: EWSFolderInfo) -> Bool {
            var parent = folder.parentID
            var guardCount = 0
            while let id = parent, guardCount < 32 {
                if hiddenRoots.contains(id) { return true }
                parent = byID[id]?.parentID
                guardCount += 1
            }
            return false
        }
        let visible = all.filter { isMail($0) && !hiddenIDs.contains($0.id) && $0.id != archiveID && !underHidden($0) }
        let visibleIDs = Set(visible.map(\.id))
        let children = Dictionary(grouping: visible) { folder -> String in
            guard let parent = folder.parentID, visibleIDs.contains(parent) else { return "" }
            return parent
        }

        var result: [MailFolder] = []
        func walk(_ parent: String, depth: Int) {
            let list = (children[parent] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for folder in list {
                result.append(MailFolder(id: folder.id, name: folder.name,
                                         parentID: parent.isEmpty ? nil : parent, depth: depth,
                                         unread: folder.unread, total: folder.total))
                walk(folder.id, depth: depth + 1)
            }
        }
        walk("", depth: 0)
        return result
    }

    /// Правила «Входящих» с сервера — только для показа, выполняет их сам Exchange.
    func serverRules() async throws -> [ServerRule] {
        try await mapped {
            let rules = try await client.inboxRules(mailbox: account.email)
            if rules.contains(where: { !$0.folderIDs.isEmpty }) && folderNames.isEmpty {
                _ = try? await customFolders()
            }
            let names = folderNames.merging(
                (distinguished ?? [:]).map { ($0.value, Self.title(forDistinguished: $0.key)) },
                uniquingKeysWith: { a, _ in a })
            return rules.sorted { $0.priority < $1.priority }.map { rule in
                let actions = rule.actions.map { text in
                    rule.folderIDs.reduce(text) { $0.replacingOccurrences(of: "{\($1)}", with: "«\(names[$1] ?? "папка")»") }
                }
                return ServerRule(id: rule.id, name: rule.name, isEnabled: rule.isEnabled,
                                  conditions: rule.conditions, actions: actions)
            }
        }
    }

    static func title(forDistinguished key: String) -> String {
        switch key {
        case "inbox": "Входящие"
        case "sentitems": "Отправленные"
        case "drafts": "Черновики"
        case "deleteditems": "Удалённые"
        case "junkemail": "Нежелательная почта"
        default: key
        }
    }

    private func syncFolder(_ folder: EWSFolderRef, key: String, role: MailboxRole) async throws -> SyncResult {
        var result = SyncResult(upserted: [], deletedIDs: [], cursor: nil)
        let since = Calendar.current.date(byAdding: .day, value: -initialDays, to: .now) ?? .now
        let (found, complete) = try await client.findItems(in: folder, since: since, max: initialLimit)
        let local = try database.messages(accountID: accountID, folder: key)
        result.deletedIDs += try database.movedIn(accountID: accountID, folder: key)
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var seen = Set<String>()
        var fresh: [String] = []
        for item in found {
            let id = messageID(folder: key, item: item.id)
            seen.insert(id)
            if var existing = localByID[id] {
                let read = item.isRead ?? existing.isRead
                let flagged = item.flagged ?? existing.isFlagged
                if read != existing.isRead || flagged != existing.isFlagged {
                    existing.isRead = read
                    existing.isFlagged = flagged
                    result.upserted.append(existing)
                }
            } else {
                fresh.append(item.id)
            }
        }

        // Удалённые и перенесённые на сервере: только в пределах окна, которое вернул сервер
        // (старые письма из поиска на сервере не трогаем).
        let boundary = complete ? since : (found.compactMap(\.received).min() ?? since)
        for message in local where !seen.contains(message.id) && message.date >= boundary {
            result.deletedIDs.append(message.id)
        }

        if !fresh.isEmpty {
            for item in try await client.getItems(ids: fresh) {
                let message = await makeMessage(item, folder: key, role: role)
                result.upserted.append(message)
                result.headers[message.id] = item.headers
            }
        }
        return result
    }

    private func makeMessage(_ item: EWSItem, folder: String, role: MailboxRole) async -> Message {
        let headers = item.headers
        // Заголовки письма дают SMTP-адреса; у внутренних писем Exchange их может не быть — тогда адресная книга.
        var from = MIMEParser.parseAddressList(headers["from"] ?? "").first
        if from == nil, let mailbox = item.from { from = await address(mailbox) }
        var to = MIMEParser.parseAddressList(headers["to"] ?? "")
        if to.isEmpty { to = await addresses(item.to) }
        var cc = MIMEParser.parseAddressList(headers["cc"] ?? "")
        if cc.isEmpty { cc = await addresses(item.cc) }

        let headerID = (item.internetMessageID ?? headers["message-id"]).map(IMAPProvider.stripAngles)
        let references = IMAPProvider.messageIDs(in: item.references ?? headers["references"] ?? "")
        let inReplyTo = IMAPProvider.messageIDs(in: item.inReplyTo ?? headers["in-reply-to"] ?? "").first
        let threadKey: String
        if let conversation = item.conversationID {
            threadKey = "c" + conversation
        } else {
            threadKey = "m" + (references.first ?? inReplyTo ?? headerID ?? item.id)
        }

        var message = Message(
            id: messageID(folder: folder, item: item.id),
            accountID: accountID,
            threadID: "\(accountID.uuidString)-\(threadKey)",
            role: role,
            from: from ?? Address(name: nil, email: ""),
            to: to,
            cc: cc,
            subject: (item.subject?.isEmpty == false ? item.subject : nil) ?? "(без темы)",
            body: item.preview ?? "",
            date: item.received ?? item.sent ?? .now,
            isRead: (item.isRead ?? false) || role == .sent || role == .drafts,
            isFlagged: item.flagged ?? false
        )
        message.folder = folder
        message.headerMessageID = headerID
        message.inReplyToHeader = inReplyTo
        message.references = references.isEmpty ? nil : references
        message.listUnsubscribe = headers["list-unsubscribe"].flatMap { $0.contains(":") ? $0 : nil }
        message.listUnsubscribePost = headers["list-unsubscribe-post"]?.lowercased().contains("one-click")
        message.bodyPending = true
        message.attachmentHint = item.hasAttachments ?? false
        return message
    }

    private func address(_ mailbox: EWSMailbox) async -> Address {
        guard mailbox.isExchangeLegacy else { return Address(name: mailbox.name, email: mailbox.email) }
        if let cached = resolved[mailbox.email] { return Address(name: mailbox.name ?? cached.name, email: cached.email) }
        let smtp = (try? await client.resolve(mailbox.email))?.email ?? ""
        let result = Address(name: mailbox.name, email: smtp.contains("@") ? smtp : "")
        resolved[mailbox.email] = result
        return result
    }

    private func addresses(_ list: [EWSMailbox]) async -> [Address] {
        var result: [Address] = []
        for mailbox in list { result.append(await address(mailbox)) }
        return result
    }

    // MARK: Действия

    func apply(_ action: MailAction) async throws {
        let items = action.ids.compactMap { Self.location(of: $0)?.item }
        guard !items.isEmpty else { return }
        try await mapped {
            switch action {
            case .markRead(_, let read):
                try await client.setRead(ids: items, read: read)
            case .flag(_, let flagged):
                try await client.setFlag(ids: items, flagged: flagged)
            case .move(_, let role):
                guard let key = Self.key(for: role), let target = try await folderRef(key, create: true) else { return }
                try await client.move(ids: items, to: target)
            case .moveToFolder(_, let folder):
                guard let target = try await folderRef(folder) else { return }
                try await client.move(ids: items, to: target)
            case .deletePermanently:
                try await client.delete(ids: items)
            case .snooze:
                // «Отложить» живёт локально.
                break
            }
        }
    }

    // MARK: Тело

    func fetchContent(for message: Message) async throws -> MessageContent {
        guard let location = Self.location(of: message.id) else { throw MailProviderError.notFound }
        let raw = try await mapped { try await client.getMime(id: location.item) }
        return MailContentBuilder.content(from: MIMEParser.parse(raw), accountID: accountID,
                                          messageID: message.id, cacheDirectory: cacheDirectory)
    }

    func rawSource(for message: Message) async throws -> Data {
        guard let location = Self.location(of: message.id) else { throw MailProviderError.notFound }
        return try await mapped { try await client.getMime(id: location.item) }
    }

    // MARK: Поиск и ожидание

    func serverSearch(_ query: String) async throws -> [Message] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return try await mapped {
            var found: [Message] = []
            for role in [MailboxRole.inbox, .archive, .sent] {
                guard let key = Self.key(for: role), let folder = try await folderRef(key) else { continue }
                let hits = try await client.findItems(in: folder, since: nil, max: 40, query: q).items
                guard !hits.isEmpty else { continue }
                for item in try await client.getItems(ids: hits.map(\.id)) {
                    found.append(await makeMessage(item, folder: key, role: role))
                }
            }
            return found
        }
    }

    /// Push-уведомлений нет — просто пауза; MailStore после неё синхронизирует ящик.
    func waitForChanges(timeout: TimeInterval) async throws -> Bool {
        try await Task.sleep(nanoseconds: UInt64(min(timeout, pollInterval) * 1_000_000_000))
        return true
    }

    // MARK: Отправка

    func send(_ outgoing: OutgoingMessage) async throws -> Message {
        let from = Address(name: account.senderName, email: outgoing.fromAddress)
        let domain = outgoing.fromAddress.split(separator: "@").last.map(String.init) ?? "unimail.local"
        var attachments: [OutgoingAttachment] = []
        for url in outgoing.attachmentURLs {
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent,
                                                  mimeType: IMAPProvider.mimeType(for: url),
                                                  data: try Data(contentsOf: url)))
        }
        let html = outgoing.htmlBody.map {
            "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">\($0)</body></html>"
        }

        func mime(to: [Address], cc: [Address]) -> (OutgoingMIME, String) {
            let id = MIMEBuilder.makeMessageID(domain: domain)
            var m = OutgoingMIME(from: from, to: to, subject: outgoing.subject, textBody: outgoing.body, messageID: id)
            m.cc = cc
            m.htmlBody = html
            m.attachments = attachments
            m.inReplyTo = outgoing.inReplyToHeader
            m.references = outgoing.referenceHeaders ?? []
            m.extraHeaders = [("X-Mailer", "UniMail for macOS")]
            if let ics = outgoing.calendarReply { m.calendar = (outgoing.calendarMethod ?? "REPLY", ics) }
            return (m, id)
        }

        var batches: [(OutgoingMIME, String, [String])] = []
        if outgoing.sendSeparately && outgoing.to.count > 1 {
            batches = outgoing.to.map { let (m, id) = mime(to: [$0], cc: []); return (m, id, []) }
        } else {
            let (m, id) = mime(to: outgoing.to, cc: outgoing.cc)
            batches = [(m, id, outgoing.bcc.map(\.email))]
        }

        var lastID = ""
        for (message, id, bcc) in batches {
            let data = MIMEBuilder.build(message)
            try await mapped { try await client.send(mime: data, bcc: bcc) }
            lastID = id
        }

        var result = Message(
            id: "\(accountID.uuidString)|local-sent|\(lastID)",
            accountID: accountID,
            threadID: outgoing.threadID ?? "\(accountID.uuidString)-m\(lastID)",
            role: .sent,
            from: from,
            to: outgoing.to,
            cc: outgoing.cc,
            subject: outgoing.subject,
            body: outgoing.body,
            htmlBody: outgoing.htmlBody,
            date: .now,
            isRead: true
        )
        result.headerMessageID = IMAPProvider.stripAngles(lastID)
        result.attachmentHint = !attachments.isEmpty
        return result
    }

    // MARK: Календарь

    nonisolated var hasServerCalendar: Bool { true }

    func calendarEvents(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try await mapped {
            var events: [CalendarEvent] = []
            for item in try await client.calendarView(from: start, to: end) {
                events.append(await event(from: item, detailed: false))
            }
            return events
        }
    }

    func calendarEventDetails(_ event: CalendarEvent) async throws -> CalendarEvent {
        try await mapped {
            guard let item = try await client.calendarDetails(ids: [event.remoteID]).first else { return event }
            var detailed = await self.event(from: item, detailed: true)
            // Повторяющаяся встреча: id экземпляра, время — из CalendarView.
            detailed.start = event.start
            detailed.end = event.end
            return detailed
        }
    }

    private func event(from item: EWSCalendarItem, detailed: Bool) async -> CalendarEvent {
        func response(_ text: String?) -> EventResponse {
            switch text {
            case "Accept": .accepted
            case "Tentative": .tentative
            case "Decline": .declined
            case "Organizer": .organizer
            default: .none
            }
        }
        var organizer: EventAttendee?
        if let box = item.organizer {
            let address = await address(box)
            organizer = EventAttendee(name: address.name, email: address.email, response: .organizer)
        }
        let isOrganizer = item.myResponse == "Organizer"
            || (organizer?.email.lowercased() == account.email.lowercased() && !account.email.isEmpty)
        var attendees: [EventAttendee] = []
        for (box, status) in item.required {
            let address = await address(box)
            attendees.append(EventAttendee(name: address.name, email: address.email, response: response(status)))
        }
        for (box, status) in item.optional {
            let address = await address(box)
            attendees.append(EventAttendee(name: address.name, email: address.email, response: response(status), optional: true))
        }
        var event = CalendarEvent(
            id: "\(accountID.uuidString)|\(item.id)", source: .exchange, accountID: accountID, remoteID: item.id,
            title: item.subject.isEmpty ? "(без названия)" : item.subject,
            start: item.start, end: item.end
        )
        event.isAllDay = item.isAllDay
        event.location = item.location ?? ""
        event.notes = item.body ?? ""
        event.organizer = organizer
        event.attendees = attendees
        event.isMeeting = item.isMeeting
        event.isCancelled = item.isCancelled
        event.isRecurring = item.isRecurring
        event.myResponse = isOrganizer ? .organizer : response(item.myResponse)
        event.calendarTitle = account.displayName
        event.canEdit = isOrganizer || !item.isMeeting
        event.detailsPending = !detailed
        return event
    }

    func saveEvent(_ draft: EventDraft) async throws -> String {
        let zone = draft.isAllDay ? WindowsTimeZones.windows() : nil
        return try await mapped {
            if let id = draft.remoteID {
                try await client.updateCalendarItem(
                    id: id, subject: draft.title, body: draft.notes, reminder: draft.reminderMinutes,
                    start: draft.start, end: draft.end, isAllDay: draft.isAllDay, location: draft.location,
                    attendees: draft.attendeesChanged ? draft.attendees.map(\.email) : nil, timeZone: zone)
                return id
            }
            return try await client.createCalendarItem(
                subject: draft.title, body: draft.notes, reminder: draft.reminderMinutes,
                start: draft.start, end: draft.end, isAllDay: draft.isAllDay, location: draft.location,
                attendees: draft.attendees.map(\.email), timeZone: zone)
        }
    }

    func deleteEvent(remoteID: String) async throws {
        try await mapped { try await client.deleteCalendarItem(id: remoteID) }
    }

    func respondToEvent(remoteID: String, response: EventResponse, comment: String?) async throws {
        guard let kind = Self.meetingResponse(response) else { return }
        try await mapped { try await client.respond(to: remoteID, kind, comment: comment) }
    }

    /// Приглашение в письме Exchange — это MeetingRequest: отвечаем на него, сервер сам обновит календарь.
    func respondToInvite(messageID: String, response: EventResponse) async throws -> Bool {
        guard let location = Self.location(of: messageID), let kind = Self.meetingResponse(response) else { return false }
        try await mapped { try await client.respond(to: location.item, kind) }
        return true
    }

    /// Встреча из Календаря macOS на сервере: сначала в сетке дня, потом серия по теме, потом приглашение во «Входящих».
    func locateEvent(title: String, start: Date, end: Date) async throws -> CalendarEvent? {
        let wanted = CalendarEvent.normalizedTitle(title)
        let subject = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return try await mapped {
            let day = try await client.calendarView(from: start.addingTimeInterval(-3600), to: end.addingTimeInterval(3600))
            if let item = day.first(where: { CalendarEvent.normalizedTitle($0.subject) == wanted && abs($0.start.timeIntervalSince(start)) < 3600 }) {
                return await event(from: item, detailed: false)
            }
            let series = try await client.findCalendarItems(subject: subject)
            if let item = series.first(where: { CalendarEvent.normalizedTitle($0.subject) == wanted && !$0.isCancelled }) {
                var found = await event(from: item, detailed: false)
                found.start = start
                found.end = end
                return found
            }
            let requests = try await client.findMeetingRequests(subject: subject)
            if let request = requests.first {
                var found = CalendarEvent(id: "\(accountID.uuidString)|\(request.id)", source: .exchange, accountID: accountID,
                                          remoteID: request.id, title: title, start: start, end: end)
                found.isMeeting = true
                found.myResponse = .none
                found.canEdit = false
                return found
            }
            return nil
        }
    }

    static func meetingResponse(_ response: EventResponse) -> EWSMeetingResponse? {
        switch response {
        case .accepted: .accept
        case .tentative: .tentative
        case .declined: .decline
        case .none, .organizer: nil
        }
    }

    // MARK: Проверка

    func verifyLogin() async throws {
        _ = try await mapped { try await client.getFolder(.distinguished("inbox")) }
    }

    /// Ошибки EWS → понятные ошибки провайдера (неверный пароль, нет связи).
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch EWSError.unauthorized(let detail) {
            let host = account.exchange.flatMap { EWSEndpoint.url(for: $0.server)?.host } ?? "сервер"
            throw MailProviderError.loginRejected(server: "Exchange \(host)", details: detail)
        }
    }
}
