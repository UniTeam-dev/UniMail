import SwiftUI

/// Строка треда: точка «не прочитано», аватар с меткой аккаунта, имя, счётчик, скрепка, флаг, время,
/// тема и превью. Три плотности — как в макете.
@MainActor
struct ThreadRow: View {
    let thread: ThreadSummary
    let account: Account?
    let showAccount: Bool
    let isSelected: Bool
    let density: ListDensity

    @State var isHovered = false

    private var message: Message { thread.latest }
    private var unread: Bool { thread.hasUnread }
    private var outgoing: Bool { [.sent, .drafts, .scheduled].contains(message.role) }

    /// В «Отправленных» и «Черновиках» интереснее получатель.
    private var counterpart: Address { outgoing ? (message.to.first ?? message.from) : message.from }

    private var senderLine: String {
        if outgoing { return "Кому: \(counterpart.display)" }
        let others = thread.participants.filter { $0.email != account?.email }
        if others.count > 1 {
            return others.prefix(3).map { $0.display.components(separatedBy: " ").first ?? $0.display }.joined(separator: ", ")
        }
        return counterpart.display
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // Точка «не прочитано»
            Circle()
                .fill(UM.accent)
                .frame(width: 8, height: 8)
                .scaleEffect(unread ? 1 : 0.3)
                .opacity(unread ? 1 : 0)
                .frame(width: 8, height: density == .compact ? 18 : density.avatar)
                .animation(Motion.bouncy, value: unread)

            SenderAvatar(address: counterpart, size: density.avatar, fontSize: density.avatarFont)
                .overlay(alignment: .bottomTrailing) {
                    if showAccount, let account {
                        Circle()
                            .fill(account.tint.color)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(UM.list, lineWidth: 2).padding(-2))
                            .offset(x: 2, y: 2)
                    }
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(senderLine)
                        .font(.system(size: 13, weight: unread ? .bold : .medium))
                        .lineLimit(1)
                    if thread.count > 1 {
                        Text("\(thread.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(UM.fg3)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(UM.seg))
                    }
                    Spacer(minLength: 4)
                    if thread.hasAttachments {
                        Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(UM.fg3)
                    }
                    if thread.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(UM.orange)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(dateText)
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(unread ? UM.accent : UM.fg3)
                        .lineLimit(1)
                }
                .frame(height: 18)

                subjectLine
                    .padding(.top, density.subjectTop)

                if density.showsPreview {
                    Text(message.snippet)
                        .font(.system(size: 12.5))
                        .foregroundStyle(UM.fg3)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
        .padding(density.padding)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? UM.selRow : (isHovered ? UM.hover : Color.clear))
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(Motion.bouncy, value: thread.isFlagged)
    }

    @ViewBuilder
    private var subjectLine: some View {
        let subject = Text(message.subject)
            .font(.system(size: density.subjectSize, weight: unread ? .semibold : .regular))
            .foregroundColor(UM.fg)
        if density == .compact {
            (subject + Text("  —  " + message.snippet).font(.system(size: density.subjectSize)).foregroundColor(UM.fg3))
                .lineLimit(1)
        } else {
            subject.lineLimit(1)
        }
    }

    private var dateText: String {
        if message.role == .snoozed, let until = message.snoozedUntil {
            return RelativeDate.preset(until)
        }
        if message.role == .scheduled, let at = message.scheduledAt {
            return RelativeDate.preset(at)
        }
        return RelativeDate.short(message.date)
    }
}

/// Свайп строки: вправо — зелёный «Архив», влево — оранжевый «Отложить».
@MainActor
struct SwipeableRow<Content: View>: View {
    @Environment(MailStore.self) private var store
    let threadID: String
    @ViewBuilder var content: () -> Content

    @State var offset: CGFloat = 0
    let threshold: CGFloat = 90

    var body: some View {
        ZStack {
            if offset > 0 {
                swipeBackground(color: UM.green, symbol: "archivebox.fill", title: "Архив", leading: true)
            } else if offset < 0 {
                swipeBackground(color: UM.orange, symbol: "clock.fill", title: "Отложить", leading: false)
            }
            content()
                .background {
                    if offset != 0 {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(UM.list)
                            .padding(.horizontal, 8)
                            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    }
                }
                .offset(x: offset)
        }
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    offset = value.translation.width
                }
                .onEnded { value in
                    let width = value.translation.width
                    if abs(width) > threshold {
                        // Строка улетает за край, затем уходит из списка.
                        withAnimation(Motion.list) { offset = width > 0 ? 400 : -400 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                            if width > 0 {
                                store.archive(threadIDs: [threadID])
                            } else {
                                let preset = TimePreset.tomorrowMorning
                                store.snooze(threadIDs: [threadID], until: preset.date, label: preset.title)
                            }
                            offset = 0
                        }
                    } else {
                        withAnimation(Motion.release) { offset = 0 }
                    }
                }
        )
    }

    private func swipeBackground(color: Color, symbol: String, title: String, leading: Bool) -> some View {
        HStack(spacing: 7) {
            if !leading {
                Spacer()
                Text(title)
            }
            Image(systemName: symbol)
                .font(.system(size: 16))
                .scaleEffect(abs(offset) > threshold ? 1.15 : 1)
            if leading {
                Text(title)
                Spacer()
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .opacity(min(abs(offset) / 40, 1))
        .animation(Motion.bouncy, value: abs(offset) > threshold)
    }
}
