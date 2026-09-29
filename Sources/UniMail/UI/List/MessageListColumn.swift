import SwiftUI

/// Средняя колонка: переключатель «Почта / Расписание», заголовок папки, категории и треды.
@MainActor
struct MessageListColumn: View {
    @Environment(MailStore.self) private var store
    @AppStorage("listDensity") private var density: ListDensity = .comfortable
    @FocusState private var focused: Bool
    let narrow: Bool

    var body: some View {
        @Bindable var store = store
        let threads = store.currentThreads

        VStack(spacing: 0) {
            // Шапка 52 pt
            HStack(spacing: 8) {
                ModeSwitch()
                Spacer()
                Menu {
                    Picker("Фильтр", selection: $store.quickFilter) {
                        ForEach(QuickFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: store.quickFilter == .all
                          ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(ToolbarIconStyle(tint: store.quickFilter == .all ? nil : UM.accent))
                .frame(width: 32, height: 28)
                .help("Фильтр")

                Button { store.compose() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(ToolbarIconStyle())
                    .help("Новое письмо · ⌘N")
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 52)

            ListHeader(count: threads.count, narrow: narrow)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 12)
                .id(store.scope)
                .transition(Motion.contentTransition)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if let failing = failingAccount {
                            SyncErrorBanner(account: failing)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 10)
                        }
                        ForEach(threads) { thread in
                            SwipeableRow(threadID: thread.id) {
                                ThreadRow(
                                    thread: thread,
                                    account: store.account(thread.latest.accountID),
                                    showAccount: store.scope.accountID == nil,
                                    isSelected: store.selectedThreadID == thread.id,
                                    density: density
                                )
                            }
                            .id(thread.id)
                            .onTapGesture { select(thread.id) }
                            .contextMenu { ThreadContextMenu(threadID: thread.id) }
                            .transition(Motion.rowTransition)
                        }
                        if threads.isEmpty {
                            EmptyListState()
                                .transition(.opacity)
                        }
                        if !store.searchText.isEmpty && store.canSearchServer {
                            ServerSearchFooter()
                                .padding(.horizontal, 18)
                                .padding(.top, 10)
                        }
                    }
                    .padding(.bottom, 12)
                    .animation(Motion.list, value: threads.map(\.id))
                }
                .onChange(of: store.selectedThreadID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.smooth) { proxy.scrollTo(id) }
                }
            }
            .id(store.scope)
            .transition(Motion.contentTransition)
        }
        .animation(Motion.smooth, value: store.scope)
        .background(UM.list)
        .hairline(.trailing)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press, threads: threads) }
        .onAppear { focused = true }
    }

    private var failingAccount: Account? {
        guard let id = store.scope.accountID, store.accountErrors[id] != nil else { return nil }
        return store.account(id)
    }

    private func select(_ id: String) {
        focused = true
        withAnimation(Motion.snappy) { store.selectedThreadID = id }
        store.openThread(id)
    }

    private func handleKey(_ press: KeyPress, threads: [ThreadSummary]) -> KeyPress.Result {
        let ids = threads.map(\.id)
        let selected = store.selectedThreadID.map { [$0] } ?? []

        switch press.key {
        case .downArrow: return step(+1, ids: ids)
        case .upArrow: return step(-1, ids: ids)
        case .delete, .deleteForward:
            store.trash(threadIDs: selected)
            return .handled
        case .escape:
            return .ignored
        default:
            break
        }

        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        switch press.characters {
        case "j", "о": return step(+1, ids: ids)
        case "k", "л": return step(-1, ids: ids)
        case "e", "у": store.archive(threadIDs: selected)
        case "#": store.trash(threadIDs: selected)
        case "s", "ы": store.toggleFlag(threadIDs: selected)
        case "u", "г": store.toggleRead(threadIDs: selected)
        case "r", "к": store.quickReplyRequest += 1
        case "a", "ф": store.replyToSelected(all: true)
        case "f", "а": store.forwardSelected()
        case "h", "р": store.snoozeMenuRequest += 1
        case "c", "с": store.compose()
        default: return .ignored
        }
        return .handled
    }

    private func step(_ delta: Int, ids: [String]) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        let current = store.selectedThreadID.flatMap { ids.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), ids.count - 1)
        } else {
            next = delta > 0 ? 0 : ids.count - 1
        }
        select(ids[next])
        return .handled
    }
}

