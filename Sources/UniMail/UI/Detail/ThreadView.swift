import AppKit
import SwiftUI

/// Открытый тред: тема, чипы, карточки писем и быстрый ответ.
@MainActor
struct ThreadView: View {
    @Environment(MailStore.self) private var store
    let threadID: String

    @State private var expanded: [String: Bool] = [:]

    var body: some View {
        let messages = store.thread(threadID)
        let last = messages.last

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(messages)
                    AISummaryView(threadID: threadID)
                        .padding(.top, 16)
                    VStack(spacing: 8) {
                        ForEach(messages) { message in
                            let isOpen = expanded[message.id] ?? (message.id == last?.id)
                            if isOpen {
                                MessageCard(message: message, account: store.account(message.accountID)) {
                                    toggle(message, open: isOpen, count: messages.count)
                                }
                                .transition(.opacity)
                            } else {
                                CollapsedMessage(message: message, isMine: isMine(message)) {
                                    toggle(message, open: isOpen, count: messages.count)
                                }
                                .transition(.opacity)
                            }
                        }
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 20)
                .frame(maxWidth: 740)
                .frame(maxWidth: .infinity)
            }

            if let last {
                QuickReplyBar(replyTo: last)
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
            }
        }
        .animation(Motion.smooth, value: expanded)
        // Тела писем скачиваются при открытии треда (из базы или с сервера).
        .task(id: threadID) { store.loadBodies(threadID: threadID) }
        .onChange(of: expanded) { store.loadBodies(threadID: threadID) }
    }

    private func isMine(_ message: Message) -> Bool {
        store.accounts.contains { $0.email == message.from.email }
    }

    private func toggle(_ message: Message, open: Bool, count: Int) {
        guard count > 1 else { return }
        withAnimation(Motion.smooth) { expanded[message.id] = !open }
    }

    private func header(_ messages: [Message]) -> some View {
        let subject = messages.last?.subject ?? ""
        var seen = Set<UUID>()
        let accounts = messages.map(\.accountID).filter { seen.insert($0).inserted }.compactMap { store.account($0) }
        let isNewsletter = messages.contains { $0.category == .newsletters }
        let unsubscribable = messages.last { UnsubscribeService.shared.canUnsubscribe($0) }
        let awaitingReply = store.isAwaitingReply(threadID: threadID)
        return VStack(alignment: .leading, spacing: 12) {
            Text(subject)
                .font(.system(size: 23, weight: .bold))
                .tracking(-0.46)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(accounts) { AccountChip(account: $0) }
                InfoChip {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 11))
                    Text("\(messages.count) \(plural(messages.count, "письмо", "письма", "писем")) в треде")
                }
                if let unsubscribable {
                    UnsubscribeChip(message: unsubscribable)
                } else if isNewsletter {
                    InfoChip { Text("Рассылка") }
                }
                if awaitingReply {
                    InfoChip {
                        Image(systemName: "arrowshape.turn.up.left.badge.clock").font(.system(size: 11))
                        Text("Нет ответа ·").foregroundStyle(UM.orange)
                        Button("Снять") {
                            withAnimation(Motion.snappy) { store.dismissFollowUp(threadID: threadID) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(UM.accent)
                        .fontWeight(.medium)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Свёрнутое письмо

@MainActor
private struct CollapsedMessage: View {
    let message: Message
    let isMine: Bool
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            SenderAvatar(address: message.from, size: 26, fontSize: 10.5, isMe: isMine)
            Text(message.from.display)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Text(message.snippet)
                .font(.system(size: 12.5))
                .foregroundStyle(UM.fg3)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(RelativeDate.long(message.date))
                .font(.system(size: 12))
                .foregroundStyle(UM.fg3)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .umCard(radius: 12, small: true, fill: hovering ? UM.cardHover : UM.card)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

// MARK: - Раскрытое письмо

@MainActor
struct MessageCard: View {
    @Environment(MailStore.self) private var store
    let message: Message
    let account: Account?
    var onToggle: () -> Void

    private var isMine: Bool { store.accounts.contains { $0.email == message.from.email } }

    /// «мне, Михаил Орлов и ещё 3».
    private var recipientsText: String {
        let myEmails = Set(store.accounts.flatMap { [$0.email] + $0.aliases })
        let all = message.to + message.cc
        let names = all.map { myEmails.contains($0.email) ? "мне" : $0.display }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) и ещё \(names.count - 2)" : shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SenderAvatar(address: message.from, size: 36, fontSize: 13, isMe: isMine)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(message.from.display)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .contextMenu { senderMenu }
                        Text(message.from.email)
                            .font(.system(size: 12))
                            .foregroundStyle(UM.fg3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text("кому: \(recipientsText)")
                        .font(.system(size: 12))
                        .foregroundStyle(UM.fg3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(RelativeDate.long(message.date))
                    .font(.system(size: 12))
                    .foregroundStyle(UM.fg3)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if message.role == .scheduled || message.role == .drafts {
                OutboxBar(message: message).padding(.top, 14)
            }
            if let invite = message.invite {
                InviteBlock(message: message, invite: invite).padding(.top, 16)
            }
            if let code = message.detectedCode {
                CodeBlock(code: code).padding(.top, 16)
            }

            if message.bodyPending == true {
                BodyPlaceholder(message: message).padding(.top, 14)
            } else if let html = message.htmlBody {
                HTMLBody(html: html, senderKnown: store.isKnownSender(message.from.email)).padding(.top, 14)
            } else if !message.paragraphs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(message.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: 13.5))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 48)
                .padding(.top, 16)
            }

            if !message.attachments.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(message.attachments) { attachment in
                        AttachmentChip(attachment: attachment)
                            .contentShape(Rectangle())
                            .onTapGesture { AttachmentActions.open(attachment) }
                            .contextMenu {
                                Button("Открыть") { AttachmentActions.open(attachment) }
                                Button("Сохранить как…") { AttachmentActions.save(attachment) }
                                Button("Показать в Finder") { AttachmentActions.reveal(attachment) }
                            }
                            .help(attachment.localPath == nil ? "Файл ещё скачивается" : "Открыть — клик, другие действия — правый клик")
                    }
                }
                .padding(.leading, 48)
                .padding(.top, 6)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .umCard(radius: 14)
    }

    /// «Категория отправителя»: все его письма переезжают, будущие — тоже.
    @ViewBuilder private var senderMenu: some View {
        Button("Написать \(message.from.display)") {
            store.compose(.new)
            if var request = store.composeQueue.popLast() {
                request.draft.to = [message.from]
                store.composeQueue.append(request)
            }
        }
        Button("Скопировать адрес") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.from.email, forType: .string)
        }
        if !isMine {
            Divider()
            Menu("Категория отправителя") {
                ForEach(InboxCategory.allCases, id: \.self) { category in
                    Button {
                        store.setCategory(category, forSenderOf: message.id)
                    } label: {
                        if category == message.category {
                            Label(category.title, systemImage: "checkmark")
                        } else {
                            Text(category.title)
                        }
                    }
                }
            }
        }
        if message.role == .sent {
            Divider()
            Button("Напомнить, если не ответят") { store.remindIfNoReply(messageID: message.id) }
        }
    }
}

