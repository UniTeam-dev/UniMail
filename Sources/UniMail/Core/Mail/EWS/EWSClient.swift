import Foundation

/// POST одного SOAP-запроса на адрес EWS. Возвращает HTTP-статус и тело.
/// На macOS — `EWSHTTPTransport` (URLSession, вход Basic/NTLM/Kerberos), в проверках — фейковый сервер.
typealias EWSPost = @Sendable (_ body: Data) async throws -> (status: Int, body: Data)

enum EWSError: LocalizedError, Equatable {
    /// Вход не принят; в тексте — какие способы пробовали.
    case unauthorized(String)
    case http(Int)
    case fault(String)
    case response(code: String, message: String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .unauthorized(let detail): "Exchange не принял логин или пароль (\(detail))."
        case .http(let code): "Сервер Exchange ответил HTTP \(code)."
        case .fault(let text): "Ошибка Exchange: \(text)"
        case .response(let code, let message): message.isEmpty ? "Ошибка Exchange: \(code)" : "Ошибка Exchange (\(code)): \(message)"
        case .malformed: "Непонятный ответ сервера Exchange."
        }
    }
}

/// Папка: стандартная (inbox, sentitems, deleteditems, junkemail, drafts, msgfolderroot) или по id.
enum EWSFolderRef: Sendable, Hashable {
    case distinguished(String)
    case id(String)

    var xml: String {
        switch self {
        case .distinguished(let name): "<t:DistinguishedFolderId Id=\"\(name)\"/>"
        case .id(let id): "<t:FolderId Id=\"\(XMLTree.escape(id))\"/>"
        }
    }
}

struct EWSFolder: Sendable, Hashable {
    var id: String
    var name: String
}

/// Папка из полного дерева ящика (FindFolder Deep).
struct EWSFolderInfo: Sendable, Hashable {
    var id: String
    var name: String
    var parentID: String?
    var folderClass: String?
    var unread: Int?
    var total: Int?
}

/// Правило «Входящих» с сервера (GetInboxRules).
struct EWSRule: Sendable, Hashable {
    var id: String
    var name: String
    var isEnabled: Bool
    var priority: Int
    var conditions: [String]
    var actions: [String]
    /// Папки из действий «переместить/скопировать» — названия подставит провайдер.
    var folderIDs: [String]
}

struct EWSMailbox: Sendable, Hashable {
    var name: String?
    var email: String
    var routingType: String?

    /// Внутренний адрес Exchange (/O=…/CN=…) вместо SMTP.
    var isExchangeLegacy: Bool { routingType?.uppercased() == "EX" || (!email.contains("@") && email.hasPrefix("/")) }
}

struct EWSItem: Sendable {
    var id: String
    var changeKey: String?
    var itemClass: String?
    var subject: String?
    var received: Date?
    var sent: Date?
    var from: EWSMailbox?
    var to: [EWSMailbox] = []
    var cc: [EWSMailbox] = []
    var isRead: Bool?
    var hasAttachments: Bool?
    var flagged: Bool?
    var conversationID: String?
    var internetMessageID: String?
    /// Заголовки письма (ключи в нижнем регистре).
    var headers: [String: String] = [:]
    var preview: String?
    var references: String?
    var inReplyTo: String?
    var mime: Data?
}

/// Клиент Exchange Web Services (Exchange 2013+): папки, поиск писем, свойства, MIME, флаги, перемещение, отправка.
struct EWSClient: Sendable {
    let post: EWSPost

    init(post: @escaping EWSPost) {
        self.post = post
    }

    // MARK: Конверт

