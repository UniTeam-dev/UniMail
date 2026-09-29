import AppKit
import SwiftUI

/// Правая колонка: открытый тред.
@MainActor
struct ThreadDetailView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        Group {
            if let id = store.selectedThreadID, !store.thread(id).isEmpty {
                ThreadContent(threadID: id)
                    .id(id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 14)),
                        removal: .opacity
                    ))
            } else {
                EmptyDetail()
                    .transition(.opacity)
            }
        }
        .animation(Motion.smooth, value: store.selectedThreadID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}

@MainActor
private struct EmptyDetail: View {
    @State private var float = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "envelope.open")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.tertiary)
                .offset(y: float ? -4 : 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { float = true }
                }
            Text("Выберите письмо").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                shortcut("⌘K", "Командная палитра")
                shortcut("⌘1…9", "Переключить ящик")
                shortcut("J / K", "Следующее / предыдущее")
                shortcut("E", "В архив")
                shortcut("H", "Отложить до утра")
                shortcut("R", "Ответить")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary))
                .frame(width: 64, alignment: .leading)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct ThreadContent: View {
    @Environment(MailStore.self) private var store
    let threadID: String
    @State private var expanded: Set<String> = []

    var body: some View {
        let messages = store.thread(threadID)
        let last = messages.last

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                subjectHeader(messages)

                if let invite = messages.last(where: \.hasInvite) {
                    InviteBanner(message: invite)
                }
                if let code = messages.compactMap({ OneTimeCode.find(in: $0) }).last {
                    CodeBanner(code: code)
                }

                ForEach(messages) { message in
                    MessageCard(
                        message: message,
                        account: store.account(message.accountID),
                        isExpanded: expanded.contains(message.id) || message.id == last?.id
                    ) {
                        withAnimation(Motion.smooth) {
                            if expanded.contains(message.id) { expanded.remove(message.id) } else { expanded.insert(message.id) }
                        }
                    }
                }

                if let last {
                    QuickReplyBar(replyTo: last)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // Непрочитанные письма треда раскрыты сразу.
            expanded = Set(messages.filter { !$0.isRead }.map(\.id))
        }
        .toolbar { toolbar(last: last) }
    }

    private func subjectHeader(_ messages: [Message]) -> some View {
        let subject = messages.last?.subject ?? ""
        let accounts = Set(messages.map(\.accountID)).compactMap { store.account($0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(subject)
                .font(.system(size: 22, weight: .bold))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                ForEach(accounts) { AccountChip(account: $0) }
                if messages.count > 1 {
                    Text("\(messages.count) письма в треде")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if messages.contains(where: \.isFlagged) {
                    Label("Важное", systemImage: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(last: Message?) -> some ToolbarContent {
        let ids = [threadID]
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                BounceIconButton(title: "Ответить", symbol: "arrowshape.turn.up.left") {
                    if let last { store.compose(.reply, from: last.id) }
                }
                BounceIconButton(title: "Ответить всем", symbol: "arrowshape.turn.up.left.2") {
                    if let last { store.compose(.replyAll, from: last.id) }
                }
                BounceIconButton(title: "Переслать", symbol: "arrowshape.turn.up.right") {
                    if let last { store.compose(.forward, from: last.id) }
                }
            }

            BounceIconButton(title: "В архив", symbol: "archivebox") { store.archive(threadIDs: ids) }
            BounceIconButton(title: "Удалить", symbol: "trash") { store.trash(threadIDs: ids) }
            BounceIconButton(
                title: "Флажок",
                symbol: store.thread(threadID).contains(where: \.isFlagged) ? "flag.fill" : "flag"
            ) { store.toggleFlag(threadIDs: ids) }

            Menu {
                ForEach(TimePreset.allCases) { preset in
                    Button("\(preset.title) — \(preset.subtitle)", systemImage: preset.symbol) {
                        store.snooze(threadIDs: ids, until: preset.date)
                    }
                }
            } label: {
                Label("Отложить", systemImage: "clock")
            }
            .help("Отложить")

            Menu {
                Button("Прочитано / не прочитано", systemImage: "envelope.badge") { store.toggleRead(threadIDs: ids) }
                Button("Во входящие", systemImage: "tray") { store.moveToInbox(threadIDs: ids) }
                Button("Это спам", systemImage: "xmark.bin") { store.markSpam(threadIDs: ids) }
            } label: {
                Label("Ещё", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Контекстные кнопки

/// Код подтверждения в письме → кнопка «Скопировать».
enum OneTimeCode {
    static func find(in message: Message) -> String? {
        let text = message.subject + " " + message.body
        guard text.lowercased().contains("код") || text.lowercased().contains("code") else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{3})[ -]?(\d{3})\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text),
              let b = Range(match.range(at: 2), in: text) else { return nil }
        return String(text[a]) + String(text[b])
    }
}

@MainActor
private struct CodeBanner: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(.teal)
            Text("Код подтверждения").foregroundStyle(.secondary)
            Text(code).font(.system(.title3, design: .monospaced).weight(.bold)).kerning(2)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                withAnimation(Motion.bouncy) { copied = true }
            } label: {
                Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.teal.opacity(0.1)))
    }
}

@MainActor
private struct InviteBanner: View {
    let message: Message
    @State private var answer: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(message.date.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 2).background(.red)
                Text(message.date.formatted(.dateTime.day()))
                    .font(.title2.weight(.semibold)).padding(.vertical, 2)
            }
            .frame(width: 46)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Приглашение на встречу").font(.headline)
                Text(answer.map { "Ваш ответ: \($0)" } ?? "Добавьте в календарь и ответьте организатору")
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            if answer == nil {
                HStack(spacing: 6) {
                    Button("Принять") { respond("принято") }.buttonStyle(.borderedProminent).tint(.green)
                    Button("Возможно") { respond("возможно") }
                    Button("Отклонить") { respond("отклонено") }
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.07)))
    }

    private func respond(_ text: String) {
        // Этап 6: iTIP-ответ организатору + запись в календарь через EventKit / Graph / Google Calendar.
        withAnimation(Motion.bouncy) { answer = text }
    }
}
