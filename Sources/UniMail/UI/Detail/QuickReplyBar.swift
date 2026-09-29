import SwiftUI

/// Быстрый ответ под тредом: капсула «Быстрый ответ… R», по клику или R — редактор.
@MainActor
struct QuickReplyBar: View {
    @Environment(MailStore.self) var store
    let replyTo: Message

    @State var text = ""
    @State var isOpen = false
    @State var hovering = false
    @FocusState var focused: Bool

    private static let formatSymbols = ["bold", "italic", "list.bullet", "link", "paperclip", "face.smiling"]

    var body: some View {
        ZStack {
            if isOpen {
                editor
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else {
                capsule
                    .transition(.opacity)
            }
        }
        .animation(Motion.smooth, value: isOpen)
        .onChange(of: store.quickReplyRequest) { _, _ in open() }
    }

    private var capsule: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "arrowshape.turn.up.left").font(.system(size: 13))
                Text("Быстрый ответ…").font(.system(size: 13))
                Spacer()
                KeyHint(text: "R")
            }
            .foregroundStyle(UM.fg3)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 40)
            .background(Capsule().fill(UM.card))
            .overlay(Capsule().strokeBorder(hovering ? UM.sepStrong : UM.cardBorder, lineWidth: 0.5))
            .modifier(CardShadow(small: true))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left").font(.system(size: 12))
                (Text("Ответ: ") + Text(replyTo.from.display).foregroundColor(UM.fg).fontWeight(.medium))
                Spacer()
                Button {
                    store.compose(.reply, from: replyTo.id)
                    close()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Открыть в отдельном окне")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Свернуть")
            }
            .font(.system(size: 12))
            .foregroundStyle(UM.fg3)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .hairline(.bottom)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Напишите ответ…")
                        .font(.system(size: 13.5))
                        .foregroundStyle(UM.fg3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 12)
                    .focused($focused)
            }
            .frame(height: 110)

            HStack(spacing: 2) {
                ForEach(Self.formatSymbols, id: \.self) { symbol in
                    Button {} label: { Image(systemName: symbol).font(.system(size: 13)) }
                        .buttonStyle(ToolbarIconStyle(width: 28, height: 26, radius: 6, tint: UM.fg3))
                }
                Spacer()
                Text("⌘↩").font(.system(size: 11)).foregroundStyle(UM.fg3).padding(.trailing, 8)
                Button(action: send) {
                    HStack(spacing: 5) {
                        Text("Отправить")
                        Image(systemName: "paperplane.fill").font(.system(size: 11))
                    }
                }
                .buttonStyle(UMButtonStyle(kind: .primary, height: 28, radius: 8, horizontal: 14))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .umCard(radius: 14)
    }

    private func open() {
        withAnimation(Motion.smooth) { isOpen = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private func close() {
        withAnimation(Motion.smooth) {
            isOpen = false
            text = ""
        }
    }

    private func send() {
        guard let account = store.account(replyTo.accountID) else { return }
        let myEmails = Set([account.email] + account.aliases)
        let recipient = myEmails.contains(replyTo.from.email) ? (replyTo.to.first ?? replyTo.from) : replyTo.from
        let draft = OutgoingMessage(
            accountID: account.id,
            fromAddress: account.email,
            to: [recipient],
            cc: [], bcc: [],
            subject: ComposeRequest.prefixed("Re:", replyTo.subject),
            body: text + ComposeRequest.quote(replyTo),
            inReplyTo: replyTo.id,
            threadID: replyTo.threadID
        )
        store.send(draft, requestID: UUID(), undoTitle: "Ответ отправлен")
        close()
    }
}
