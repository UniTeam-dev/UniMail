import AppKit
import SwiftUI

/// Одно письмо внутри треда. Свёрнутое — одна строка, развёрнутое — полное тело.
@MainActor
struct MessageCard: View {
    @Environment(MailStore.self) var store
    let message: Message
    let account: Account?
    let isExpanded: Bool
    var onToggle: () -> Void

    @State var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    MessageBody(message: message)
                    if !message.attachments.isEmpty {
                        AttachmentStrip(attachments: message.attachments)
                    }
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.10 : 0.05), radius: isHovered ? 10 : 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .onHover { hovering in withAnimation(Motion.smooth) { isHovered = hovering } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SenderAvatar(address: message.from, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.from.display).font(.system(size: 13, weight: .semibold))
                    Text(message.from.email).font(.caption).foregroundStyle(.tertiary)
                }
                if isExpanded {
                    Text("Кому: " + (message.to + message.cc).map(\.display).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(message.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isHovered && isExpanded {
                HStack(spacing: 2) {
                    iconButton("arrowshape.turn.up.left", "Ответить") { store.compose(.reply, from: message.id) }
                    iconButton("arrowshape.turn.up.right", "Переслать") { store.compose(.forward, from: message.id) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Text(RelativeDate.long(message.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func iconButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

/// Тело письма: HTML в изолированном WKWebView или обычный текст.
@MainActor
struct MessageBody: View {
    let message: Message
    @AppStorage("loadRemoteImages") var loadRemoteByDefault = false
    @State var allowRemote = false
    @State var height: CGFloat = 60

    var body: some View {
        if let html = message.htmlBody {
            let prepared = HTMLSanitizer.prepare(html, allowRemote: allowRemote || loadRemoteByDefault)
            VStack(alignment: .leading, spacing: 10) {
                if prepared.blockedImages > 0 || prepared.trackers > 0 {
                    PrivacyBanner(blocked: prepared.blockedImages, trackers: prepared.trackers) {
                        withAnimation(Motion.smooth) { allowRemote = true }
                    }
                }
                HTMLView(html: prepared.html, allowRemote: allowRemote || loadRemoteByDefault, height: $height)
                    .frame(height: height)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .animation(Motion.smooth, value: height)
            }
        } else {
            Text(message.body)
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private struct PrivacyBanner: View {
    let blocked: Int
    let trackers: Int
    var onAllow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 1) {
                if blocked > 0 {
                    Text("Удалённые изображения скрыты: \(blocked)")
                }
                if trackers > 0 {
                    Text("Трекинг-пиксели вырезаны: \(trackers) — отправитель не узнает, что вы открыли письмо")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Spacer()
            if blocked > 0 {
                Button("Показать изображения", action: onAllow).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.indigo.opacity(0.08)))
    }
}

@MainActor
struct AttachmentStrip: View {
    let attachments: [Attachment]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentChip(attachment: attachment)
            }
        }
    }
}

@MainActor
private struct AttachmentChip: View {
    let attachment: Attachment
    @State var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename).font(.caption.weight(.medium)).lineLimit(1)
                Text(attachment.sizeText).font(.caption2).foregroundStyle(.secondary)
            }
            if hovering {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.9 : 0.5)))
        .scaleEffect(hovering ? 1.02 : 1)
        .onHover { h in withAnimation(Motion.bouncy) { hovering = h } }
        .help("Quick Look и сохранение — после подключения настоящих аккаунтов")
    }
}
