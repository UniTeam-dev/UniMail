import AppKit
import SwiftUI

/// Строка треда в списке.
@MainActor
struct ThreadRow: View {
    let thread: ThreadSummary
    let account: Account?
    let showAccount: Bool
    let isSelected: Bool
    let density: ListDensity
    let namespace: Namespace.ID

    @State var isHovered = false

    private var message: Message { thread.latest }
    private var unread: Bool { thread.hasUnread }

    /// В «Отправленных» и «Черновиках» интереснее получатель, чем мы сами.
    private var counterpart: Address {
        [.sent, .drafts, .scheduled].contains(message.role) ? (message.to.first ?? message.from) : message.from
    }

    private var senderLine: String {
        let names = thread.participants.map { $0.display.components(separatedBy: " ").first ?? $0.display }
        if thread.participants.count > 1 {
            return names.prefix(3).joined(separator: ", ")
        }
        return [.sent, .drafts, .scheduled].contains(message.role) ? "Кому: \(counterpart.display)" : counterpart.display
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Точка «не прочитано»
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .scaleEffect(unread ? 1 : 0.01)
                .opacity(unread ? 1 : 0)
                .padding(.top, density == .compact ? 6 : 13)
                .animation(Motion.bouncy, value: unread)

            if density != .compact {
                SenderAvatar(address: counterpart, size: 34)
                    .overlay(alignment: .bottomTrailing) {
                        if showAccount, let account {
                            Circle()
                                .fill(account.tint.color)
                                .frame(width: 11, height: 11)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                                .offset(x: 2, y: 2)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(senderLine)
                        .font(.system(size: 13, weight: unread ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.count > 1 {
                        Text("\(thread.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().strokeBorder(.tertiary))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if thread.hasAttachments {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                    }
                    if thread.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(unread ? Color.accentColor : .secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 6) {
                    if message.hasInvite {
                        Image(systemName: "calendar").font(.caption).foregroundStyle(.red)
                    }
                    Text(message.subject)
                        .font(.system(size: 13, weight: unread ? .medium : .regular))
                        .foregroundStyle(unread ? .primary : .secondary)
                        .lineLimit(1)
                }

                if density.showsSnippet {
                    Text(message.snippet)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(density == .spacious ? 3 : 2)
                }

                if showAccount, let account, density == .spacious {
                    AccountChip(account: account).padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, density.verticalPadding)
        .background {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "row-selection", in: namespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                }
            }
        }
        .overlay(alignment: .leading) {
            if showAccount, let account, density == .compact {
                Capsule().fill(account.tint.color).frame(width: 3).padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Motion.snappy) { isHovered = hovering }
        }
        .animation(Motion.bouncy, value: thread.isFlagged)
    }

    private var dateText: String {
        if message.role == .snoozed, let until = message.snoozedUntil {
            return "⏰ " + RelativeDate.short(until)
        }
        if message.role == .scheduled, let at = message.scheduledAt {
            return "🕓 " + RelativeDate.short(at)
        }
        return RelativeDate.short(message.date)
    }
}

/// Свайп строки мышью/трекпадом с зажатой кнопкой: вправо — архив, влево — отложить.
/// (Двухпальцевые свайпы трекпада без нажатия — этап 7, через NSEvent scrollWheel.)
@MainActor
struct SwipeableRow<Content: View>: View {
    var onArchive: () -> Void
    var onSnooze: () -> Void
    @ViewBuilder var content: () -> Content

    @State var offset: CGFloat = 0
    let threshold: CGFloat = 90

    var body: some View {
        ZStack {
            HStack {
                action(symbol: "archivebox.fill", title: "Архив", color: .green, active: offset > threshold)
                    .opacity(offset > 0 ? 1 : 0)
                Spacer()
                action(symbol: "clock.fill", title: "Отложить", color: .orange, active: -offset > threshold)
                    .opacity(offset < 0 ? 1 : 0)
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((offset > 0 ? Color.green : Color.orange).opacity(min(abs(offset) / threshold, 1) * 0.22))
            )

            content()
                .background(Color(nsColor: .controlBackgroundColor).opacity(offset == 0 ? 0 : 1),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .offset(x: offset)
        }
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    offset = value.translation.width
                }
                .onEnded { value in
                    let width = value.translation.width
                    if width > threshold {
                        withAnimation(Motion.snappy) { offset = 600 }
                        onArchive()
                    } else if width < -threshold {
                        withAnimation(Motion.snappy) { offset = -600 }
                        onSnooze()
                    }
                    withAnimation(Motion.bouncy) { offset = 0 }
                }
        )
    }

    private func action(symbol: String, title: String, color: Color, active: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .scaleEffect(active ? 1.2 : 1)
            Text(title).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .animation(Motion.bouncy, value: active)
    }
}