// MARK: - Переключатель «Почта / Расписание»

@MainActor
struct ModeSwitch: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let items: [SlidingSegments<AppMode>.Item] = [
            SlidingSegments<AppMode>.Item(value: .mail, title: "Почта", symbol: "envelope"),
            SlidingSegments<AppMode>.Item(value: .schedule, title: "Расписание", symbol: "calendar"),
        ]
        SlidingSegments(items: items, selection: $store.mode)
        .fixedSize()
    }
}

// MARK: - Заголовок списка

@MainActor
private struct ListHeader: View {
    @Environment(MailStore.self) private var store
    let count: Int
    let narrow: Bool

    var body: some View {
        @Bindable var store = store
        let searching = !store.searchText.isEmpty
        let unread = store.unreadCount(store.scope)
        let subtitle: String = {
            if searching { return "\(count) \(plural(count, "результат", "результата", "результатов"))" }
            if (store.scope.role == .inbox || store.scope.role == .custom) && unread > 0 {
                return "\(unread) \(plural(unread, "непрочитанное", "непрочитанных", "непрочитанных"))"
            }
            return ""
        }()

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(searching ? "Поиск" : store.scopeTitle)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.57)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(UM.fg3)
                    .contentTransition(.numericText(value: Double(unread)))
                    .padding(.leading, 8)
                Spacer(minLength: 0)
                if unread > 0 && !searching {
                    Button { store.markAllRead() } label: {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 13))
                            .foregroundStyle(UM.fg2)
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverStyle(radius: 7))
                    .help("Отметить все как прочитанные · ⌥⌘T")
                    .transition(.scale.combined(with: .opacity))
                }
            }

            if store.scope.role == .inbox && !searching {
                SlidingSegments(
                    items: categoryItems,
                    selection: $store.categoryFilter,
                    equalWidth: true,
                    fontSize: narrow ? 11 : 12
                )
            }
        }
        .animation(Motion.bouncy, value: unread)
    }

    private var categoryItems: [SlidingSegments<InboxCategory?>.Item] {
        typealias Item = SlidingSegments<InboxCategory?>.Item
        var items: [Item] = [Item(value: nil, title: "Все")]
        for category in InboxCategory.allCases {
            items.append(Item(value: category, title: narrow ? category.shortTitle : category.title))
        }
        return items
    }
}

// MARK: - Пустые состояния

@MainActor
private struct EmptyListState: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        Group {
            if !store.searchText.isEmpty {
                VStack(spacing: 0) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(UM.fg3)
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(UM.seg))
                    Text("Ничего не нашлось")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, 16)
                    Text("По запросу «\(store.searchText)» нет писем ни в одном ящике. Попробуйте другие слова или поищите в архиве.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(UM.fg3)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 270)
                        .padding(.top, 6)
                    if !store.searchEverywhere {
                        Button("Искать в спаме и корзине") { store.searchEverywhere = true }
                            .buttonStyle(UMButtonStyle(kind: .secondary))
                            .padding(.top, 16)
                    }
                }
            } else if store.scope.role == .inbox && store.categoryFilter == nil && store.quickFilter == .all {
                VStack(spacing: 0) {
                    Text("☕️").font(.system(size: 44))
                    Text("Входящие разобраны ☕️")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.17)
                        .padding(.top, 16)
                    Text(nextSnoozeText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(UM.fg3)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 260)
                        .padding(.top, 6)
                }
            } else {
                Text("В этой папке пусто")
                    .font(.system(size: 12.5))
                    .foregroundStyle(UM.fg3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.top, 90)
    }

    private var nextSnoozeText: String {
        let next = store.messages.values
            .filter { $0.role == .snoozed && (store.scope.accountID == nil || $0.accountID == store.scope.accountID) }
            .compactMap(\.snoozedUntil)
            .min()
        guard let next else { return "Новых писем нет." }
        return "Новых писем нет. Следующее отложенное вернётся \(RelativeDate.long(next).lowercased())."
    }
}

