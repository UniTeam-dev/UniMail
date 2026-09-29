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
                if isNewsletter {
                    InfoChip {
                        Text("Рассылка ·")
                        Text("Отписаться").foregroundStyle(UM.accent).fontWeight(.medium)
                    }
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

            if let invite = message.invite {
                InviteBlock(invite: invite).padding(.top, 16)
            }
            if let code = message.detectedCode {
                CodeBlock(code: code).padding(.top, 16)
            }

            if let html = message.htmlBody {
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
                    ForEach(message.attachments) { AttachmentChip(attachment: $0) }
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
}

// MARK: - Приглашение

@MainActor
private struct InviteBlock: View {
    let invite: Invite
    @State private var answer: String?

    private struct RSVP: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var color: Color
    }

    private let options = [
        RSVP(id: "yes", title: "Принять", symbol: "checkmark", color: UM.green),
        RSVP(id: "maybe", title: "Возможно", symbol: "questionmark", color: UM.orange),
        RSVP(id: "no", title: "Отклонить", symbol: "xmark", color: UM.red),
    ]

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
                        // Этап 6: iTIP-ответ организатору + запись в Календарь через EventKit.
                        withAnimation(Motion.snappy) { answer = on ? nil : option.id }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: option.symbol).font(.system(size: 12, weight: .semibold))
                            Text(option.title)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(UMButtonStyle(kind: .custom(on ? option.color : UM.field, on ? .white : UM.fg),
                                               height: 30, radius: 8))
                }
            }
        }
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
