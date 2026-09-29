import Foundation

/// Встреча календаря Exchange.
struct EWSCalendarItem: Sendable, Hashable {
    var id: String
    var changeKey: String?
    var subject: String
    var start: Date
    var end: Date
    var isAllDay = false
    var location: String?
    var organizer: EWSMailbox?
    /// Accept, Tentative, Decline, NoResponseReceived, Organizer, Unknown.
    var myResponse: String?
    var isMeeting = false
    var isCancelled = false
    var isRecurring = false
    var body: String?
    var required: [(EWSMailbox, String?)] = []
    var optional: [(EWSMailbox, String?)] = []

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.changeKey == b.changeKey }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(changeKey) }
}

/// Ответ на приглашение в EWS.
enum EWSMeetingResponse: String, Sendable {
    case accept = "AcceptItem"
    case tentative = "TentativelyAcceptItem"
    case decline = "DeclineItem"
}

/// Календарь Exchange: встречи за период, подробности, создание, изменение, удаление, ответы на приглашения.
extension EWSClient {
    static let calendarSummaryFields = [
        "item:Subject", "calendar:Start", "calendar:End", "calendar:IsAllDayEvent", "calendar:Location",
        "calendar:Organizer", "calendar:MyResponseType", "calendar:IsMeeting", "calendar:IsCancelled",
        "calendar:IsRecurring",
    ]

    /// Встречи в интервале (повторяющиеся развёрнуты сервером — CalendarView).
    func calendarView(from start: Date, to end: Date, max: Int = 500) async throws -> [EWSCalendarItem] {
        let fields = Self.calendarSummaryFields.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()
        let messages = try await callChecked("""
        <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties>\(fields)</t:AdditionalProperties></m:ItemShape>\
        <m:CalendarView MaxEntriesReturned="\(max)" StartDate="\(Self.formatDate(start))" EndDate="\(Self.formatDate(end))"/>\
        <m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/></m:ParentFolderIds></m:FindItem>
        """)
        return (messages.first?.descendants("CalendarItem") ?? []).compactMap(Self.calendarItem)
    }

    /// Встречи календаря по теме — одиночные и повторяющиеся серии целиком (без развёртки по дням).
    /// Нужны, когда встречу видно в Календаре macOS, а в CalendarView сервер её не отдал.
    func findCalendarItems(subject: String, max: Int = 20) async throws -> [EWSCalendarItem] {
        let fields = Self.calendarSummaryFields.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()
        let messages = try await callChecked("""
        <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties>\(fields)</t:AdditionalProperties></m:ItemShape>\
        <m:IndexedPageItemView MaxEntriesReturned="\(max)" Offset="0" BasePoint="Beginning"/>\
        <m:Restriction>\(Self.subjectRestriction(subject, mode: "Substring"))</m:Restriction>\
        <m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/></m:ParentFolderIds></m:FindItem>
        """)
        return (messages.first?.descendants("CalendarItem") ?? []).compactMap(Self.calendarItem)
    }

    /// Приглашения (MeetingRequest) во «Входящих» по теме — на них тоже можно ответить.
    func findMeetingRequests(subject: String, max: Int = 10) async throws -> [(id: String, subject: String)] {
        let messages = try await callChecked("""
        <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties><t:FieldURI FieldURI="item:Subject"/><t:FieldURI FieldURI="item:ItemClass"/></t:AdditionalProperties></m:ItemShape>\
        <m:IndexedPageItemView MaxEntriesReturned="\(max)" Offset="0" BasePoint="Beginning"/>\
        <m:Restriction>\(Self.subjectRestriction(subject, mode: "Substring"))</m:Restriction>\
        <m:ParentFolderIds><t:DistinguishedFolderId Id="inbox"/></m:ParentFolderIds></m:FindItem>
        """)
        let items = messages.first?["RootFolder", "Items"]?.children ?? []
        return items.compactMap { node in
            guard let id = node.child("ItemId")?.attributes["Id"],
                  node.name == "MeetingRequest" || (node.value("ItemClass") ?? "").hasPrefix("IPM.Schedule.Meeting.Request")
            else { return nil }
            return (id, node.value("Subject") ?? "")
        }
    }

    static func subjectRestriction(_ subject: String, mode: String = "FullString") -> String {
        "<t:Contains ContainmentMode=\"\(mode)\" ContainmentComparison=\"IgnoreCase\"><t:FieldURI FieldURI=\"item:Subject\"/>"
            + "<t:Constant Value=\"\(XMLTree.escape(subject))\"/></t:Contains>"
    }