// MARK: - Ошибка синхронизации

@MainActor
private struct SyncErrorBanner: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let account: Account

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UM.orange))
            VStack(alignment: .leading, spacing: 3) {
                Text("Не удалось синхронизировать «\(account.displayName)»")
                    .font(.system(size: 13, weight: .semibold))
                Text(store.accountErrors[account.id] ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(UM.fg2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Ввести пароль") { openSettings() }
                        .buttonStyle(UMButtonStyle(kind: .primary, height: 26, radius: 7, horizontal: 12))
                    Button("Повторить") { Task { await store.refresh(accountID: account.id) } }
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 12))
                }
                .padding(.top, 7)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UM.warnBg))
    }
}

// MARK: - Контекстное меню треда

@MainActor
struct ThreadContextMenu: View {
    @Environment(MailStore.self) private var store
    let threadID: String

    var body: some View {
        let last = store.thread(threadID).last
        Button("Ответить", systemImage: "arrowshape.turn.up.left") {
            if let last { store.compose(.reply, from: last.id) }
        }
        Button("Ответить всем", systemImage: "arrowshape.turn.up.left.2") {
            if let last { store.compose(.replyAll, from: last.id) }
        }
        Button("Переслать", systemImage: "arrowshape.turn.up.right") {
            if let last { store.compose(.forward, from: last.id) }
        }
        Divider()
        Button("Прочитано / не прочитано", systemImage: "envelope.badge") { store.toggleRead(threadIDs: [threadID]) }
        Button("Флажок", systemImage: "flag") { store.toggleFlag(threadIDs: [threadID]) }
        Menu("Отложить") {
            ForEach(TimePreset.allCases) { preset in
                Button("\(preset.title) — \(preset.subtitle)", systemImage: preset.symbol) {
                    store.snooze(threadIDs: [threadID], until: preset.date, label: preset.title)
                }
            }
        }
        if let accountID = last?.accountID, !store.folders(of: accountID).isEmpty {
            Menu("Переместить в папку") {
                ForEach(store.folders(of: accountID)) { folder in
                    Button(String(repeating: "   ", count: min(folder.depth, 6)) + folder.name) {
                        store.move(threadIDs: [threadID], toFolder: folder, accountID: accountID)
                    }
                    .disabled(store.scope.folderKey == folder.id)
                }
            }
        }
        Divider()
        Group {
            if store.scope.role != .inbox {
                Button("Во входящие", systemImage: "tray") { store.moveToInbox(threadIDs: [threadID]) }
            }
            Button("В архив", systemImage: "archivebox") { store.archive(threadIDs: [threadID]) }
            Button("Это спам", systemImage: "exclamationmark.octagon") { store.markSpam(threadIDs: [threadID]) }
            Button("Удалить", systemImage: "trash", role: .destructive) { store.trash(threadIDs: [threadID]) }
        }
    }
}

// MARK: - Поиск на сервере

/// Под результатами: письма старше локальной истории ищутся на сервере (IMAP SEARCH / X-GM-RAW).
@MainActor
private struct ServerSearchFooter: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            switch store.serverSearchState {
            case .idle:
                Button {
                    store.searchOnServer()
                } label: {
                    Label("Искать на сервере", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(UMButtonStyle(kind: .secondary, height: 28, radius: 8, horizontal: 12))
            case .searching:
                ProgressView().controlSize(.small)
                Text("Ищу на сервере…").foregroundStyle(UM.fg3)
            case .done(let found):
                Image(systemName: "checkmark.circle").foregroundStyle(UM.green)
                Text(found == 0 ? "На сервере ничего больше нет"
                     : "С сервера: \(found) \(plural(found, "тред", "треда", "тредов"))")
                    .foregroundStyle(UM.fg3)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UM.orange)
                Text(text).foregroundStyle(UM.fg3).lineLimit(2)
                Button("Повторить") { store.searchOnServer() }
                    .buttonStyle(.plain)
                    .foregroundStyle(UM.accent)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
        .animation(Motion.snappy, value: store.serverSearchState)
    }
}
