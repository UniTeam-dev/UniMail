import AppKit
import SwiftUI

/// Карточка встречи (поповер): время, место и ссылка на видеовстречу, участники с ответами, описание,
/// «Принять / Под вопросом / Отклонить», изменить, удалить, открыть письмо или Календарь.
@MainActor
struct EventDetailView: View {
    @Environment(MailStore.self) private var store
    @State var event: CalendarEvent
    let data: ScheduleData
    let actions: ScheduleActions
    let close: () -> Void

    @State private var responding: EventResponse?
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var showAllAttendees = false

    var body: some View {
        let color = data.color(event)
        VStack(alignment: .leading, spacing: 0) {
            // Заголовок
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 5, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(size: 15, weight: .semibold))
                        .strikethrough(event.isCancelled)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 5) {
                        Text(dateLine)
                        if event.isRecurring { Image(systemName: "repeat").help("Повторяющаяся встреча") }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(UM.fg2)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            if event.isCancelled {
                banner("Встреча отменена организатором", symbol: "xmark.octagon", tint: UM.badFg, bg: UM.bad)
            }

            VStack(alignment: .leading, spacing: 9) {
                if !event.location.isEmpty && !locationIsLink {
                    row("mappin.and.ellipse") {
                        Text(event.location).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let url = event.meetingURL ?? (locationIsLink ? URL(string: event.location.trimmingCharacters(in: .whitespaces)) : nil) {
                    row("video") {
                        HStack(spacing: 8) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Подключиться", systemImage: "arrow.up.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(UMButtonStyle(kind: .primary, height: 24, radius: 7, horizontal: 10))
                            Text(url.host ?? "")
                                .font(.system(size: 11.5))
                                .foregroundStyle(UM.fg3)
                                .lineLimit(1)
                        }
                        .help(url.absoluteString)
                        .contextMenu {
                            Button("Скопировать ссылку") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                        }
                    }
                }
                row("calendar") {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(calendarLine).foregroundStyle(UM.fg2)
                    }
                }
                if let organizer = event.organizer, event.isMeeting {
                    row("person.crop.circle") {
                        HStack(spacing: 4) {
                            Text(organizer.display)
                            Text("· организатор").foregroundStyle(UM.fg3)
                        }
                        .help(organizer.email)
                    }
                }
                if !event.attendees.isEmpty { attendeesBlock }
                if event.detailsPending {
                    row("ellipsis") { ProgressView().controlSize(.small) }
                }
                if !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundStyle(UM.fg2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UM.inset))
                }
            }
            .font(.system(size: 12.5))

            if event.canRespond { responseBar.padding(.top, 14) }

            if let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.badFg)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            actionsBar.padding(.top, 14)
        }
        .padding(16)
        .frame(width: 360)
        .task {
            if event.detailsPending {
                let detailed = await store.loadDetails(event)
                withAnimation(Motion.snappy) { event = detailed }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { Task { await delete() } }
        } message: {
            if event.isMeeting && !event.attendees.isEmpty {
                Text("Участникам уйдёт уведомление об отмене.")
            }
        }
    }

    private var dateLine: String {
        let day = RelativeDate.dayTitle(event.start)
        return event.isAllDay ? "\(day) · \(EventTime.text(event))" : "\(day) · \(EventTime.text(event)) · \(EventTime.duration(event))"
    }

    private var calendarLine: String {
        switch event.source {
        case .exchange: "Exchange · \(event.calendarTitle)"
        case .mail: "Приглашение в письме · \(event.accountID.flatMap { store.account($0)?.displayName } ?? "")"
        case .system: event.calendarTitle.isEmpty ? "Календарь" : event.calendarTitle
        }
    }

    /// Место — просто ссылка на видеовстречу.
    private var locationIsLink: Bool {
        let location = event.location.trimmingCharacters(in: .whitespaces).lowercased()
        return location.hasPrefix("http://") || location.hasPrefix("https://")
    }

    /// Описание без технического хвоста Teams/Zoom и без ссылки, которая уже на кнопке.
    private var notes: String {
        var text = event.notes
        for link in [event.meetingURL?.absoluteString, locationIsLink ? event.location.trimmingCharacters(in: .whitespaces) : nil] {
            if let link, !link.isEmpty { text = text.replacingOccurrences(of: link, with: "🔗") }
        }
        return text
            .replacingOccurrences(of: "_{10,}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deleteTitle: String { "Удалить «\(event.title)»?" }

    private func row<Content: View>(_ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(UM.fg3)
                .frame(width: 16)
            content()
            Spacer(minLength: 0)
        }
    }

    private func banner(_ text: String, symbol: String, tint: Color, bg: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
            .padding(.bottom, 10)
    }

    // MARK: Участники

    private var attendeesBlock: some View {
        let list = event.attendees
        let shown = showAllAttendees ? list : Array(list.prefix(6))
        let counts = Dictionary(grouping: list, by: \.response).mapValues(\.count)
        return row("person.2") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(list.count) \(plural(list.count, "участник", "участника", "участников"))")
                    if let n = counts[.accepted] { Text("✓ \(n)").foregroundStyle(UM.green) }
                    if let n = counts[.tentative] { Text("? \(n)").foregroundStyle(UM.orange) }
                    if let n = counts[.declined] { Text("✕ \(n)").foregroundStyle(UM.red) }
                }
                .font(.system(size: 12, weight: .medium))
                ForEach(Array(shown.enumerated()), id: \.offset) { _, attendee in
                    HStack(spacing: 6) {
                        Image(systemName: attendee.response.symbol)
                            .font(.system(size: 10.5))
                            .foregroundStyle(responseColor(attendee.response))
                            .frame(width: 13)
                        Text(attendee.display).lineLimit(1)
                        if attendee.optional { Text("по желанию").foregroundStyle(UM.fg3) }
                    }
                    .font(.system(size: 12))
                    .help("\(attendee.email) · \(attendee.response.title)")
                    .contextMenu {
                        Button("Написать письмо") { writeTo([Address(name: attendee.name, email: attendee.email)]) }
                        Button("Скопировать адрес") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(attendee.email, forType: .string)
                        }
                    }
                }
                if list.count > shown.count {
                    Button("Показать всех (\(list.count))") { withAnimation(Motion.snappy) { showAllAttendees = true } }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
        }
    }

    private func responseColor(_ response: EventResponse) -> Color {
        switch response {
        case .accepted, .organizer: UM.green
        case .tentative: UM.orange
        case .declined: UM.red
        case .none: UM.fg3
        }
    }

    // MARK: Ответ

    private var responseBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(event.myResponse == .none ? "Пойдёте?" : "Ваш ответ: \(event.myResponse.title.lowercased())")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(UM.fg3)
            HStack(spacing: 6) {
                responseButton(.accepted, "Принять", "checkmark")
                responseButton(.tentative, "Под вопросом", "questionmark")
                responseButton(.declined, "Отклонить", "xmark")
            }
        }
    }

    private func responseButton(_ response: EventResponse, _ title: String, _ symbol: String) -> some View {
        let active = event.myResponse == response
        let tint = responseColor(response)
        return Button {
            Task { await respond(response) }
        } label: {
            HStack(spacing: 5) {
                if responding == response {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(active ? .white : UM.fg)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? tint : UM.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(responding != nil)
    }

    private func respond(_ response: EventResponse) async {
        responding = response
        error = nil
        let ok = await store.respond(to: event, response)
        responding = nil
        if ok {
            withAnimation(Motion.snappy) { event.myResponse = response }
            if response == .declined { close() }
        } else {
            error = event.accountID.flatMap { store.calendarErrors[$0] ?? store.accountErrors[$0] } ?? "Не удалось отправить ответ."
        }
    }

    // MARK: Действия

    private var actionsBar: some View {
        HStack(spacing: 6) {
            if event.canEdit && event.source != .mail {
                Button {
                    close()
                    actions.edit(event)
                } label: { Label("Изменить", systemImage: "pencil") }
                    .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
            }
            if let messageID = event.messageID {
                Button {
                    close()
                    openMessage(messageID)
                } label: { Label("Письмо", systemImage: "envelope") }
                    .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
            }
            Menu {
                if event.isMeeting, !event.attendees.isEmpty {
                    Button("Написать участникам") {
                        writeTo(event.attendees.map { Address(name: $0.name, email: $0.email) }
                            + (event.organizer.map { [Address(name: $0.name, email: $0.email)] } ?? []))
                    }
                }
                Button("Скопировать сведения") {
                    var text = "\(event.title)\n\(dateLine)"
                    if !event.location.isEmpty { text += "\n\(event.location)" }
                    if let url = event.meetingURL { text += "\n\(url.absoluteString)" }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if event.source == .system {
                    Button("Открыть в Календаре") {
                        CalendarService.shared.openInCalendar(date: event.start, eventID: event.remoteID)
                    }
                }
                Button("Новая встреча на это время") {
                    close()
                    actions.create(event.start, event.isAllDay)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: 0)
            if event.canEdit && event.source != .mail {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash").frame(width: 26, height: 26)
                }
                .buttonStyle(ToolbarIconStyle(width: 28, height: 26, radius: 7, tint: UM.badFg))
                .help("Удалить встречу")
            }
        }
    }

    private func delete() async {
        do {
            switch event.source {
            case .exchange:
                try await store.deleteServerEvent(event)
            case .system:
                let invitation = CalendarService.shared.invitations[event.remoteID]
                try CalendarService.shared.delete(eventID: event.remoteID)
                if let invitation {
                    var draft = EventDraft(event: event)
                    draft.attendees = invitation.attendees
                    await store.sendInvitation(uid: invitation.uid, sequence: invitation.sequence + 1, draft: draft,
                                               from: invitation.accountID, cancel: true)
                }
            case .mail:
                return
            }
            close()
        } catch {
            self.error = "Не удалось удалить: \(error.localizedDescription)"
        }
    }

    private func openMessage(_ messageID: String) {
        guard let message = store.messages[messageID] else { return }
        withAnimation(Motion.smooth) { store.mode = .mail }
        let scope: MailScope = message.role == .custom
            ? .folder(message.accountID, message.folder ?? "")
            : .account(message.accountID, message.role)
        store.searchText = ""
        store.select(scope: scope)
        store.selectedThreadID = message.threadID
        store.openThread(message.threadID)
    }

    private func writeTo(_ addresses: [Address]) {
        var seen = Set<String>()
        let unique = addresses.filter { seen.insert($0.email.lowercased()).inserted && !$0.email.isEmpty }
        store.compose(.new)
        guard var request = store.composeQueue.popLast() else { return }
        request.draft.to = unique
        if request.draft.subject.isEmpty { request.draft.subject = event.title }
        store.composeQueue.append(request)
    }
}