    /// Подробности: участники и описание (текстом).
    func calendarDetails(ids: [String]) async throws -> [EWSCalendarItem] {
        guard !ids.isEmpty else { return [] }
        let fields = (Self.calendarSummaryFields + ["item:Body", "calendar:RequiredAttendees", "calendar:OptionalAttendees"])
            .map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()
        let body = try await call("""
        <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:BodyType>Text</t:BodyType>\
        <t:AdditionalProperties>\(fields)</t:AdditionalProperties></m:ItemShape>\
        <m:ItemIds>\(Self.itemIdsXML(ids))</m:ItemIds></m:GetItem>
        """)
        return Self.responseMessages(body)
            .filter { $0.attributes["ResponseClass"] != "Error" }
            .compactMap { $0.firstDescendant("CalendarItem").flatMap(Self.calendarItem) }
    }

    static func calendarItem(_ node: XNode) -> EWSCalendarItem? {
        guard let idNode = node.child("ItemId"), let id = idNode.attributes["Id"],
              let start = node.value("Start").flatMap(parseDate),
              let end = node.value("End").flatMap(parseDate) else { return nil }
        var item = EWSCalendarItem(id: id, changeKey: idNode.attributes["ChangeKey"],
                                   subject: node.value("Subject") ?? "", start: start, end: end)
        item.isAllDay = node.value("IsAllDayEvent") == "true"
        item.location = node.value("Location").flatMap { $0.isEmpty ? nil : $0 }
        item.organizer = node["Organizer", "Mailbox"].map(mailbox)
        item.myResponse = node.value("MyResponseType")
        item.isMeeting = node.value("IsMeeting") == "true"
        item.isCancelled = node.value("IsCancelled") == "true"
        item.isRecurring = node.value("IsRecurring") == "true"
        item.body = node.child("Body")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        func attendees(_ name: String) -> [(EWSMailbox, String?)] {
            (node.child(name)?.children("Attendee") ?? []).compactMap { attendee in
                guard let box = attendee.child("Mailbox") else { return nil }
                return (mailbox(box), attendee.value("ResponseType"))
            }
        }
        item.required = attendees("RequiredAttendees")
        item.optional = attendees("OptionalAttendees")
        return item
    }

    /// XML полей встречи в порядке схемы EWS (порядок элементов важен).
    static func calendarItemXML(subject: String, body: String, reminder: Int?, start: Date, end: Date,
                                isAllDay: Bool, location: String, attendees: [String], timeZone: String?) -> String {
        var x = "<t:Subject>\(XMLTree.escape(subject))</t:Subject>"
        x += "<t:Body BodyType=\"Text\">\(XMLTree.escape(body))</t:Body>"
        if let reminder {
            x += "<t:ReminderIsSet>true</t:ReminderIsSet><t:ReminderMinutesBeforeStart>\(reminder)</t:ReminderMinutesBeforeStart>"
        } else {
            x += "<t:ReminderIsSet>false</t:ReminderIsSet>"
        }
        x += "<t:Start>\(formatDate(start))</t:Start><t:End>\(formatDate(end))</t:End>"
        x += "<t:IsAllDayEvent>\(isAllDay)</t:IsAllDayEvent>"
        x += "<t:LegacyFreeBusyStatus>\(isAllDay ? "Free" : "Busy")</t:LegacyFreeBusyStatus>"
        if !location.isEmpty { x += "<t:Location>\(XMLTree.escape(location))</t:Location>" }
        if !attendees.isEmpty {
            x += "<t:RequiredAttendees>" + attendees.map {
                "<t:Attendee><t:Mailbox><t:EmailAddress>\(XMLTree.escape($0))</t:EmailAddress></t:Mailbox></t:Attendee>"
            }.joined() + "</t:RequiredAttendees>"
        }
        if let timeZone {
            x += "<t:StartTimeZone Id=\"\(timeZone)\"/><t:EndTimeZone Id=\"\(timeZone)\"/>"
        }
        return x
    }

    /// Новая встреча. С участниками — Exchange сам разошлёт приглашения.
    func createCalendarItem(subject: String, body: String, reminder: Int?, start: Date, end: Date, isAllDay: Bool,
                            location: String, attendees: [String], timeZone: String?) async throws -> String {
        let send = attendees.isEmpty ? "SendToNone" : "SendToAllAndSaveCopy"
        let item = Self.calendarItemXML(subject: subject, body: body, reminder: reminder, start: start, end: end,
                                        isAllDay: isAllDay, location: location, attendees: attendees, timeZone: timeZone)
        let messages = try await callChecked("""
        <m:CreateItem SendMeetingInvitations="\(send)">\
        <m:SavedItemFolderId><t:DistinguishedFolderId Id="calendar"/></m:SavedItemFolderId>\
        <m:Items><t:CalendarItem>\(item)</t:CalendarItem></m:Items></m:CreateItem>
        """)
        guard let id = messages.first?.firstDescendant("ItemId")?.attributes["Id"] else { throw EWSError.malformed }
        return id
    }

