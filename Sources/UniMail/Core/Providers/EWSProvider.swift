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

    private func folderRef(_ key: String, create: Bool = false) async throws -> EWSFolderRef? {
        guard key == "archive" else { return .distinguished(key) }
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
            return result
        }
    }

    private func syncFolder(_ folder: EWSFolderRef, key: String, role: MailboxRole) async throws -> SyncResult {
        var result = SyncResult(upserted: [], deletedIDs: [], cursor: nil)
        let since = Calendar.current.date(byAdding: .day, value: -initialDays, to: .now) ?? .now
        let (found, complete) = try await client.findItems(in: folder, since: since, max: initialLimit)
        let local = try database.messages(accountID: accountID, folder: key)
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
            if let ics = outgoing.calendarReply { m.calendar = ("REPLY", ics) }
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
