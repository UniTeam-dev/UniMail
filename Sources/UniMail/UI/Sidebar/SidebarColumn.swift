import SwiftUI

/// Левая колонка: панель аккаунтов (66 pt) + папки или календарь (210 pt) на вибрантном фоне.
@MainActor
struct SidebarColumn: View {
    @Environment(MailStore.self) private var store
    let foldersWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            AccountRail()
                .frame(width: 66)
                .frame(maxHeight: .infinity)
                .background(UM.rail)
                .hairline(.trailing)

            VStack(spacing: 0) {
                Color.clear.frame(height: 52)
                BoxHeader()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)

                if store.mode == .mail {
                    FolderList()
                        .transition(.opacity)
                } else {
                    ScheduleSidebar()
                        .transition(.opacity)
                }

                Spacer(minLength: 0)
                SyncFooter()
            }
            .frame(width: foldersWidth)
        }
        .background {
            ZStack {
                VisualEffect(material: .sidebar, blending: .behindWindow)
                UM.side
            }
        }
        .hairline(.trailing)
    }
}

// MARK: - Панель аккаунтов

@MainActor
struct AccountRail: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var isAddingAccount = false

    private func tileTop(_ index: Int) -> CGFloat { 116 + CGFloat(index) * 52 }

    /// Смещение подложки: 46 для «Все ящики», 110 + 52·i для аккаунтов.
    private var selectionY: CGFloat {
        guard let id = store.scope.accountID, let index = store.accounts.firstIndex(where: { $0.id == id }) else { return 46 }
        return 110 + CGFloat(index) * 52
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Подложка выбора и «таблетка» слева.
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(UM.selSide)
                .frame(width: 52, height: 52)
                .offset(x: 7, y: selectionY)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 3, topTrailingRadius: 3)
                .fill(UM.fg)
                .frame(width: 4, height: 20)
                .offset(y: selectionY + 16)

            Button { store.switchToAccount(nil) } label: {
                AllBoxesTile()
            }
            .buttonStyle(TileStyle())
            .help("Все ящики · ⌘1")
            .offset(x: 13, y: 52)

            Rectangle().fill(UM.sepStrong).frame(width: 26, height: 1).offset(x: 20, y: 104)

            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                RailAccount(account: account, index: index)
                    .offset(x: 13, y: tileTop(index))
            }

            VStack(spacing: 12) {
                Button { isAddingAccount = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16))
                        .foregroundStyle(UM.fg2)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(UM.fg3, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
                .buttonStyle(HoverStyle(radius: 12))
                .help("Добавить аккаунт")

                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(UM.fg2)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(HoverStyle(radius: 9))
                .help("Настройки · ⌘,")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Motion.rail, value: selectionY)
        .sheet(isPresented: $isAddingAccount) {
            AddAccountView()
        }
    }
}

/// Нажатие по плитке — сжатие до 0.9 и пружинка.
struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
    }
}

@MainActor
private struct RailAccount: View {
    @Environment(MailStore.self) private var store
    let account: Account
    let index: Int