    /// Изменение встречи: каждое поле — SetItemField; участникам уйдёт обновление.
    func updateCalendarItem(id: String, subject: String, body: String, reminder: Int?, start: Date, end: Date,
                            isAllDay: Bool, location: String, attendees: [String]?, timeZone: String?) async throws {
        func set(_ field: String, _ value: String) -> String {
            "<t:SetItemField><t:FieldURI FieldURI=\"\(field)\"/><t:CalendarItem>\(value)</t:CalendarItem></t:SetItemField>"
        }
        func delete(_ field: String) -> String { "<t:DeleteItemField><t:FieldURI FieldURI=\"\(field)\"/></t:DeleteItemField>" }
        var updates = set("item:Subject", "<t:Subject>\(XMLTree.escape(subject))</t:Subject>")
        updates += set("item:Body", "<t:Body BodyType=\"Text\">\(XMLTree.escape(body))</t:Body>")
        if let reminder {
            updates += set("item:ReminderIsSet", "<t:ReminderIsSet>true</t:ReminderIsSet>")
            updates += set("item:ReminderMinutesBeforeStart", "<t:ReminderMinutesBeforeStart>\(reminder)</t:ReminderMinutesBeforeStart>")
        } else {
            updates += set("item:ReminderIsSet", "<t:ReminderIsSet>false</t:ReminderIsSet>")
        }
        if let timeZone, isAllDay {
            updates += set("calendar:StartTimeZone", "<t:StartTimeZone Id=\"\(timeZone)\"/>")
            updates += set("calendar:EndTimeZone", "<t:EndTimeZone Id=\"\(timeZone)\"/>")
        }
        updates += set("calendar:Start", "<t:Start>\(Self.formatDate(start))</t:Start>")
        updates += set("calendar:End", "<t:End>\(Self.formatDate(end))</t:End>")
        updates += set("calendar:IsAllDayEvent", "<t:IsAllDayEvent>\(isAllDay)</t:IsAllDayEvent>")
        updates += location.isEmpty ? delete("calendar:Location")
            : set("calendar:Location", "<t:Location>\(XMLTree.escape(location))</t:Location>")
        if let attendees {
            updates += attendees.isEmpty ? delete("calendar:RequiredAttendees")
                : set("calendar:RequiredAttendees", "<t:RequiredAttendees>" + attendees.map {
                    "<t:Attendee><t:Mailbox><t:EmailAddress>\(XMLTree.escape($0))</t:EmailAddress></t:Mailbox></t:Attendee>"
                }.joined() + "</t:RequiredAttendees>")
        }
        try await callChecked("""
        <m:UpdateItem ConflictResolution="AlwaysOverwrite" SendMeetingInvitationsOrCancellations="SendToAllAndSaveCopy">\
        <m:ItemChanges><t:ItemChange><t:ItemId Id="\(XMLTree.escape(id))"/><t:Updates>\(updates)</t:Updates></t:ItemChange></m:ItemChanges>\
        </m:UpdateItem>
        """)
    }

    /// Удалить встречу (в «Удалённые»); участникам — отмена.
    func deleteCalendarItem(id: String) async throws {
        try await callChecked("""
        <m:DeleteItem DeleteType="MoveToDeletedItems" SendMeetingCancellations="SendToAllAndSaveCopy">\
        <m:ItemIds>\(Self.itemIdsXML([id]))</m:ItemIds></m:DeleteItem>
        """)
    }

    /// Принять / под вопросом / отклонить. `id` — встреча в календаре или письмо-приглашение.
    func respond(to id: String, _ response: EWSMeetingResponse, comment: String? = nil, send: Bool = true) async throws {
        let body = comment.map { "<t:Body BodyType=\"Text\">\(XMLTree.escape($0))</t:Body>" } ?? ""
        try await callChecked("""
        <m:CreateItem MessageDisposition="\(send ? "SendAndSaveCopy" : "SaveOnly")">\
        <m:Items><t:\(response.rawValue)>\(body)<t:ReferenceItemId Id="\(XMLTree.escape(id))"/></t:\(response.rawValue)></m:Items>\
        </m:CreateItem>
        """)
    }
}
