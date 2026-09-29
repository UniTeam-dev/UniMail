import Foundation

/// Встречи: календари Exchange (через провайдер ящика) и приглашения из писем.
/// События Календаря macOS (EventKit) добавляет экран «Расписание» — здесь только то, что идёт через почту.
@MainActor
extension MailStore {
    /// Ящики с календарём на сервере.
    var calendarAccountIDs: [UUID] {
        accounts.map(\.id).filter { providers[$0]?.hasServerCalendar == true && providers[$0]?.isLive == true }
    }

    /// Загрузить встречи Exchange за период (замещает загруженные ранее в этом периоде).
    func loadCalendar(from start: Date, to end: Date) async {
        await withTaskGroup(of: Void.self) { group in
            for id in calendarAccountIDs {
                group.addTask { await self.loadCalendar(accountID: id, from: start, to: end) }
            }
        }
    }

    func loadCalendar(accountID: UUID, from start: Date, to end: Date) async {
        guard let provider = providers[accountID], provider.hasServerCalendar else { return }
        do {
            let fetched = try await provider.calendarEvents(from: start, to: end)
            var list = (serverEvents[accountID] ?? []).filter { !$0.overlaps(start, end) }
            // Уже загруженные подробности не теряем.
            let known = Dictionary((serverEvents[accountID] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for var event in fetched {
                if let old = known[event.id], !old.detailsPending {
                    event.attendees = old.attendees
                    event.notes = old.notes
                    event.detailsPending = false
                }
                list.append(event)
            }
            serverEvents[accountID] = list.sorted { $0.start < $1.start }
            calendarErrors[accountID] = nil
        } catch {
            calendarErrors[accountID] = error.localizedDescription
        }
    }

    /// Встречи Exchange и приглашения из писем за период. Приглашение, которое уже есть в календаре
    /// Exchange, не дублируется — к встрече привязывается письмо.
    func mailCalendarEvents(from start: Date, to end: Date, accountFilter: UUID?) -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        for (accountID, events) in serverEvents where accountFilter == nil || accountID == accountFilter {
            guard account(accountID) != nil else { continue }
            result += events.filter { $0.overlaps(start, end) && !$0.isCancelled }
        }
        guard scheduleLayers.contains(.meetingsFromMail) else { return result }

        for message in messages.values where message.role != .trash && message.role != .spam {
            // Ответы участников («Принято: …») и прочие не-приглашения встречами не считаем.
            guard let invite = message.invite, accountFilter == nil || message.accountID == accountFilter,
                  !Self.isInviteReply(invite, subject: message.subject),
                  invite.start < end, max(invite.end, invite.start) >= start else { continue }
            if let index = result.firstIndex(where: {
                $0.accountID == message.accountID && $0.title == invite.title && abs($0.start.timeIntervalSince(invite.start)) < 60
            }) {
                result[index].messageID = message.id
                continue
            }
            // Уже в календаре Exchange (загружен весь период ящика) — не показываем второй раз.
            if serverEvents[message.accountID] != nil, invite.response != nil { continue }
            result.append(Self.inviteEvent(message: message, invite: invite))
        }
        return result.sorted { $0.start < $1.start }
    }

    static func isInviteReply(_ invite: Invite, subject: String) -> Bool {
        if let ics = invite.ics?.uppercased(), ics.contains("METHOD:REPLY") || ics.contains("METHOD:COUNTER") { return true }
        let lower = subject.lowercased()
        return ["принято:", "отклонено:", "под вопросом:", "accepted:", "declined:", "tentative:"].contains { lower.hasPrefix($0) }
    }

    static func inviteEvent(message: Message, invite: Invite) -> CalendarEvent {
        var event = CalendarEvent(id: "invite-\(message.id)", source: .mail, accountID: message.accountID,
                                  remoteID: message.id, title: invite.title, start: invite.start,
                                  end: max(invite.end, invite.start.addingTimeInterval(15 * 60)))
        event.location = invite.location
        event.notes = message.body
        let organizer = invite.organizer ?? message.from
        event.organizer = EventAttendee(name: organizer.name, email: organizer.email, response: .organizer)
        event.attendees = (message.to + message.cc).map { EventAttendee(name: $0.name, email: $0.email) }
        event.myResponse = EventResponse(partStat: invite.response)
        event.isMeeting = true
        event.canEdit = false
        event.messageID = message.id
        event.calendarTitle = "Из письма"
        if let ics = invite.ics, let parsed = ICSParser.parse(ics).first {
            event.isAllDay = parsed.allDay
            if parsed.method?.uppercased() == "CANCEL" { event.isCancelled = true }
            if !parsed.attendees.isEmpty {
                event.attendees = parsed.attendees.map { EventAttendee(name: $0.name, email: $0.email) }
            }
        }
        return event
    }

    /// Подробности встречи Exchange (участники, описание).
    func loadDetails(_ event: CalendarEvent) async -> CalendarEvent {
        guard event.source == .exchange, event.detailsPending, let accountID = event.accountID,
              let provider = providers[accountID] else { return event }
        do {
            var detailed = try await provider.calendarEventDetails(event)
            detailed.messageID = event.messageID
            updateServerEvent(id: event.id, accountID: accountID) { $0 = detailed }
            return detailed
        } catch {
            calendarErrors[accountID] = error.localizedDescription
            return event
        }
    }

    /// Создать или изменить встречу в календаре Exchange.
    func saveServerEvent(_ draft: EventDraft, accountID: UUID) async throws {
        guard let provider = providers[accountID] else { throw MailProviderError.notFound }
        _ = try await provider.saveEvent(draft)
        await reloadAround(draft.start, accountID: accountID)
    }

    /// Удалить свою встречу Exchange (участникам уйдёт отмена).
    func deleteServerEvent(_ event: CalendarEvent) async throws {
        guard let accountID = event.accountID, let provider = providers[accountID] else { return }
        try await provider.deleteEvent(remoteID: event.remoteID)
        serverEvents[accountID]?.removeAll { $0.id == event.id }
    }

    /// Принять / под вопросом / отклонить.
    @discardableResult
    func respond(to event: CalendarEvent, _ response: EventResponse) async -> Bool {
        switch event.source {
        case .mail:
            guard let status = ICSPartStat(rawValue: response.rawValue.uppercased()) else { return false }
            return await respondToInvite(messageID: event.remoteID, status: status)
        case .exchange:
            guard let accountID = event.accountID, let provider = providers[accountID] else { return false }
            let previous = event.myResponse
            updateServerEvent(id: event.id, accountID: accountID) { $0.myResponse = response }
            do {
                try await provider.respondToEvent(remoteID: event.remoteID, response: response, comment: nil)
                if let messageID = event.messageID {
                    setInviteResponse(messageID: messageID, response.rawValue.uppercased())
                }
                if response == .declined {
                    serverEvents[accountID]?.removeAll { $0.id == event.id }
                }
                return true
            } catch {
                updateServerEvent(id: event.id, accountID: accountID) { $0.myResponse = previous }
                calendarErrors[accountID] = "Ответ не отправлен: \(error.localizedDescription)"
                return false
            }
        case .system:
            // Встреча Exchange, которую сервер не отдал в сетке: ищем её в ящиках Exchange и отвечаем там.
            lastCalendarError = nil
            for accountID in calendarAccountIDs {
                guard let provider = providers[accountID] else { continue }
                do {
                    guard var found = try await provider.locateEvent(title: event.title, start: event.start, end: event.end) else { continue }
                    found.accountID = accountID
                    try await provider.respondToEvent(remoteID: found.remoteID, response: response, comment: nil)
                    found.myResponse = response
                    eventResponseOverrides[event.id] = response
                    if !(serverEvents[accountID] ?? []).contains(where: { $0.id == found.id }) && response != .declined {
                        serverEvents[accountID, default: []].append(found)
                    } else {
                        updateServerEvent(id: found.id, accountID: accountID) { $0.myResponse = response }
                    }
                    return true
                } catch {
                    lastCalendarError = "Ответ не отправлен: \(error.localizedDescription)"
                    return false
                }
            }
            lastCalendarError = "Не нашёл эту встречу на сервере Exchange — ответьте в Календаре macOS."
            return false
        }
    }

    /// Приглашение участникам письмом (iCalendar REQUEST или CANCEL) — для встреч не в Exchange.
    func sendInvitation(uid: String, sequence: Int, draft: EventDraft, from accountID: UUID, cancel: Bool = false) async {
        guard let account = account(accountID), !draft.attendees.isEmpty else { return }
        let me = Address(name: account.senderName ?? account.displayName, email: account.email)
        let ics = ICSBuilder.request(uid: uid, sequence: sequence, summary: draft.title, start: draft.start,
                                     end: draft.end, allDay: draft.isAllDay, location: draft.location,
                                     description: draft.notes, organizer: me, attendees: draft.attendees,
                                     method: cancel ? "CANCEL" : "REQUEST")
        let when = draft.start.formatted(.dateTime.day().month(.wide).hour().minute())
        var lines = [cancel ? "Встреча отменена." : "Приглашаю на встречу.", "", draft.title, when]
        if !draft.location.isEmpty { lines.append(draft.location) }
        if !draft.notes.isEmpty { lines += ["", draft.notes] }
        var outgoing = OutgoingMessage(accountID: accountID, fromAddress: account.email, to: draft.attendees, cc: [], bcc: [],
                                       subject: (cancel ? "Отменено: " : sequence > 0 ? "Изменено: " : "Приглашение: ") + draft.title,
                                       body: lines.joined(separator: "\n"))
        outgoing.calendarReply = ics
        outgoing.calendarMethod = cancel ? "CANCEL" : "REQUEST"
        await deliver(outgoing, silent: true)
    }

    // MARK: Внутреннее

    func updateServerEvent(id: String, accountID: UUID, _ change: (inout CalendarEvent) -> Void) {
        guard let index = serverEvents[accountID]?.firstIndex(where: { $0.id == id }) else { return }
        change(&serverEvents[accountID]![index])
    }

    func updateServerEvent(accountID: UUID, title: String, start: Date, _ change: (inout CalendarEvent) -> Void) {
        guard let index = serverEvents[accountID]?.firstIndex(where: {
            $0.title == title && abs($0.start.timeIntervalSince(start)) < 60
        }) else { return }
        change(&serverEvents[accountID]![index])
    }

    private func reloadAround(_ date: Date, accountID: UUID) async {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: date)) ?? date
        let end = calendar.date(byAdding: .day, value: 42, to: start) ?? date
        await loadCalendar(accountID: accountID, from: start, to: end)
    }
}