// MARK: - Тело скачивается

@MainActor
private struct BodyPlaceholder: View {
    @Environment(MailStore.self) private var store
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.body.isEmpty {
                Text(message.body)
                    .font(.system(size: 13.5))
                    .lineSpacing(5)
                    .foregroundStyle(UM.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.bodyErrors[message.id] {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UM.orange)
                    Text(error).font(.system(size: 12)).foregroundStyle(UM.fg2).lineLimit(2)
                    Spacer(minLength: 6)
                    Button("Повторить") { store.loadBody(message.id) }
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 24, radius: 6, horizontal: 10))
                }
                .padding(10)
                .umInset(radius: 10)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Загружаю письмо…").font(.system(size: 12)).foregroundStyle(UM.fg3)
                }
                .onAppear { store.loadBody(message.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 48)
        .transition(.opacity)
    }
}

// MARK: - Запланированное письмо и черновик

@MainActor
private struct OutboxBar: View {
    @Environment(MailStore.self) private var store
    let message: Message

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.role == .scheduled ? "calendar.badge.clock" : "pencil.line")
                .font(.system(size: 14))
                .foregroundStyle(message.role == .scheduled ? UM.accent : UM.orange)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if message.role == .scheduled {
                Button("Изменить") { store.editScheduled(messageID: message.id) }
                    .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
                Button("Отправить сейчас") { store.sendScheduledNow(messageID: message.id) }
                    .buttonStyle(UMButtonStyle(kind: .primary, height: 26, radius: 7, horizontal: 10))
            } else {
                Button("Продолжить") { store.compose(.draft, from: message.id) }
                    .buttonStyle(UMButtonStyle(kind: .primary, height: 26, radius: 7, horizontal: 10))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .umInset(radius: 10)
    }

    private var title: String {
        if message.role == .scheduled, let at = message.scheduledAt {
            return "Отправится " + at.formatted(.dateTime.weekday(.wide).day().month().hour().minute())
        }
        return "Черновик"
    }
}

