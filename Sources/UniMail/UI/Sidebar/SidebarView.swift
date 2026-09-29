import SwiftUI

/// Левая колонка: панель аккаунтов + папки выбранного ящика.
@MainActor
struct SidebarView: View {
    var body: some View {
        HStack(spacing: 0) {
            AccountRail()
            Divider().opacity(0.5)
            MailboxList()
        }
        .toolbar(removing: .sidebarToggle)
    }
}

// MARK: - Панель аккаунтов

@MainActor
struct AccountRail: View {
    @Environment(MailStore.self) private var store
    @Namespace private var selectionNS
    @State private var isAddingAccount = false

    var body: some View {
        VStack(spacing: 10) {
            RailItem(
                isSelected: store.scope.accountID == nil,
                namespace: selectionNS,
                unread: store.unreadCount(.unified(.inbox)),
                isSyncing: !store.syncingAccountIDs.isEmpty,
                hasError: false,
                help: "Все ящики (⌘0)"
            ) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.blended(with: .purple, by: 0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "tray.2.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 40, height: 40)
            } action: {
                store.switchTo(index: 0)
            }

            Capsule().fill(.quaternary).frame(width: 24, height: 2)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        RailItem(
                            isSelected: store.scope.accountID == account.id,
                            namespace: selectionNS,
                            unread: store.unreadCount(.account(account.id, .inbox)),
                            isSyncing: store.syncingAccountIDs.contains(account.id),
                            hasError: store.accountErrors[account.id] != nil,
                            help: "\(account.displayName) — \(account.email)" + (index < 9 ? " (⌘\(index + 1))" : "")
                        ) {
                            AccountAvatar(account: account)
                                .opacity(store.hiddenAccountIDs.contains(account.id) ? 0.45 : 1)
                        } action: {
                            store.switchTo(index: index + 1)
                        }
                        .contextMenu { accountMenu(account) }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)

            Button { isAddingAccount = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Добавить аккаунт")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Настройки (⌘,)")
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: 66)
        .sheet(isPresented: $isAddingAccount) {
            AddAccountView()
        }
    }

    @ViewBuilder
    private func accountMenu(_ account: Account) -> some View {
        Button("Проверить почту") { Task { await store.refresh(accountID: account.id) } }
        Button(store.hiddenAccountIDs.contains(account.id) ? "Показывать в «Все ящики»" : "Скрыть из «Все ящики»") {
            store.toggleHidden(account.id)
        }
        Divider()
        Button("Удалить аккаунт…", role: .destructive) { store.removeAccount(account.id) }
    }
}

/// Элемент панели аккаунтов: подсветка выбора переезжает между элементами (matchedGeometryEffect).
@MainActor
private struct RailItem<Icon: View>: View {
    let isSelected: Bool
    let namespace: Namespace.ID
    let unread: Int
    let isSyncing: Bool
    let hasError: Bool
    let help: String
    @ViewBuilder var icon: () -> Icon
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .matchedGeometryEffect(id: "rail-selection", in: namespace)
                        .frame(width: 52, height: 52)
                }
                icon()
                    .scaleEffect(isHovered ? 1.07 : 1)
                    .overlay {
                        if isSyncing {
                            SyncRing()
                        }
                    }
            }
            .frame(width: 54, height: 52)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 22)
                        .offset(x: -6)
                        .matchedGeometryEffect(id: "rail-indicator", in: namespace)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hasError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, .orange)
                        .offset(x: -2, y: 2)
                } else {
                    CountBadge(count: unread, tint: .red)
                        .scaleEffect(0.85)
                        .offset(x: 2, y: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(Motion.bouncy) { isHovered = hovering }
        }
        .animation(Motion.bouncy, value: unread)
    }
}

/// Вращающееся кольцо «идёт синхронизация».
private struct SyncRing: View {
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 48, height: 48)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { rotation = 360 }
            }
            .transition(.opacity)
    }
}
