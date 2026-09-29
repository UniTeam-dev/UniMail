import SwiftUI

/// Средняя колонка: треды текущей папки.
@MainActor
struct MessageListView: View {
    @Environment(MailStore.self) private var store
    @AppStorage("listDensity") private var density: ListDensity = .comfortable
    @Namespace private var selectionNS
    @Namespace private var categoryNS
    @FocusState private var listFocused: Bool

    var body: some View {
        let threads = store.currentThreads

        VStack(spacing: 0) {
            header(count: threads.count)

            if threads.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(threads) { thread in
                                SwipeableRow(
                                    onArchive: { store.archive(threadIDs: [thread.id]) },
                                    onSnooze: { store.snooze(threadIDs: [thread.id], until: TimePreset.tomorrowMorning.date) }
                                ) {
                                    ThreadRow(
                                        thread: thread,
                                        account: store.account(thread.latest.accountID),
                                        showAccount: store.scope.accountID == nil,
                                        isSelected: store.selectedThreadID == thread.id,
                                        density: density,
                                        namespace: selectionNS
                                    )
                                }
                                .id(thread.id)
                                .onTapGesture { select(thread.id) }
                                .contextMenu { ThreadContextMenu(threadID: thread.id) }
                                .transition(Motion.rowTransition)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: store.selectedThreadID) { _, id in
                        guard let id else { return }
                        withAnimation(Motion.smooth) { proxy.scrollTo(id, anchor: nil) }
                    }
                }
                .id(store.scope)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 10)),
                    removal: .opacity
                ))
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press, threads: threads) }
        .navigationTitle(store.scope.role.title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Проверить почту", systemImage: "arrow.clockwise")
                        .symbolEffect(.pulse, isActive: !store.syncingAccountIDs.isEmpty)
                }
                .help("Проверить почту (⇧⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.compose() } label: {
                    Label("Новое письмо", systemImage: "square.and.pencil")
                }
                .help("Новое письмо (⌘N)")
            }
        }
    }

    // MARK: Шапка

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.searchText.isEmpty ? store.scope.role.title : "Результаты поиска")
                    .font(.title2.weight(.bold))
                    .contentTransition(.opacity)
                Spacer()
                Text(countText(count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(count)))
            }

            if store.scope.role == .inbox && store.searchText.isEmpty {
                categoryPicker
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .animation(Motion.snappy, value: count)
    }

    private func countText(_ count: Int) -> String {
        let unread = store.unreadCount(store.scope)
        return unread > 0 ? "\(unread) непрочит." : "\(count) тредов"
    }

    private var categoryPicker: some View {
        let options: [InboxCategory?] = [nil] + InboxCategory.allCases.map { Optional($0) }
        return HStack(spacing: 4) {
            ForEach(options, id: \.self) { category in
                let selected = store.categoryFilter == category
                Button {
                    withAnimation(Motion.snappy) { store.categoryFilter = category }
                } label: {
                    Text(category?.title ?? "Все")
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.background)
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "category", in: categoryNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }

    // MARK: Пустое состояние

    @ViewBuilder
    private var emptyState: some View {
        if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if store.scope.role == .inbox {
            ContentUnavailableView {
                Label("Входящие разобраны", systemImage: "checkmark.seal")
                    .symbolEffect(.bounce, value: store.scope)
            } description: {
                Text("Новых писем нет. Можно выдохнуть ☕️")
            }
        } else {
            ContentUnavailableView(
                "Пусто",
                systemImage: store.scope.role.symbol,
                description: Text("В папке «\(store.scope.role.title)» ничего нет.")
            )
        }
    }

    // MARK: Выбор и клавиатура

    private func select(_ id: String) {
        listFocused = true
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
        default:
            break
        }

        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        switch press.characters {
        case "j": return step(+1, ids: ids)
        case "k": return step(-1, ids: ids)
        case "e": store.archive(threadIDs: selected)
        case "#": store.trash(threadIDs: selected)
        case "s": store.toggleFlag(threadIDs: selected)
        case "u": store.toggleRead(threadIDs: selected)
        case "r": store.replyToSelected()
        case "a": store.replyToSelected(all: true)
        case "f": store.forwardSelected()
        case "h": store.snooze(threadIDs: selected, until: TimePreset.tomorrowMorning.date)
        case "c": store.compose()
        default: return .ignored
        }
        return .handled
    }

    /// Переход к соседнему треду (стрелки, j/k).
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

// MARK: - Контекстное меню

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
                    store.snooze(threadIDs: [threadID], until: preset.date)
                }
            }
        }
        Divider()
        if store.scope.role != .inbox {
            Button("Во входящие", systemImage: "tray") { store.moveToInbox(threadIDs: [threadID]) }
        }
        Button("В архив", systemImage: "archivebox") { store.archive(threadIDs: [threadID]) }
        Button("Это спам", systemImage: "xmark.bin") { store.markSpam(threadIDs: [threadID]) }
        Button("Удалить", systemImage: "trash", role: .destructive) { store.trash(threadIDs: [threadID]) }
    }
}