    var body: some View {
        let unread = store.unreadCount(.account(account.id, .inbox))
        let failed = store.accountErrors[account.id] != nil
        let syncing = store.syncingAccountIDs.contains(account.id) && !failed

        Button { store.switchToAccount(account.id) } label: {
            AccountTile(account: account)
                .opacity(account.hiddenFromUnified == true && store.scope.accountID == nil ? 0.5 : 1)
        }
        .buttonStyle(TileStyle())
        .overlay {
            if syncing {
                SyncRing(color: account.tint.color)
            }
        }
        .overlay(alignment: .topTrailing) {
            if unread > 0 && !failed {
                RailBadge(count: unread)
                    .fixedSize()
                    .offset(x: 7, y: -6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if failed {
                Text("!")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(UM.orange))
                    .overlay(Circle().strokeBorder(UM.railSolid, lineWidth: 2).padding(-2))
                    .offset(x: 5, y: 5)
            }
        }
        .animation(Motion.bouncy, value: unread)
        .help("\(account.displayName) — \(account.email)" + (index < 8 ? " · ⌘\(index + 2)" : ""))
        .contextMenu {
            Button("Проверить почту") { Task { await store.refresh(accountID: account.id) } }
            Button(account.hiddenFromUnified == true ? "Показывать в «Все ящики»" : "Скрыть из «Все ящики»") {
                store.toggleHidden(account.id)
            }
            Divider()
            Button("Удалить аккаунт", role: .destructive) { store.removeAccount(account.id) }
        }
    }
}

/// Кольцо синхронизации: дуга цвета аккаунта вращается вокруг плитки.
/// При «Уменьшить движение» — пульсирует.
private struct SyncRing: View {
    let color: Color
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 48, height: 48)
            .opacity(Motion.reduce ? (spin ? 0.3 : 0.8) : 0.8)
            .rotationEffect(.degrees(Motion.reduce ? -45 : (spin ? 315 : -45)))
            .onAppear {
                let animation: Animation = Motion.reduce
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .linear(duration: 1.1).repeatForever(autoreverses: false)
                withAnimation(animation) { spin = true }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Заголовок ящика

@MainActor
private struct BoxHeader: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let account = store.scope.accountID.flatMap { store.account($0) }
        let title: String
        let subtitle: String
        if store.mode == .schedule {
            title = "Расписание"
            let calendars = store.accounts.count + (CalendarService.shared.access.canRead ? CalendarService.shared.calendars.count : 0)
            let queued = store.messages.values.filter { $0.role == .scheduled }.count
            subtitle = "\(calendars) \(plural(calendars, "календарь", "календаря", "календарей")) · \(queued) \(plural(queued, "письмо", "письма", "писем")) в очереди"
        } else if let account {
            title = account.displayName
            subtitle = account.email
        } else {
            title = "Все ящики"
            let n = store.accounts.count
            subtitle = "\(n) \(plural(n, "аккаунт", "аккаунта", "аккаунтов")) в одном списке"
        }

        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(UM.fg3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .id("\(store.mode.rawValue)-\(store.scope.accountID?.uuidString ?? "all")")
            .transition(Motion.reduce ? AnyTransition.opacity : .push(from: .bottom).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(Motion.smooth, value: store.scope.accountID)
        .animation(Motion.smooth, value: store.mode)
    }
}

// MARK: - Папки

@MainActor
private struct FolderList: View {
    @Environment(MailStore.self) private var store
    @Namespace private var selectionNS

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MailboxRole.primary) { role in row(role) }
                SectionLabel(text: "Ещё")
                ForEach(MailboxRole.secondary) { role in row(role) }

                if let accountID = store.scope.accountID {
                    let folders = visibleFolders(accountID)
                    if !folders.isEmpty {
                        SectionLabel(text: "Папки").padding(.top, 6)
                        ForEach(folders) { folder in folderRow(folder, accountID: accountID) }
                    }
                } else {
                    SectionLabel(text: "Показывать ящики").padding(.top, 6)
                    ForEach(store.accounts) { account in eye(account) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .animation(Motion.snappy, value: store.scope)
    }

    // MARK: Свои папки

    @State private var collapsed: Set<String> = []

    /// Папки без свёрнутых веток.
    private func visibleFolders(_ accountID: UUID) -> [MailFolder] {
        let all = store.folders(of: accountID)
        guard !collapsed.isEmpty else { return all }
        let parents = Dictionary(all.map { ($0.id, $0.parentID) }, uniquingKeysWith: { a, _ in a })
        return all.filter { folder in
            var parent = folder.parentID
            while let id = parent {
                if collapsed.contains(id) { return false }
                parent = parents[id] ?? nil
            }
            return true
        }
    }

    private func folderRow(_ folder: MailFolder, accountID: UUID) -> some View {
        let scope = MailScope.folder(accountID, folder.id)
        let isSelected = store.scope == scope && store.searchText.isEmpty
        let count = store.folderUnread(folder, accountID: accountID)
        let hasChildren = store.folders(of: accountID).contains { $0.parentID == folder.id }
        let isCollapsed = collapsed.contains(folder.id)
        let syncing = store.isSyncingFolder(accountID: accountID, key: folder.id)

        return Button {
            store.searchText = ""
            store.select(scope: scope)
        } label: {
            HStack(spacing: 7) {
                Group {
                    if hasChildren {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(UM.fg3)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 12, height: 20)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(Motion.snappy) {
                                    if isCollapsed { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
                                }
                            }
                    } else {
                        Color.clear.frame(width: 12, height: 1)
                    }
                }
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? UM.accent : UM.fg2)
                    .frame(width: 18)
                Text(folder.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if syncing {
                    ProgressView().controlSize(.mini)
                } else if count > 0 {
                    CountPill(count: count, prominent: false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 2 + CGFloat(min(folder.depth, 6)) * 12)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(UM.selSide)
                        .matchedGeometryEffect(id: "folder", in: selectionNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folder.name)
        .contextMenu {
            Button("Отметить все как прочитанные") { store.markAllRead(in: scope) }
                .disabled(count == 0)
            Button("Обновить папку") { Task { await store.refreshFolder(accountID: accountID, key: folder.id) } }
        }
        .animation(Motion.bouncy, value: count)
    }

    private func row(_ role: MailboxRole) -> some View {
        let scope = store.scope.with(role: role)
        let isSelected = store.scope == scope && store.searchText.isEmpty
        let count: Int = {
            switch role.counter {
            case .unread: return store.unreadCount(scope)
            case .total: return store.totalCount(scope)
            case .none: return 0
            }
        }()

        return Button {
            store.searchText = ""
            store.select(scope: scope)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? role.selectedSymbol : role.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? UM.accent : UM.fg2)
                    .frame(width: 20)
                Text(role.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    CountPill(count: count, prominent: role == .inbox)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(UM.selSide)
                        .matchedGeometryEffect(id: "folder", in: selectionNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Отметить все как прочитанные") { store.markAllRead(in: scope) }
                .disabled(store.unreadCount(scope) == 0)
        }
        .animation(Motion.bouncy, value: count)
    }

    private func eye(_ account: Account) -> some View {
        let hidden = account.hiddenFromUnified == true
        return Button { store.toggleHidden(account.id) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(account.tint.color).frame(width: 9, height: 9)
                Text(account.displayName).font(.system(size: 13))
                Spacer()
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(UM.fg3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .frame(height: 28)
            .opacity(hidden ? 0.45 : 1)
        }
        .buttonStyle(HoverStyle(radius: 8, pressScale: 1))
        .animation(Motion.smooth, value: hidden)
    }
}

// MARK: - Статус синхронизации

@MainActor
private struct SyncFooter: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let failing = store.accounts.first { store.accountErrors[$0.id] != nil }
        let syncing = !store.syncingAccountIDs.isEmpty
        let symbol = failing != nil ? "exclamationmark.arrow.triangle.2.circlepath"
            : (syncing ? "arrow.triangle.2.circlepath" : "checkmark.icloud")
        let text: String = {
            if let failing { return "\(failing.displayName): нужен пароль" }
            if syncing { return "Синхронизация…" }
            if let last = store.lastSync { return "Синхронизировано · \(RelativeDate.clock(last))" }
            return "Не синхронизировано"
        }()

        return HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .symbolEffect(.pulse, isActive: syncing)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(failing != nil ? UM.warnFg : UM.fg3)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.top)
    }
}
