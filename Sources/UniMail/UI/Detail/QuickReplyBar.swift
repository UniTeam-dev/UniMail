import AppKit
import SwiftUI

/// Быстрый ответ прямо под тредом. Разворачивается по клику.
@MainActor
struct QuickReplyBar: View {
    @Environment(MailStore.self) var store
    let replyTo: Message

    @State var text = ""
    @State var isActive = false
    @FocusState var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isActive {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.secondary)
                    Text("Ответ для \(replyTo.from.display)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Открыть в окне") {
                        store.compose(.reply, from: replyTo.id)
                        collapse()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90, maxHeight: 220)
                    .focused($focused)
                HStack {
                    Button("Отмена", action: collapse)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button {
                        send()
                    } label: {
                        Label("Отправить", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack(spacing: 10) {
                    if let account = store.account(replyTo.accountID) {
                        AccountAvatar(account: account, size: 26)
                    }
                    Text("Быстрый ответ…").foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Motion.smooth) { isActive = true }
                    focused = true
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isActive ? 0.12 : 0.04), radius: isActive ? 12 : 3, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06))
        )
    }

    private func collapse() {
        withAnimation(Motion.smooth) {
            isActive = false
            text = ""
        }
    }

    private func send() {
        guard let account = store.account(replyTo.accountID) else { return }
        let draft = OutgoingMessage(
            accountID: account.id,
            fromAddress: account.email,
            to: [replyTo.role == .sent ? (replyTo.to.first ?? replyTo.from) : replyTo.from],
            cc: [], bcc: [],
            subject: ComposeRequest.prefixed("Re:", replyTo.subject),
            body: text + ComposeRequest.quote(replyTo),
            inReplyTo: replyTo.id,
            threadID: replyTo.threadID
        )
        store.send(draft, requestID: UUID())
        collapse()
    }
}
