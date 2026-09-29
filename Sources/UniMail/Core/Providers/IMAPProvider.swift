import Foundation

/// Провайдер для любых IMAP/SMTP-ящиков: Gmail (пароль приложения, расширения X-GM),
/// iCloud, Яндекс, Mail.ru, корпоративный Exchange.
///
/// Состояние папок (UIDVALIDITY, последний UID, HIGHESTMODSEQ) хранится в базе, письма сливает MailStore.
/// Идентификатор письма: `"<accountID>|<папка>|<uidvalidity>|<uid>"`.
actor IMAPProvider: MailProvider {
    nonisolated let accountID: UUID
    private let account: Account
    private let database: MailDatabase
    private let transportFactory: TransportFactory
    private let password: @Sendable () -> String?
    private let cacheDirectory: URL

    private var client: IMAPClient?
    private var idleClient: IMAPClient?
    private var folders: [IMAPFolder] = []
    private var roleFolders: [MailboxRole: String] = [:]
    private let mutex = AsyncMutex()

    /// Сколько дней истории забирать при первой синхронизации папки.
    var initialDays = 30
    /// Максимум писем в папке при первой синхронизации.
    var initialLimit = 400

    init(account: Account,
         database: MailDatabase,
         transportFactory: @escaping TransportFactory,
         password: @escaping @Sendable () -> String?,
         cacheDirectory: URL) {
        self.accountID = account.id
        self.account = account
        self.database = database
        self.transportFactory = transportFactory
        self.password = password
        self.cacheDirectory = cacheDirectory
    }

    private var server: ServerSettings { account.server ?? ServerSettings(imapHost: "", smtpHost: "", username: account.email) }
    private var isGmail: Bool { server.imapHost.lowercased().contains("gmail") || account.kind == .gmail }

    // MARK: - Соединение

    private func connect(readTimeout: TimeInterval) async throws -> IMAPClient {
        guard !server.imapHost.isEmpty else { throw MailProviderError.missingServerSettings }
        guard let password = password(), !password.isEmpty else { throw MailProviderError.missingPassword }
        let security = server.imapSecurity ?? (server.imapPort == 143 ? .starttls : .tls)
        let transport: MailTransport
        do {
            transport = try await transportFactory(server.imapHost, server.imapPort, security == .tls, readTimeout)
        } catch {
            throw MailProviderError.network(error.localizedDescription)
        }
        let client = IMAPClient(transport: transport)
        do {
            try await client.connect()
            if security == .starttls { try await client.startTLS() }
            try await client.login(username: server.username.isEmpty ? account.email : server.username, password: password)
            try? await client.enableCondStore()
        } catch let error as IMAPError {
            transport.close()
            if case .authenticationFailed = error { throw MailProviderError.authenticationFailed }
            throw error
        } catch {
            transport.close()
            throw MailProviderError.network(error.localizedDescription)
        }
        return client
    }

    /// Команды выполняются по одной: соединение одно, SELECT разных папок не должен перемешиваться.
    private func exclusive<T>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        await mutex.lock()
        do {
            let client = try await commandClient()
            let result = try await body(client)
            await mutex.unlock()
            return result
        } catch {
            // Соединение могло умереть — следующая операция откроет новое.
            if !(error is IMAPError) || isConnectionError(error) {
                await self.client?.logout()
                self.client = nil
            }
            await mutex.unlock()
            throw error
        }
    }

    private func isConnectionError(_ error: Error) -> Bool {
        if error is MailTransportError { return true }
        if case .unexpected = error as? IMAPError { return true }
        return false
    }

    private func commandClient() async throws -> IMAPClient {
        if let client { return client }
        let fresh = try await connect(readTimeout: 120)
        client = fresh
        return fresh
    }

    private func loadFolders(_ client: IMAPClient) async throws {
        guard folders.isEmpty else { return }
        folders = try await client.listFolders().filter(\.isSelectable)
        var map: [MailboxRole: String] = [:]
        for folder in folders {
            guard let role = folder.role, map[role] == nil else { continue }
            map[role] = folder.name
        }
        if map[.inbox] == nil { map[.inbox] = "INBOX" }
        roleFolders = map
    }

    // MARK: - Идентификаторы

    struct Location: Hashable {
        var folder: String
        var uidValidity: UInt32
        var uid: UInt32
    }

    func messageID(folder: String, uidValidity: UInt32, uid: UInt32) -> String {
        "\(accountID.uuidString)|\(folder)|\(uidValidity)|\(uid)"
    }

    nonisolated static func location(of id: String) -> Location? {
        let parts = id.components(separatedBy: "|")
        guard parts.count >= 4, let uid = UInt32(parts[parts.count - 1]), let validity = UInt32(parts[parts.count - 2]) else {
            return nil
        }
        let folder = parts[1..<(parts.count - 2)].joined(separator: "|")
        return Location(folder: folder, uidValidity: validity, uid: uid)
    }

    // MARK: - Синхронизация

    func sync(cursor: String?) async throws -> SyncResult {
        var result = SyncResult(upserted: [], deletedIDs: [], cursor: nil)
        try await exclusive { client in try await loadFolders(client) }
        let roles: [MailboxRole] = [.inbox, .sent, .drafts, .archive, .spam, .trash]
        for role in roles {
            guard let folder = roleFolders[role] else { continue }
            let part = try await exclusive { client in try await syncFolder(client, folder: folder, role: role) }
            result.upserted += part.upserted
            result.deletedIDs += part.deletedIDs
            result.headers.merge(part.headers) { a, _ in a }
        }
        return result
    }

    private func syncFolder(_ client: IMAPClient, folder: String, role: MailboxRole) async throws -> SyncResult {
        let info = try await client.select(folder, readOnly: true)
        let capabilities = await client.capabilities
        let condStore = capabilities.contains("CONDSTORE") || capabilities.contains("QRESYNC")
        var result = SyncResult(upserted: [], deletedIDs: [], cursor: nil)

        var state = try database.syncState(accountID: accountID, folder: folder)
        var local = try database.folderUIDs(accountID: accountID, folder: folder)

        // Новый UIDVALIDITY — старые UID недействительны, начинаем папку заново.
        if let existing = state, existing.uidValidity != info.uidValidity {
            result.deletedIDs += Array(local.keys)
            local = [:]
            state = nil
        }

        var newUIDs: [UInt32] = []
        if let state {
            if (info.uidNext ?? UInt32.max) > state.lastUID + 1 && info.exists > 0 {
                newUIDs = try await client.uidSearch("UID \(state.lastUID + 1):*").filter { $0 > state.lastUID }
            }
        } else if info.exists > 0 {
            let since = Calendar.current.date(byAdding: .day, value: -initialDays, to: .now) ?? .now
            newUIDs = try await client.uidSearch("SINCE \(Self.searchDate(since))")
            if newUIDs.isEmpty {
                newUIDs = Array(try await client.uidSearch("ALL").suffix(50))
            }
            newUIDs = Array(newUIDs.sorted().suffix(initialLimit))
        }

        // Удалённые на сервере: сверяем диапазон известных UID.
        if !local.isEmpty, let minUID = local.values.min() {
            let present = Set(try await client.uidSearch("UID \(minUID):*"))
            for (id, uid) in local where !present.contains(uid) {
                result.deletedIDs.append(id)
            }
            local = local.filter { present.contains($0.value) }
        }

        // Новые письма.
        if !newUIDs.isEmpty {
            let summaries = try await client.fetchSummaries(uids: newUIDs, includePreview: true)
            for summary in summaries {
                if isGmail && role == .archive && Self.gmailSkipInAllMail(summary.gmailLabels) { continue }
                let message = makeMessage(summary, folder: folder, uidValidity: info.uidValidity, role: role)
                result.upserted.append(message)
                result.headers[message.id] = summary.headers
            }
        }

        // Изменения флагов у известных писем.
        var updates: [IMAPFlagUpdate] = []
        if condStore, let old = state?.highestModSeq, let current = info.highestModSeq, current != old {
            updates = try await client.fetchFlags(changedSince: old)
        } else if !condStore && !local.isEmpty {
            let recent = Array(local.values.sorted().suffix(800))
            updates = try await client.fetchFlags(uids: recent)
        }
        if !updates.isEmpty {
            let byUID = Dictionary(updates.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
            let ids = local.filter { byUID[$0.value] != nil }.map(\.key)
            for var message in try database.messages(ids: ids) {
                guard let uid = message.uid, let update = byUID[uid] else { continue }
                let read = update.flags.contains("\\Seen")
                let flagged = update.flags.contains("\\Flagged")
                guard read != message.isRead || flagged != message.isFlagged else { continue }
                message.isRead = read
                message.isFlagged = flagged
                result.upserted.append(message)
            }
        }

        let lastUID = max(newUIDs.max() ?? 0, state?.lastUID ?? 0)
        try database.setSyncState(FolderSyncState(
            accountID: accountID, folder: folder, uidValidity: info.uidValidity,
            highestModSeq: info.highestModSeq, lastUID: lastUID
        ))
        return result
    }

    private static func gmailSkipInAllMail(_ labels: [String]) -> Bool {
        let skip: Set<String> = ["\\inbox", "\\sent", "\\draft", "\\trash", "\\spam", "\\junk"]
        return labels.contains { skip.contains($0.lowercased()) }
    }

    static func searchDate(_ date: Date) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let c = Calendar(identifier: .gregorian).dateComponents([.day, .month, .year], from: date)
        return "\(c.day ?? 1)-\(months[(c.month ?? 1) - 1])-\(c.year ?? 2000)"
    }

    private func makeMessage(_ s: IMAPMessageSummary, folder: String, uidValidity: UInt32, role: MailboxRole) -> Message {
        let env = s.envelope
        let from = env.from.first ?? Address(name: nil, email: "")
        let references = Self.messageIDs(in: s.headers["references"] ?? "")
        let messageIDHeader = env.messageID.map(Self.stripAngles)
        let inReplyTo = env.inReplyTo.flatMap { Self.messageIDs(in: $0).first }
        let threadKey: String
        if let thrid = s.gmailThreadID {
            threadKey = "g\(thrid)"
        } else {
            threadKey = "m" + (references.first ?? inReplyTo ?? messageIDHeader ?? "\(folder)-\(s.uid)")
        }
        // Заголовок целиком: UnsubscribeService сам выберет one-click, mailto или ссылку.
        let unsubscribe = s.headers["list-unsubscribe"].flatMap { $0.contains(":") ? $0 : nil }
        var message = Message(
            id: messageID(folder: folder, uidValidity: uidValidity, uid: s.uid),
            accountID: accountID,
            threadID: "\(accountID.uuidString)-\(threadKey)",
            role: role,
            from: from,
            to: env.to,
            cc: env.cc,
            subject: env.subject ?? "(без темы)",
            body: s.preview ?? "",
            date: env.date ?? s.internalDate ?? .now,
            isRead: s.flags.contains("\\Seen") || role == .sent || role == .drafts,
            isFlagged: s.flags.contains("\\Flagged")
        )
        message.folder = folder
        message.uid = s.uid
        message.headerMessageID = messageIDHeader
        message.inReplyToHeader = inReplyTo
        message.references = references.isEmpty ? nil : references
        message.listUnsubscribe = unsubscribe
        message.listUnsubscribePost = s.headers["list-unsubscribe-post"]?.lowercased().contains("one-click")
        message.labels = s.gmailLabels.isEmpty ? nil : s.gmailLabels
        message.bodyPending = true
        message.attachmentHint = s.hasAttachments
        return message
    }

    static func stripAngles(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    /// `<a@b> <c@d>` → ["a@b", "c@d"].
    static func messageIDs(in header: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inside = false
        for ch in header {
            if ch == "<" { inside = true; current = ""; continue }
            if ch == ">" {
                if inside && !current.isEmpty { result.append(current) }
                inside = false
                continue
            }
            if inside { current.append(ch) }
        }
        if result.isEmpty {
            let trimmed = stripAngles(header)
            if !trimmed.isEmpty && !trimmed.contains(" ") { result.append(trimmed) }
        }
        return result
    }

    static func pickUnsubscribe(_ header: String) -> String? {
        let items = header.components(separatedBy: ",").map(stripAngles).filter { !$0.isEmpty }
        return items.first { $0.lowercased().hasPrefix("https:") } ?? items.first { $0.lowercased().hasPrefix("mailto:") }
    }

    // MARK: - Действия

    func apply(_ action: MailAction) async throws {
        let byFolder = Dictionary(grouping: action.ids.compactMap { Self.location(of: $0) }, by: \.folder)
        for (folder, locations) in byFolder {
            let uids = locations.map(\.uid)
            try await exclusive { client in
                try await loadFolders(client)
                _ = try await client.select(folder, readOnly: false)
                switch action {
                case .markRead(_, let read):
                    try await client.store(uids: uids, flags: ["\\Seen"], add: read)
                case .flag(_, let flagged):
                    try await client.store(uids: uids, flags: ["\\Flagged"], add: flagged)
                case .move(_, let role):
                    guard let target = roleFolders[role], target != folder else { return }
                    try await client.move(uids: uids, to: target)
                case .deletePermanently:
                    try await client.store(uids: uids, flags: ["\\Deleted"], add: true)
                    try await client.expunge(uids: uids)
                case .snooze:
                    // «Отложить» живёт локально: на сервере письмо остаётся во «Входящих».
                    break
                }
            }
        }
    }

    // MARK: - Тело письма

    func fetchContent(for message: Message) async throws -> MessageContent {
        guard let location = Self.location(of: message.id) else { throw MailProviderError.notFound }
        let raw = try await exclusive { client -> Data in
            _ = try await client.select(location.folder, readOnly: true)
            return try await client.fetchMessage(uid: location.uid)
        }
        guard !raw.isEmpty else { throw MailProviderError.notFound }
        return content(from: MIMEParser.parse(raw), messageID: message.id)
    }

    /// Разбор MIME → содержимое для экрана чтения. Вложения сохраняются в кэш, встроенные картинки
    /// подставляются в HTML как data:-URI (WKWebView с CSP не ходит за cid: и file:).
    func content(from parsed: ParsedMessage, messageID: String) -> MessageContent {
        let folder = cacheDirectory
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.safeFileName(messageID), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var html = parsed.htmlBody
        var attachments: [Attachment] = []
        for part in parsed.attachments {
            if part.isInline, let cid = part.contentID, var current = html, part.data.count < 3_000_000,
               part.mimeType.lowercased().hasPrefix("image/") {
                let uri = "data:\(part.mimeType);base64,\(part.data.base64EncodedString())"
                current = current.replacingOccurrences(of: "cid:\(cid)", with: uri)
                html = current
                continue
            }
            let name = part.filename.isEmpty ? "вложение-\(part.partID)" : part.filename
            let url = folder.appendingPathComponent(Self.safeFileName(name))
            try? part.data.write(to: url, options: .atomic)
            attachments.append(Attachment(
                filename: name, size: part.data.count, mimeType: part.mimeType,
                partID: part.partID, contentID: part.contentID, localPath: url.path
            ))
        }

        var invite: Invite?
        if let ics = parsed.calendar, let event = ICSParser.parse(ics).first,
           (event.method ?? "REQUEST").uppercased() != "CANCEL" {
            invite = Invite(title: event.summary, start: event.start, end: event.end,
                            location: event.location ?? "", organizer: event.organizer, ics: ics)
        }

        let text = parsed.textBody ?? html.map { MailFTS.plainText(fromHTML: $0) }
        return MessageContent(
            text: text, html: html, attachments: attachments, invite: invite,
            listUnsubscribe: parsed.listUnsubscribe, listUnsubscribePost: parsed.listUnsubscribePost,
            references: parsed.references, inReplyTo: parsed.inReplyTo, messageID: parsed.messageID
        )
    }

    static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
        return String(cleaned.prefix(120))
    }

    func rawSource(for message: Message) async throws -> Data {
        guard let location = Self.location(of: message.id) else { throw MailProviderError.notFound }
        return try await exclusive { client in
            _ = try await client.select(location.folder, readOnly: true)
            return try await client.fetchMessage(uid: location.uid)
        }
    }

    // MARK: - Поиск на сервере

    func serverSearch(_ query: String) async throws -> [Message] {
        let q = query.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        try await exclusive { client in try await loadFolders(client) }
        var found: [Message] = []
        for role in [MailboxRole.inbox, .archive, .sent] {
            guard let folder = roleFolders[role] else { continue }
            let part = try await exclusive { client -> [Message] in
                let info = try await client.select(folder, readOnly: true)
                let criteria = isGmail ? "X-GM-RAW \"\(q)\"" : "TEXT \"\(q)\""
                let uids = Array(try await client.uidSearch(criteria).sorted().suffix(40))
                guard !uids.isEmpty else { return [] }
                return try await client.fetchSummaries(uids: uids, includePreview: true).map {
                    makeMessage($0, folder: folder, uidValidity: info.uidValidity, role: role)
                }
            }
            found += part
        }
        return found
    }

    // MARK: - IDLE

    func waitForChanges(timeout: TimeInterval) async throws -> Bool {
        if idleClient == nil {
            let fresh = try await connect(readTimeout: timeout + 120)
            _ = try await fresh.select("INBOX", readOnly: true)
            idleClient = fresh
        }
        guard let idleClient else { return false }
        do {
            return try await idleClient.idle(timeout: timeout)
        } catch {
            await idleClient.logout()
            self.idleClient = nil
            throw error
        }
    }

    // MARK: - Отправка

    func send(_ outgoing: OutgoingMessage) async throws -> Message {
        guard let password = password(), !password.isEmpty else { throw MailProviderError.missingPassword }
        let from = Address(name: account.senderName, email: outgoing.fromAddress)
        let domain = outgoing.fromAddress.split(separator: "@").last.map(String.init) ?? "unimail.local"
        var attachments: [OutgoingAttachment] = []
        for url in outgoing.attachmentURLs {
            let data = try Data(contentsOf: url)
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent,
                                                  mimeType: Self.mimeType(for: url), data: data))
        }
        let html = outgoing.htmlBody.map {
            "<!doctype html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">\($0)</body></html>"
        }

        func mime(to: [Address], cc: [Address], bcc: [Address]) -> (OutgoingMIME, String) {
            let id = MIMEBuilder.makeMessageID(domain: domain)
            var m = OutgoingMIME(from: from, to: to, subject: outgoing.subject, textBody: outgoing.body, messageID: id)
            m.cc = cc
            m.bcc = bcc
            m.htmlBody = html
            m.attachments = attachments
            m.inReplyTo = outgoing.inReplyToHeader
            m.references = outgoing.referenceHeaders ?? []
            m.extraHeaders = [("X-Mailer", "UniMail for macOS")]
            if let ics = outgoing.calendarReply { m.calendar = ("REPLY", ics) }
            return (m, id)
        }

        var batches: [(OutgoingMIME, String)] = []
        if outgoing.sendSeparately && outgoing.to.count > 1 {
            batches = outgoing.to.map { mime(to: [$0], cc: [], bcc: []) }
        } else {
            batches = [mime(to: outgoing.to, cc: outgoing.cc, bcc: outgoing.bcc)]
        }

        var lastID = ""
        var lastData = Data()
        for (message, id) in batches {
            let data = MIMEBuilder.build(message)
            let recipients = (message.to + message.cc + message.bcc).map(\.email)
            try await smtpSend(from: outgoing.fromAddress, recipients: recipients, data: data, password: password)
            lastID = id
            lastData = data
        }

        // Gmail сам кладёт копию в «Отправленные»; остальным серверам — APPEND.
        if !isGmail, let sent = try? await sentFolder() {
            _ = try? await exclusive { client in
                try await client.append(folder: sent, message: lastData, flags: ["\\Seen"], date: .now)
            }
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
        result.headerMessageID = Self.stripAngles(lastID)
        result.attachmentHint = !attachments.isEmpty
        return result
    }

    private func sentFolder() async throws -> String? {
        try await exclusive { client in
            try await loadFolders(client)
            return roleFolders[.sent]
        }
    }

    private func smtpSend(from: String, recipients: [String], data: Data, password: String) async throws {
        let security = server.smtpSecurity ?? (server.smtpPort == 465 ? .tls : .starttls)
        let transport: MailTransport
        do {
            transport = try await transportFactory(server.smtpHost, server.smtpPort, security == .tls, 120)
        } catch {
            throw MailProviderError.network(error.localizedDescription)
        }
        defer { transport.close() }
        let smtp = SMTPClient(transport: transport, heloName: "unimail.local")
        do {
            try await smtp.connect()
            let caps = try await smtp.ehlo()
            if security == .starttls {
                guard caps.contains("STARTTLS") else { throw MailProviderError.network("сервер SMTP не поддерживает STARTTLS") }
                try await smtp.startTLS()
            }
            try await smtp.authenticate(username: server.username.isEmpty ? account.email : server.username, password: password)
            try await smtp.send(from: from, recipients: recipients, data: data)
            await smtp.quit()
        } catch let error as SMTPError {
            if case .authenticationFailed = error { throw MailProviderError.authenticationFailed }
            throw error
        }
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        case "zip": return "application/zip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "key": return "application/vnd.apple.keynote"
        case "ics": return "text/calendar"
        case "eml": return "message/rfc822"
        case "csv": return "text/csv"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Проверка и отключение

    func verifyLogin() async throws {
        let client = try await connect(readTimeout: 60)
        _ = try await client.listFolders()
        await client.logout()
        guard let password = password() else { throw MailProviderError.missingPassword }
        // SMTP: только вход, без отправки.
        let security = server.smtpSecurity ?? (server.smtpPort == 465 ? .tls : .starttls)
        let transport = try await transportFactory(server.smtpHost, server.smtpPort, security == .tls, 60)
        defer { transport.close() }
        let smtp = SMTPClient(transport: transport, heloName: "unimail.local")
        do {
            try await smtp.connect()
            let caps = try await smtp.ehlo()
            if security == .starttls && caps.contains("STARTTLS") { try await smtp.startTLS() }
            try await smtp.authenticate(username: server.username.isEmpty ? account.email : server.username, password: password)
            await smtp.quit()
        } catch let error as SMTPError {
            if case .authenticationFailed = error { throw MailProviderError.authenticationFailed }
            throw error
        }
    }

    func disconnect() async {
        await client?.logout()
        client = nil
        await idleClient?.stopIdle()
        await idleClient?.logout()
        idleClient = nil
    }
}