    static func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
        <soap:Header><t:RequestServerVersion Version="Exchange2013_SP1"/></soap:Header>
        <soap:Body>\(body)</soap:Body>
        </soap:Envelope>
        """
    }

    /// Выполнить запрос и вернуть элемент `Body` ответа.
    func call(_ body: String) async throws -> XNode {
        let (status, data) = try await post(Data(Self.envelope(body).utf8))
        if status == 401 || status == 403 { throw EWSError.unauthorized("HTTP \(status)") }
        let root = XMLTree.parse(data)
        if let fault = root?.firstDescendant("Fault") {
            let text = fault.value("faultstring") ?? fault.firstDescendant("Message")?.text ?? "SOAP Fault"
            throw EWSError.fault(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard (200..<300).contains(status) else { throw EWSError.http(status) }
        guard let body = root?.firstDescendant("Body") else { throw EWSError.malformed }
        return body
    }

    /// Ответные сообщения (`…ResponseMessage`) в порядке запроса.
    static func responseMessages(_ body: XNode) -> [XNode] {
        body.descendants("ResponseMessages").first?.children ?? []
    }

    static func check(_ message: XNode) throws {
        guard message.attributes["ResponseClass"] == "Error" else { return }
        throw EWSError.response(code: message.value("ResponseCode") ?? "Error",
                                message: message.value("MessageText") ?? "")
    }

    /// Все ответы успешны (одиночные операции).
    @discardableResult
    func callChecked(_ body: String) async throws -> [XNode] {
        let messages = Self.responseMessages(try await call(body))
        for message in messages { try Self.check(message) }
        return messages
    }

    // MARK: Папки

    func getFolder(_ ref: EWSFolderRef) async throws -> EWSFolder {
        let messages = try await callChecked("""
        <m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties><t:FieldURI FieldURI="folder:DisplayName"/></t:AdditionalProperties></m:FolderShape>\
        <m:FolderIds>\(ref.xml)</m:FolderIds></m:GetFolder>
        """)
        guard let folder = messages.first?.firstDescendant("FolderId").flatMap({ $0.attributes["Id"] }) else {
            throw EWSError.malformed
        }
        return EWSFolder(id: folder, name: messages.first?.firstDescendant("DisplayName")?.text ?? "")
    }

    func findFolders(parent: EWSFolderRef) async throws -> [EWSFolder] {
        let messages = try await callChecked("""
        <m:FindFolder Traversal="Shallow"><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties><t:FieldURI FieldURI="folder:DisplayName"/></t:AdditionalProperties></m:FolderShape>\
        <m:ParentFolderIds>\(parent.xml)</m:ParentFolderIds></m:FindFolder>
        """)
        return (messages.first?.descendants("Folder") ?? []).compactMap { node in
            guard let id = node.child("FolderId")?.attributes["Id"] else { return nil }
            return EWSFolder(id: id, name: node.value("DisplayName") ?? "")
        }
    }

    func createFolder(name: String, parent: EWSFolderRef) async throws -> EWSFolder {
        let messages = try await callChecked("""
        <m:CreateFolder><m:ParentFolderId>\(parent.xml)</m:ParentFolderId>\
        <m:Folders><t:Folder><t:DisplayName>\(XMLTree.escape(name))</t:DisplayName></t:Folder></m:Folders></m:CreateFolder>
        """)
        guard let id = messages.first?.firstDescendant("FolderId")?.attributes["Id"] else { throw EWSError.malformed }
        return EWSFolder(id: id, name: name)
    }

    /// Всё дерево папок ящика (почтовые и прочие — фильтрует вызывающий).
    func findAllFolders() async throws -> [EWSFolderInfo] {
        let messages = try await callChecked("""
        <m:FindFolder Traversal="Deep"><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties><t:FieldURI FieldURI="folder:DisplayName"/><t:FieldURI FieldURI="folder:ParentFolderId"/>\
        <t:FieldURI FieldURI="folder:FolderClass"/><t:FieldURI FieldURI="folder:UnreadCount"/>\
        <t:FieldURI FieldURI="folder:TotalCount"/></t:AdditionalProperties></m:FolderShape>\
        <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds></m:FindFolder>
        """)
        guard let folders = messages.first?.firstDescendant("Folders") else { return [] }
        return folders.children.compactMap { node in
            guard let id = node.child("FolderId")?.attributes["Id"] else { return nil }
            return EWSFolderInfo(
                id: id,
                name: node.value("DisplayName") ?? "",
                parentID: node.child("ParentFolderId")?.attributes["Id"],
                folderClass: node.name == "Folder" ? (node.value("FolderClass") ?? "IPF.Note") : node.name,
                unread: node.value("UnreadCount").flatMap { Int($0) },
                total: node.value("TotalCount").flatMap { Int($0) }
            )
        }
    }

    /// Id стандартных папок (inbox, sentitems…) — чтобы не показывать их среди своих.
    func distinguishedFolderIDs(_ names: [String]) async throws -> [String: String] {
        let ids = names.map { "<t:DistinguishedFolderId Id=\"\($0)\"/>" }.joined()
        let body = try await call("""
        <m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape>\
        <m:FolderIds>\(ids)</m:FolderIds></m:GetFolder>
        """)
        var result: [String: String] = [:]
        for (name, message) in zip(names, Self.responseMessages(body)) where message.attributes["ResponseClass"] != "Error" {
            if let id = message.firstDescendant("FolderId")?.attributes["Id"] { result[name] = id }
        }
        return result
    }

    /// Правила «Входящих» (работают на сервере).
    func inboxRules(mailbox: String) async throws -> [EWSRule] {
        let body = try await call("""
        <m:GetInboxRules><m:MailboxSmtpAddress>\(XMLTree.escape(mailbox))</m:MailboxSmtpAddress></m:GetInboxRules>
        """)
        guard let response = body.firstDescendant("GetInboxRulesResponse") else { throw EWSError.malformed }
        try Self.check(response)
        return (response.child("InboxRules")?.children("Rule") ?? []).map(Self.rule)
    }

    static func rule(_ node: XNode) -> EWSRule {
        var conditions: [String] = []
        var actions: [String] = []
        var folderIDs: [String] = []
        func strings(_ element: XNode?) -> [String] {
            (element?.children ?? []).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        func addresses(_ element: XNode?) -> [String] {
            // В правилах адреса — <t:Address> (EmailAddressType), в письмах — <t:Mailbox>.
            (element?.children ?? []).map { mailbox($0) }.map { $0.email.isEmpty ? ($0.name ?? "") : $0.email }.filter { !$0.isEmpty }
        }
        func quoted(_ list: [String]) -> String { list.map { "«\($0)»" }.joined(separator: " или ") }

        if let c = node.child("Conditions") {
            if let v = Optional(addresses(c.child("FromAddresses"))), !v.isEmpty { conditions.append("от \(v.joined(separator: ", "))") }
            if let v = Optional(addresses(c.child("SentToAddresses"))), !v.isEmpty { conditions.append("кому \(v.joined(separator: ", "))") }
            if let v = Optional(strings(c.child("ContainsSubjectStrings"))), !v.isEmpty { conditions.append("тема содержит \(quoted(v))") }
            if let v = Optional(strings(c.child("ContainsSubjectOrBodyStrings"))), !v.isEmpty { conditions.append("тема или текст содержит \(quoted(v))") }
            if let v = Optional(strings(c.child("ContainsBodyStrings"))), !v.isEmpty { conditions.append("текст содержит \(quoted(v))") }
            if let v = Optional(strings(c.child("ContainsSenderStrings"))), !v.isEmpty { conditions.append("отправитель содержит \(quoted(v))") }
            if let v = Optional(strings(c.child("ContainsRecipientStrings"))), !v.isEmpty { conditions.append("получатель содержит \(quoted(v))") }
            if let v = Optional(strings(c.child("ContainsHeaderStrings"))), !v.isEmpty { conditions.append("заголовки содержат \(quoted(v))") }
            if c.value("SentToMe") == "true" { conditions.append("я в «Кому»") }
            if c.value("SentCcMe") == "true" { conditions.append("я в копии") }
            if c.value("SentOnlyToMe") == "true" { conditions.append("только мне") }
            if c.value("HasAttachments") == "true" { conditions.append("есть вложения") }
            if let importance = c.value("Importance") { conditions.append("важность: \(importance)") }
            if !strings(c.child("Categories")).isEmpty { conditions.append("категория \(quoted(strings(c.child("Categories"))))") }
        }
        if let a = node.child("Actions") {
            if let id = a["MoveToFolder", "FolderId"]?.attributes["Id"] { actions.append("переместить в папку {\(id)}"); folderIDs.append(id) }
            if let id = a["CopyToFolder", "FolderId"]?.attributes["Id"] { actions.append("скопировать в папку {\(id)}"); folderIDs.append(id) }
            if a.value("MarkAsRead") == "true" { actions.append("отметить прочитанным") }
            if a.value("Delete") == "true" { actions.append("удалить") }
            if a.value("PermanentDelete") == "true" { actions.append("удалить навсегда") }
            if let v = Optional(strings(a.child("AssignCategories"))), !v.isEmpty { actions.append("категория \(quoted(v))") }
            if let importance = a.value("MarkImportance") { actions.append("важность: \(importance)") }
            if let v = Optional(addresses(a.child("ForwardToRecipients"))), !v.isEmpty { actions.append("переслать \(v.joined(separator: ", "))") }
            if let v = Optional(addresses(a.child("RedirectToRecipients"))), !v.isEmpty { actions.append("перенаправить \(v.joined(separator: ", "))") }
            if a.value("StopProcessingRules") == "true" { actions.append("не применять следующие правила") }
        }
        return EWSRule(id: node.value("RuleId") ?? UUID().uuidString,
                       name: node.value("DisplayName") ?? "Правило",
                       isEnabled: node.value("IsEnabled") != "false",
                       priority: node.value("Priority").flatMap { Int($0) } ?? 0,
                       conditions: conditions, actions: actions, folderIDs: folderIDs)
    }

    // MARK: Письма

    static let summaryFields = [
        "item:Subject", "item:DateTimeReceived", "message:From", "message:IsRead",
        "item:HasAttachments", "item:Flag", "item:ConversationId", "item:ItemClass",
    ]

    static let detailFields = [
        "item:Subject", "item:DateTimeReceived", "item:DateTimeSent", "item:ItemClass",
        "message:From", "message:ToRecipients", "message:CcRecipients", "message:IsRead",
        "item:HasAttachments", "item:Flag", "item:ConversationId", "message:InternetMessageId",
        "item:InternetMessageHeaders", "item:Preview", "message:References", "item:InReplyTo",
    ]

    static func fieldsXML(_ fields: [String]) -> String {
        fields.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()
    }

    /// Письма папки: новые сверху, не старше `since`, не больше `max`. Либо поиск по `query` (AQS).
    /// `complete` — сервер вернул всё, что подходит под условие.
    func findItems(in folder: EWSFolderRef, since: Date?, max: Int, query: String? = nil) async throws -> (items: [EWSItem], complete: Bool) {
        var restriction = ""
        if let since, query == nil {
            restriction = """
            <m:Restriction><t:IsGreaterThanOrEqualTo><t:FieldURI FieldURI="item:DateTimeReceived"/>\
            <t:FieldURIOrConstant><t:Constant Value="\(Self.formatDate(since))"/></t:FieldURIOrConstant>\
            </t:IsGreaterThanOrEqualTo></m:Restriction>
            """
        }
        let queryXML = query.map { "<m:QueryString>\(XMLTree.escape($0))</m:QueryString>" } ?? ""
        let messages = try await callChecked("""
        <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties>\(Self.fieldsXML(Self.summaryFields))</t:AdditionalProperties></m:ItemShape>\
        <m:IndexedPageItemView MaxEntriesReturned="\(max)" Offset="0" BasePoint="Beginning"/>\
        \(restriction)\
        <m:SortOrder><t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder></m:SortOrder>\
        <m:ParentFolderIds>\(folder.xml)</m:ParentFolderIds>\(queryXML)</m:FindItem>
        """)
        guard let root = messages.first?.child("RootFolder") else { throw EWSError.malformed }
        let items = (root.child("Items")?.children ?? []).compactMap(Self.item)
        let complete = root.attributes["IncludesLastItemInRange"].map { $0.lowercased() == "true" } ?? true
        return (items, complete)
    }

    /// Полные свойства писем (адреса, заголовки, превью). Письма с ошибкой пропускаются.
    func getItems(ids: [String]) async throws -> [EWSItem] {
        var result: [EWSItem] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = ids[start..<min(start + 50, ids.count)]
            let body = try await call("""
            <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
            <t:AdditionalProperties>\(Self.fieldsXML(Self.detailFields))</t:AdditionalProperties></m:ItemShape>\
            <m:ItemIds>\(Self.itemIdsXML(Array(chunk)))</m:ItemIds></m:GetItem>
            """)
            for message in Self.responseMessages(body) where message.attributes["ResponseClass"] != "Error" {
                result += (message.child("Items")?.children ?? []).compactMap(Self.item)
            }
        }
        return result
    }

    /// Исходник письма (RFC 822) — для тела, вложений и .eml.
    func getMime(id: String) async throws -> Data {
        let messages = try await callChecked("""
        <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:IncludeMimeContent>true</t:IncludeMimeContent></m:ItemShape>\
        <m:ItemIds>\(Self.itemIdsXML([id]))</m:ItemIds></m:GetItem>
        """)
        guard let text = messages.first?.firstDescendant("MimeContent")?.text,
              let data = Data(base64Encoded: text.filter { !$0.isWhitespace }) else { throw EWSError.malformed }
        return data
    }

    static func itemIdsXML(_ ids: [String]) -> String {
        ids.map { "<t:ItemId Id=\"\(XMLTree.escape($0))\"/>" }.joined()
    }

    // MARK: Действия

    func setRead(ids: [String], read: Bool) async throws {
        try await update(ids: ids, field: "message:IsRead", value: "<t:Message><t:IsRead>\(read)</t:IsRead></t:Message>")
    }

    func setFlag(ids: [String], flagged: Bool) async throws {
        let status = flagged ? "Flagged" : "NotFlagged"
        try await update(ids: ids, field: "item:Flag",
                         value: "<t:Message><t:Flag><t:FlagStatus>\(status)</t:FlagStatus></t:Flag></t:Message>")
    }

    private func update(ids: [String], field: String, value: String) async throws {
        guard !ids.isEmpty else { return }
        let changes = ids.map { id in
            "<t:ItemChange><t:ItemId Id=\"\(XMLTree.escape(id))\"/><t:Updates><t:SetItemField>" +
                "<t:FieldURI FieldURI=\"\(field)\"/>\(value)</t:SetItemField></t:Updates></t:ItemChange>"
        }.joined()
        try await callChecked("""
        <m:UpdateItem MessageDisposition="SaveOnly" ConflictResolution="AlwaysOverwrite" SuppressReadReceipts="true">\
        <m:ItemChanges>\(changes)</m:ItemChanges></m:UpdateItem>
        """)
    }

    func move(ids: [String], to folder: EWSFolderRef) async throws {
        guard !ids.isEmpty else { return }
        try await callChecked("""
        <m:MoveItem><m:ToFolderId>\(folder.xml)</m:ToFolderId><m:ItemIds>\(Self.itemIdsXML(ids))</m:ItemIds></m:MoveItem>
        """)
    }

    func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await callChecked("""
        <m:DeleteItem DeleteType="HardDelete"><m:ItemIds>\(Self.itemIdsXML(ids))</m:ItemIds></m:DeleteItem>
        """)
    }

    /// Отправить готовое письмо (MIME) с копией в «Отправленных». Скрытые получатели — отдельно:
    /// в MIME их нет.
    func send(mime: Data, bcc: [String]) async throws {
        let bccXML = bcc.isEmpty ? "" : "<t:BccRecipients>" + bcc.map {
            "<t:Mailbox><t:EmailAddress>\(XMLTree.escape($0))</t:EmailAddress></t:Mailbox>"
        }.joined() + "</t:BccRecipients>"
        try await callChecked("""
        <m:CreateItem MessageDisposition="SendAndSaveCopy">\
        <m:SavedItemFolderId><t:DistinguishedFolderId Id="sentitems"/></m:SavedItemFolderId>\
        <m:Items><t:Message><t:MimeContent CharacterSet="UTF-8">\(mime.base64EncodedString())</t:MimeContent>\(bccXML)</t:Message></m:Items>\
        </m:CreateItem>
        """)
    }

    /// SMTP-адрес по внутреннему адресу Exchange (/O=…/CN=…).
    func resolve(_ legacy: String) async throws -> EWSMailbox? {
        let body = try await call("""
        <m:ResolveNames ReturnFullContactData="false" SearchScope="ActiveDirectory">\
        <m:UnresolvedEntry>\(XMLTree.escape(legacy))</m:UnresolvedEntry></m:ResolveNames>
        """)
        guard let message = Self.responseMessages(body).first,
              message.attributes["ResponseClass"] != "Error" || message.value("ResponseCode") == "ErrorNameResolutionMultipleResults",
              let mailbox = message.firstDescendant("Mailbox") else { return nil }
        return Self.mailbox(mailbox)
    }

    // MARK: Разбор

    static func item(_ node: XNode) -> EWSItem? {
        guard let idNode = node.child("ItemId"), let id = idNode.attributes["Id"] else { return nil }
        var item = EWSItem(id: id, changeKey: idNode.attributes["ChangeKey"])
        item.itemClass = node.value("ItemClass")
        item.subject = node.value("Subject")
        item.received = node.value("DateTimeReceived").flatMap(parseDate)
        item.sent = node.value("DateTimeSent").flatMap(parseDate)
        item.from = node["From", "Mailbox"].map(mailbox)
        item.to = node.child("ToRecipients")?.children("Mailbox").map(mailbox) ?? []
        item.cc = node.child("CcRecipients")?.children("Mailbox").map(mailbox) ?? []
        item.isRead = node.value("IsRead").map { $0.lowercased() == "true" }
        item.hasAttachments = node.value("HasAttachments").map { $0.lowercased() == "true" }
        if let status = node.value("Flag", "FlagStatus") { item.flagged = status == "Flagged" }
        item.conversationID = node.child("ConversationId")?.attributes["Id"]
        item.internetMessageID = node.value("InternetMessageId")
        for header in node.child("InternetMessageHeaders")?.children("InternetMessageHeader") ?? [] {
            guard let name = header.attributes["HeaderName"]?.lowercased() else { continue }
            let value = header.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = item.headers[name] { item.headers[name] = existing + ", " + value } else { item.headers[name] = value }
        }
        item.preview = node.value("Preview")
        item.references = node.value("References")
        item.inReplyTo = node.value("InReplyTo")
        return item
    }

    static func mailbox(_ node: XNode) -> EWSMailbox {
        let name = node.value("Name")
        return EWSMailbox(name: (name?.isEmpty ?? true) ? nil : name,
                          email: node.value("EmailAddress") ?? "",
                          routingType: node.value("RoutingType"))
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
