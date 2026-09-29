import SwiftUI

/// Новая встреча или изменение своей: название, время, календарь (Exchange или Календарь macOS),
/// место, участники, напоминание, описание. Участникам Exchange сам рассылает приглашения;
/// для Календаря macOS приглашение уходит письмом (iCalendar) с выбранного ящика.
@MainActor
struct EventEditorSheet: View {
    @Environment(MailStore.self) private var store
    let request: EventEditorRequest
    let onDone: () -> Void

    enum Target: Hashable {
        case exchange(UUID)
        case system(String)
    }

    @State private var draft: EventDraft
    @State private var target: Target?
    @State private var attendeesText = ""
    @State private var inviteFrom: UUID?
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(request: EventEditorRequest, onDone: @escaping () -> Void) {
        self.request = request
        self.onDone = onDone
        _draft = State(initialValue: request.draft)
        _attendeesText = State(initialValue: request.draft.attendees.map(\.email).joined(separator: ", "))
    }

    private var isNew: Bool { request.original == nil }
    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "Новая встреча" : "Изменить встречу")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        label("Название")
                        TextField("Созвон, обед, планирование…", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                            .focused($titleFocused)
                    }
                    GridRow {
                        label("Весь день")
                        Toggle("", isOn: allDayBinding).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    GridRow {
                        label("Начало")
                        DatePicker("", selection: startBinding,
                                   displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                            .labelsHidden()
                            .fixedSize()
                    }
                    GridRow {
                        label("Конец")
                        HStack(spacing: 8) {
                            DatePicker("", selection: endBinding, in: draft.start...,
                                       displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                                .labelsHidden()
                                .fixedSize()
                            if !draft.isAllDay {
                                Menu("Длительность") {
                                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                                        Button(minutes < 60 ? "\(minutes) мин" : (minutes % 60 == 0 ? "\(minutes / 60) ч" : "1,5 ч")) {
                                            draft.end = draft.start.addingTimeInterval(TimeInterval(minutes * 60))
                                        }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }
                    GridRow {
                        label("Календарь")
                        Picker("", selection: $target) {
                            if !exchangeAccounts.isEmpty {
                                Section("Exchange") {
                                    ForEach(exchangeAccounts) { account in
                                        Text(account.displayName).tag(Optional(Target.exchange(account.id)))
                                    }
                                }
                            }
                            if !systemCalendars.isEmpty {
                                Section("Календарь macOS") {
                                    ForEach(systemCalendars) { item in
                                        Text("\(item.title) · \(item.sourceTitle)").tag(Optional(Target.system(item.id)))
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!isNew)
                    }
                    GridRow {
                        label("Место")
                        TextField("Переговорная, адрес или ссылка на звонок", text: $draft.location)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow(alignment: .top) {
                        label("Участники").padding(.top, 4)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("адреса через запятую", text: $attendeesText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...4)
                            if !suggestions.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(suggestions, id: \.email) { address in
                                        Button(address.name ?? address.email) { add(address) }
                                            .buttonStyle(UMButtonStyle(kind: .secondary, height: 20, radius: 6, horizontal: 7))
                                            .font(.system(size: 11))
                                            .help(address.email)
                                    }
                                }
                            }
                            Text(inviteHint)
                                .font(.system(size: 11))
                                .foregroundStyle(UM.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if case .system = target, !parsedAttendees.isEmpty {
                        GridRow {
                            label("Пригласить с")
                            Picker("", selection: $inviteFrom) {
                                ForEach(liveAccounts) { account in
                                    Text("\(account.displayName) · \(account.email)").tag(Optional(account.id))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    GridRow {
                        label("Напомнить")
                        Picker("", selection: $draft.reminderMinutes) {
                            Text("Не напоминать").tag(Int?.none)
                            ForEach([0, 5, 10, 15, 30, 60, 1440], id: \.self) { minutes in
                                Text(reminderTitle(minutes)).tag(Optional(minutes))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow(alignment: .top) {
                        label("Описание").padding(.top, 4)
                        TextEditor(text: $draft.notes)
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .frame(minHeight: 80, maxHeight: 160)
                            .background(RoundedRectangle(cornerRadius: 6).fill(UM.field))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(UM.badFg)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отменить") { onDone() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(UMButtonStyle(kind: .secondary))
                Button(saveTitle) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(UMButtonStyle(kind: .primary))
                    .disabled(saving || target == nil || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(UM.sheetBar)
        }
        .frame(width: 520, height: 600)
        .background(UM.sheet)
        .task {
            if CalendarService.shared.access == .notDetermined && exchangeAccounts.isEmpty {
                await CalendarService.shared.requestAccess()
            }
            if target == nil { target = defaultTarget }
            if inviteFrom == nil { inviteFrom = store.scope.accountID ?? liveAccounts.first?.id }
            titleFocused = isNew
        }
    }

    // MARK: Данные

    private var exchangeAccounts: [Account] {
        store.calendarAccountIDs.compactMap { store.account($0) }
    }

    private var systemCalendars: [CalendarService.CalendarInfo] { CalendarService.shared.writableCalendars }

    private var liveAccounts: [Account] {
        store.accounts.filter { $0.kind != .demo && store.providers[$0.id]?.isLive == true }
    }

    private var defaultTarget: Target? {
        if let original = request.original {
            switch original.source {
            case .exchange: return original.accountID.map(Target.exchange)
            case .system:
                return CalendarService.shared.calendars.first { $0.title == original.calendarTitle }.map { .system($0.id) }
                    ?? CalendarService.shared.defaultCalendarID.map(Target.system)
            case .mail: return nil
            }
        }
        if let id = store.scope.accountID, store.calendarAccountIDs.contains(id) { return .exchange(id) }
        if let first = exchangeAccounts.first { return .exchange(first.id) }
        if let id = CalendarService.shared.defaultCalendarID, systemCalendars.contains(where: { $0.id == id }) { return .system(id) }
        return systemCalendars.first.map { .system($0.id) }
    }

    private var parsedAttendees: [Address] {
        MIMEParser.parseAddressList(attendeesText.replacingOccurrences(of: ";", with: ","))
            .filter { $0.email.contains("@") }
    }

    /// Недавние адресаты по введённому началу.
    private var suggestions: [Address] {
        let last = attendeesText.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard last.count >= 2, !last.contains("@") || !last.hasSuffix(".") else { return [] }
        var seen = Set(parsedAttendees.map { $0.email.lowercased() })
        var result: [Address] = []
        for message in store.messages.values.sorted(by: { $0.date > $1.date }) {
            for address in [message.from] + message.to + message.cc where address.email.contains("@") {
                let key = address.email.lowercased()
                guard !seen.contains(key),
                      key.hasPrefix(last) || (address.name?.lowercased().contains(last) ?? false) else { continue }
                seen.insert(key)
                result.append(address)
                if result.count == 4 { return result }
            }
        }
        return result
    }

    private func add(_ address: Address) {
        var parts = attendeesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(address.email)
        attendeesText = parts.joined(separator: ", ") + ", "
    }

    private var inviteHint: String {
        switch target {
        case .exchange: "Exchange разошлёт приглашения и соберёт ответы."
        case .system: "Приглашение уйдёт письмом с выбранного ящика — его можно принять в любом календаре."
        case nil: ""
        }
    }

    private var saveTitle: String {
        if parsedAttendees.isEmpty { return isNew ? "Создать" : "Сохранить" }
        return isNew ? "Создать и пригласить" : "Сохранить и отправить"
    }

    private func reminderTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: "В момент начала"
        case 1440: "За день"
        case 60: "За час"
        default: "За \(minutes) мин"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(UM.fg2)
            .frame(width: 96, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    // MARK: Время

    private var allDayBinding: Binding<Bool> {
        Binding(get: { draft.isAllDay }, set: { allDay in
            draft.isAllDay = allDay
            if allDay {
                draft.start = calendar.startOfDay(for: draft.start)
                let lastDay = calendar.startOfDay(for: max(draft.end.addingTimeInterval(-1), draft.start))
                draft.end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? draft.start
            } else {
                draft.start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: draft.start) ?? draft.start
                draft.end = draft.start.addingTimeInterval(3600)
            }
        })
    }

    /// Сдвиг начала переносит и конец — длительность сохраняется.
    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { value in
            let duration = draft.end.timeIntervalSince(draft.start)
            draft.start = draft.isAllDay ? calendar.startOfDay(for: value) : value
            draft.end = draft.start.addingTimeInterval(max(duration, draft.isAllDay ? 86400 : 15 * 60))
        })
    }

    /// Для «весь день» конец в EventKit и Exchange — следующая полночь; в поле показываем последний день.
    private var endBinding: Binding<Date> {
        Binding(get: {
            draft.isAllDay ? max(draft.start, draft.end.addingTimeInterval(-86400)) : draft.end
        }, set: { value in
            if draft.isAllDay {
                draft.end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: value)) ?? value
            } else {
                draft.end = max(value, draft.start.addingTimeInterval(5 * 60))
            }
        })
    }

    // MARK: Сохранение

    private func save() async {
        guard let target else { return }
        saving = true
        error = nil
        var final = draft
        final.title = final.title.trimmingCharacters(in: .whitespacesAndNewlines)
        final.attendees = parsedAttendees
        let before = Set(request.draft.attendees.map { $0.email.lowercased() })
        final.attendeesChanged = isNew || Set(final.attendees.map { $0.email.lowercased() }) != before
        do {
            switch target {
            case .exchange(let accountID):
                try await store.saveServerEvent(final, accountID: accountID)
            case .system(let calendarID):
                if !CalendarService.shared.access.canWrite { await CalendarService.shared.requestAccess() }
                // Для EventKit конец «весь день» — последняя секунда дня.
                var ek = final
                if ek.isAllDay { ek.end = ek.end.addingTimeInterval(-1) }
                let id = try CalendarService.shared.save(ek, calendarID: calendarID)
                var invitations = CalendarService.shared.invitations
                let previous = invitations[id] ?? request.original.flatMap { invitations[$0.remoteID] }
                if !final.attendees.isEmpty, let from = inviteFrom ?? previous?.accountID {
                    let invitation = CalendarService.Invitation(
                        uid: previous?.uid ?? "\(UUID().uuidString)@unimail",
                        sequence: previous.map { $0.sequence + 1 } ?? 0,
                        accountID: from, attendees: final.attendees)
                    invitations[id] = invitation
                    CalendarService.shared.invitations = invitations
                    await store.sendInvitation(uid: invitation.uid, sequence: invitation.sequence, draft: final, from: from)
                } else if let previous, final.attendees.isEmpty {
                    // Всех участников убрали — отменяем для них встречу.
                    var cancelled = final
                    cancelled.attendees = previous.attendees
                    await store.sendInvitation(uid: previous.uid, sequence: previous.sequence + 1, draft: cancelled,
                                               from: previous.accountID, cancel: true)
                    invitations[id] = nil
                    CalendarService.shared.invitations = invitations
                }
            }
            saving = false
            onDone()
        } catch {
            saving = false
            self.error = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }
}