// MARK: - Отписка

@MainActor
private struct UnsubscribeChip: View {
    @Environment(MailStore.self) private var store
    let message: Message
    @State private var state: Phase = .idle

    private enum Phase: Equatable { case idle, working, done(String), failed(String) }

    var body: some View {
        InfoChip {
            switch state {
            case .idle:
                Text("Рассылка ·")
                Button("Отписаться") { run() }
                    .buttonStyle(.plain)
                    .foregroundStyle(UM.accent)
                    .fontWeight(.medium)
            case .working:
                ProgressView().controlSize(.mini)
                Text("Отписываю…")
            case .done(let text):
                Image(systemName: "checkmark").foregroundStyle(UM.green)
                Text(text)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UM.orange)
                Text(text).lineLimit(1)
            }
        }
        .help(helpText)
        .animation(Motion.snappy, value: state)
    }

    private var helpText: String {
        if case .failed(let text) = state { return text }
        return "Отписаться от рассылки (RFC 8058, письмо или ссылка)"
    }

    private func run() {
        state = .working
        Task {
            do {
                let outcome = try await UnsubscribeService.shared.unsubscribe(message, store: store)
                switch outcome {
                case .unsubscribed: state = .done("Вы отписались")
                case .sendEmail: state = .done("Запрос на отписку отправлен")
                case .openedInBrowser: state = .done("Открыта страница отписки")
                }
                try? await Task.sleep(for: .seconds(3))
                store.markUnsubscribed(messageID: message.id)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Вложения

@MainActor
enum AttachmentActions {
    static func open(_ attachment: Attachment) {
        guard let path = attachment.localPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func reveal(_ attachment: Attachment) {
        guard let path = attachment.localPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func save(_ attachment: Attachment) {
        guard let path = attachment.localPath else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)
        } catch {
            ExportService.presentError(error)
        }
    }
}

// MARK: - Приглашение

@MainActor
private struct InviteBlock: View {
    @Environment(MailStore.self) private var store
    let message: Message
    let invite: Invite
    @State private var working = false
    @State private var calendarFailed = false

    private struct RSVP: Identifiable {
        var id: String { status.rawValue }
        var status: ICSPartStat
        var title: String
        var symbol: String
        var color: Color
    }

    private let options = [
        RSVP(status: .accepted, title: "Принять", symbol: "checkmark", color: UM.green),
        RSVP(status: .tentative, title: "Возможно", symbol: "questionmark", color: UM.orange),
        RSVP(status: .declined, title: "Отклонить", symbol: "xmark", color: UM.red),
    ]

    private var answer: String? { invite.response }

    private var whenText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEE, d MMMM"
        let day = f.string(from: invite.start)
        return day.prefix(1).uppercased() + day.dropFirst() + " · " +
            RelativeDate.clock(invite.start) + "–" + RelativeDate.clock(invite.end)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text(RelativeDate.monthShortUpper(invite.start))
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(UM.red)
                    Text("\(Calendar.current.component(.day, from: invite.start))")
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(-0.48)
                        .padding(.top, 3)
                        .padding(.bottom, 5)
                }
                .frame(width: 52)
                .background(UM.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Приглашение на встречу")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.fg3)
                    Text(invite.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .padding(.top, 2)
                    Text(whenText)
                        .font(.system(size: 12))
                        .foregroundStyle(UM.fg2)
                        .padding(.top, 3)
                    Text(invite.location)
                        .font(.system(size: 12))
                        .foregroundStyle(UM.fg3)
                        .lineLimit(1)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .umInset(radius: 12)

            HStack(spacing: 6) {
                ForEach(options) { option in
                    let on = answer == option.id
                    Button {
                        // Запись в Календарь (EventKit) и iCalendar REPLY организатору.
                        guard !on, !working else { return }
                        working = true
                        Task {
                            let ok = await store.respondToInvite(messageID: message.id, status: option.status)
                            calendarFailed = !ok
                            working = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: option.symbol).font(.system(size: 12, weight: .semibold))
                            Text(option.title)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(UMButtonStyle(kind: .custom(on ? option.color : UM.field, on ? .white : UM.fg),
                                               height: 30, radius: 8))
                    .disabled(working)
                }
            }
            if calendarFailed {
                Text("Ответ сохранён, но в Календарь добавить не удалось — разрешите доступ в Настройки → Интеграции.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(Motion.snappy, value: answer)
    }
}

// MARK: - Код подтверждения

@MainActor
private struct CodeBlock: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Код подтверждения · действует 10 мин")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UM.fg3)
                Text(code)
                    .font(UM.mono(34, .semibold))
                    .tracking(4)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.replacingOccurrences(of: " ", with: ""), forType: .string)
                withAnimation(Motion.bouncy) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(Motion.smooth) { copied = false }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                    Text(copied ? "Скопировано" : "Скопировать")
                }
                .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(UMButtonStyle(kind: .custom(UM.teal, .white), height: 34, radius: 9, horizontal: 16))
            .shadow(color: UM.teal.opacity(0.3), radius: 1, y: 1)
        }
        .padding(.vertical, 18)
        .padding(.leading, 20)
        .padding(.trailing, 18)
        .umInset(radius: 12)
    }
}

// MARK: - HTML-письмо с плашкой приватности

@MainActor
private struct HTMLBody: View {
    let html: String
    let senderKnown: Bool
    @AppStorage("remoteImages") private var remotePolicy = 0
    @AppStorage("stripTrackers") private var stripTrackers = true
    @State private var allowRemote = false
    @State private var height: CGFloat = 200

    var body: some View {
        let allowed = allowRemote || remotePolicy == 2 || (remotePolicy == 1 && senderKnown)
        let prepared = HTMLSanitizer.prepare(html, allowRemote: allowed, stripTrackers: stripTrackers)
        VStack(alignment: .leading, spacing: 14) {
            if prepared.blockedImages > 0 || prepared.trackers > 0 || allowRemote {
                HStack(spacing: 9) {
                    Image(systemName: "shield.fill").font(.system(size: 14))
                    Text(privacyText(prepared, allowed: allowed))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if prepared.blockedImages > 0 || allowRemote {
                        Button(allowRemote ? "Скрыть" : "Показать изображения") {
                            withAnimation(Motion.smooth) { allowRemote.toggle() }
                        }
                        .buttonStyle(UMButtonStyle(kind: .custom(UM.privBtn, UM.privFg), height: 24, radius: 6, horizontal: 10))
                        .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundStyle(UM.privFg)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.privBg))
            }

            HTMLView(html: prepared.html, allowRemote: allowed, height: $height)
                .frame(height: height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        }
    }

    private func privacyText(_ p: HTMLSanitizer.Prepared, allowed: Bool) -> String {
        var parts: [String] = []
        if allowed {
            parts.append("Изображения показаны")
        } else if p.blockedImages > 0 {
            parts.append("Удалённые изображения скрыты: \(p.blockedImages)")
        }
        if p.trackers > 0 && stripTrackers {
            parts.append("Трекинг-пиксели вырезаны: \(p.trackers)")
        }
        return parts.joined(separator: " · ")
    }
}

extension MailStore {
    /// «Известный» отправитель — тот, кому мы хотя бы раз писали.
    func isKnownSender(_ email: String) -> Bool {
        let target = email.lowercased()
        return messages.values.contains { m in
            m.role == .sent && (m.to + m.cc).contains { $0.email.lowercased() == target }
        }
    }
}
