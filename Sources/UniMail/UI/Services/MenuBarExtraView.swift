import AppKit
import SwiftUI

/// Запоминает `openWindow` из SwiftUI-окружения для `WindowRouter` (показ главного окна из уведомлений).
struct OpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { WindowRouter.shared.openWindow = openWindow }
    }
}

/// Иконка в строке меню: конверт и число непрочитанных.
@MainActor
struct MenuBarLabel: View {
    let store: MailStore

    var body: some View {
        let count = store.totalInboxUnread
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "envelope.badge" : "envelope")
            if count > 0 {
                Text(count > 999 ? "999+" : "\(count)")
            }
        }
        .help(count > 0 ? "UniMail — непрочитанных: \(count)" : "UniMail")
    }
}

/// Окно из строки меню: последние непрочитанные треды и быстрые действия.
@MainActor
struct MenuBarPanel: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let items = store.latestUnreadThreads(limit: 8)
        let unread = store.totalInboxUnread

        VStack(alignment: .leading, spacing: 0) {
            header(unread: unread)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 8)

            Rectangle().fill(UM.sepStrong).frame(height: 0.5).padding(.horizontal, 8)

            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(UM.fg3)
                    Text("Непрочитанных писем нет")
                        .font(.system(size: 12.5))
                        .foregroundStyle(UM.fg2)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
            } else {
                VStack(spacing: 1) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(.vertical, 5)
            }

            MenuSeparator()

            MenuRow(symbol: "square.and.pencil", title: "Новое письмо") { newMessage() }
            MenuRow(symbol: "arrow.clockwise", title: "Проверить почту", detail: syncDetail) {
                Task { await store.refreshAll() }
            }
            MenuRow(symbol: "macwindow", title: "Открыть UniMail") {
                WindowRouter.shared.showMain(using: openWindow)
            }

            MenuSeparator()

            MenuRow(symbol: "power", title: "Выйти из UniMail") { NSApp.terminate(nil) }
        }
        .padding(6)
        .frame(width: 340)
        .foregroundStyle(UM.fg)
        .font(.system(size: 13))
        .tint(UM.accent)
        .onAppear { WindowRouter.shared.openWindow = openWindow }
    }

    private func header(unread: Int) -> some View {
        HStack(spacing: 10) {
            AllBoxesTile(size: 28, radius: 8, symbolSize: 13)
            VStack(alignment: .leading, spacing: 0) {
                Text("UniMail").font(.system(size: 13, weight: .semibold))
                Text(unread == 0
                     ? "Всё прочитано"
                     : "\(unread) \(plural(unread, "непрочитанное", "непрочитанных", "непрочитанных"))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg3)
            }
            Spacer(minLength: 8)
            if unread > 0 {
                CountPill(count: unread, prominent: true)
            }
        }
    }

    private func row(_ item: UnreadThreadItem) -> some View {
        let message = item.latest
        let account = store.account(message.accountID)
        return Button {
            WindowRouter.shared.showMain(using: openWindow)
            store.reveal(threadID: item.id)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                SenderAvatar(address: message.from, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(message.from.display)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if item.unreadCount > 1 {
                            Text("\(item.unreadCount)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(UM.fg2)
                                .padding(.horizontal, 5)
                                .frame(minHeight: 15)
                                .background(Capsule().fill(UM.seg))
                        }
                        Spacer(minLength: 4)
                        Text(RelativeDate.short(message.date))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(UM.fg3)
                    }
                    HStack(spacing: 5) {
                        if let account, store.accounts.count > 1 {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(account.tint.color)
                                .frame(width: 6, height: 6)
                        }
                        Text(message.subject.isEmpty ? "(без темы)" : message.subject)
                            .font(.system(size: 12))
                            .foregroundStyle(UM.fg2)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverStyle(radius: 7))
        .help(message.snippet)
    }

    private var syncDetail: String? {
        if !store.syncingAccountIDs.isEmpty { return "Проверяю…" }
        guard let last = store.lastSync else { return nil }
        return RelativeDate.clock(last)
    }

    private func newMessage() {
        store.compose()
        // Окно написания открываем сами: главного окна (и его RootView) может не быть.
        guard let request = store.composeQueue.popLast() else { return }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "compose", value: request)
    }
}
