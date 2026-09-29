import Foundation
import Observation
import SwiftUI

/// Плашка «Отменить» внизу окна.
struct PendingUndo: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var symbol: String
}

/// Единственный источник правды для интерфейса.
///
/// Сейчас письма хранятся в памяти; на этапе 1 хранилище переедет в SQLite (GRDB + FTS5),
/// а публичный интерфейс этого класса останется прежним.
///
/// Все изменения применяются оптимистично: письмо сразу исчезает из списка,
/// а на сервер действие уходит после окна «Отменить».
@MainActor
@Observable
final class MailStore {
    // MARK: Состояние

    var accounts: [Account] {
        didSet { AccountRepository.save(accounts) }
    }
    private(set) var messages: [String: Message] = [:]

    var scope: MailScope = .unified(.inbox)
    var selectedThreadID: String?
    var searchText = ""
    var categoryFilter: InboxCategory?
    /// Почта или Расписание (переключатель в заголовке списка).
    var mode: AppMode = .mail
    /// Слои на ленте расписания.
    var scheduleLayers: Set<ScheduleLayer> = Set(ScheduleLayer.allCases)
    /// Запрос открыть быстрый ответ (клавиша R): счётчик, чтобы срабатывало повторно.
    var quickReplyRequest = 0
    /// Запрос открыть меню «Отложить» (клавиша H).
    var snoozeMenuRequest = 0
    /// Быстрый фильтр списка (кнопка-воронка в шапке списка).
    var quickFilter: QuickFilter = .all
    /// Искать также в спаме и корзине.
    var searchEverywhere = false
    /// Календари, скрытые на вкладке «Расписание».
    var scheduleHidden: Set<UUID> = []
    /// Время последней успешной синхронизации.
    private(set) var lastSync: Date?

    /// Ящики, скрытые из «Все ящики» (хранится в самих аккаунтах).
    var hiddenAccountIDs: Set<UUID> {
        Set(accounts.filter { $0.hiddenFromUnified == true }.map(\.id))
    }

    private(set) var syncingAccountIDs: Set<UUID> = []
    private(set) var accountErrors: [UUID: String] = [:]
    private(set) var undo: PendingUndo?

    /// Очередь окон написания, которые должен открыть RootView.
    var composeQueue: [ComposeRequest] = []
    var isPalettePresented = false

    // MARK: Внутреннее

    private var providers: [UUID: any MailProvider] = [:]
    private var cursors: [UUID: String] = [:]
    private var pendingCommit: (() async -> Void)?
    private var pendingRestore: (() -> Void)?
    private var pendingTask: Task<Void, Never>?
    private var backgroundLoop: Task<Void, Never>?

    private var undoSeconds: Double {
        let value = UserDefaults.standard.double(forKey: "undoSeconds")
        return value == 0 ? 5 : value
    }

    init() {
        accounts = AccountRepository.load()
        for account in accounts {
            providers[account.id] = ProviderFactory.make(for: account)
        }
    }

    // MARK: Жизненный цикл

    func start() {
        guard backgroundLoop == nil else { return }
        Task { await refreshAll() }
        backgroundLoop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                self.wakeSnoozed()
                await self.sendDueScheduled()
                tick += 1
                if tick % 3 == 0 { await self.refreshAll() }
            }
        }
    }

    func refreshAll() async {
        let ids = accounts.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(accountID: id) }
            }
        }
    }

    func refresh(accountID: UUID) async {
        guard let provider = providers[accountID], !syncingAccountIDs.contains(accountID) else { return }
        syncingAccountIDs.insert(accountID)
        defer { syncingAccountIDs.remove(accountID) }
        do {
            let result = try await provider.sync(cursor: cursors[accountID])
            cursors[accountID] = result.cursor
            accountErrors[accountID] = nil
            lastSync = .now
            withAnimation(Motion.list) {
                for message in result.upserted { messages[message.id] = message }
                for id in result.deletedIDs { messages[id] = nil }
            }
        } catch {
            accountErrors[accountID] = error.localizedDescription
        }
    }

    // MARK: Аккаунты

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func addAccount(_ account: Account, secret: String?) {
        if let secret, !secret.isEmpty {
            try? Keychain.set(secret, for: account.id.uuidString)
        }
        accounts.append(account)
        providers[account.id] = ProviderFactory.make(for: account)
        withAnimation(Motion.snappy) { scope = .account(account.id, .inbox) }
        Task { await refresh(accountID: account.id) }
    }

    func removeAccount(_ id: UUID) {
        Keychain.remove(id.uuidString)
        providers[id] = nil
        cursors[id] = nil
        withAnimation(Motion.snappy) {
            accounts.removeAll { $0.id == id }
            messages = messages.filter { $0.value.accountID != id }
            if scope.accountID == id { scope = .unified(.inbox) }
        }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
    }

    /// ⌘1 — «Все ящики», ⌘2…⌘9 — аккаунты по порядку (как в макете).
    func switchTo(index: Int) {
        let target: MailScope
        if index <= 1 {
            target = .unified(.inbox)
        } else if accounts.indices.contains(index - 2) {
            target = .account(accounts[index - 2].id, .inbox)
        } else {
            return
        }
        if mode != .mail { withAnimation(Motion.smooth) { mode = .mail } }
        select(scope: target)
    }

    /// Переключение аккаунта из панели: всегда во «Входящие», категория сбрасывается.
    func switchToAccount(_ id: UUID?) {
        if mode != .mail { withAnimation(Motion.smooth) { mode = .mail } }
        select(scope: id.map { .account($0, .inbox) } ?? .unified(.inbox))
    }

    func switchToNextAccount() {
        let order: [MailScope] = [.unified(scope.role)] + accounts.map { .account($0.id, scope.role) }
        let current = order.firstIndex(of: scope) ?? 0
        select(scope: order[(current + 1) % order.count])
    }

    func select(scope newScope: MailScope) {
        guard newScope != scope else { return }
        let accountChanged = newScope.accountID != scope.accountID
        withAnimation(Motion.snappy) {
            scope = newScope
            if accountChanged || newScope.role != .inbox { categoryFilter = nil }
            // Открытый тред остаётся, если он есть в новом списке, иначе — первый.
            let ids = threads(in: newScope).map(\.id)
            if let current = selectedThreadID, ids.contains(current) { return }
            selectedThreadID = accountChanged ? ids.first : nil
        }
        if accountChanged, let first = selectedThreadID { openThread(first) }
    }

    func toggleHidden(_ id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Motion.list) {
            accounts[index].hiddenFromUnified = !(accounts[index].hiddenFromUnified ?? false)
        }
    }

    // MARK: Выборки

    private func inScopeAccounts(_ m: Message, _ scope: MailScope) -> Bool {
        if let id = scope.accountID { return m.accountID == id }
        return !hiddenAccountIDs.contains(m.accountID)
    }

    private func matchesRole(_ m: Message, _ role: MailboxRole) -> Bool {
        switch role {
        case .flagged: m.isFlagged && m.role != .trash && m.role != .spam
        default: m.role == role
        }
    }

    /// Письма, видимые в текущем списке.
    func visibleMessages(in scope: MailScope) -> [Message] {
        let query = SearchQuery(searchText)
        let filter = quickFilter
        return messages.values.filter { m in
            guard inScopeAccounts(m, scope) else { return false }
            if !query.isEmpty {
                // Поиск идёт по всем папкам, кроме спама и корзины (если не попросили искать везде).
                return (searchEverywhere || (m.role != .trash && m.role != .spam)) && query.matches(m)
            }
            guard matchesRole(m, scope.role) else { return false }
            if scope.role == .inbox, let categoryFilter, m.category != categoryFilter { return false }
            return filter.matches(m)
        }
    }

    func threads(in scope: MailScope) -> [ThreadSummary] {
        let visible = visibleMessages(in: scope)
        let grouped = Dictionary(grouping: visible, by: \.threadID)
        return grouped.compactMap { threadID, items -> ThreadSummary? in
            let sorted = items.sorted { $0.date > $1.date }
            guard let latest = sorted.first else { return nil }
            let all = thread(threadID)
            var participants: [Address] = []
            for m in all.reversed() where !participants.contains(where: { $0.email == m.from.email }) {
                participants.append(m.from)
            }
            return ThreadSummary(
                id: threadID,
                latest: latest,
                messageIDs: sorted.map(\.id),
                participants: participants,
                count: all.count,
                hasUnread: items.contains { !$0.isRead },
                isFlagged: items.contains(where: \.isFlagged),
                hasAttachments: items.contains { !$0.attachments.isEmpty }
            )
        }
        .sorted { $0.latest.date > $1.latest.date }
    }

    var currentThreads: [ThreadSummary] { threads(in: scope) }

    /// Все письма треда по возрастанию даты (для экрана чтения).
    func thread(_ threadID: String) -> [Message] {
        let showDeleted = scope.role == .trash || scope.role == .spam
        return messages.values
            .filter { $0.threadID == threadID && (showDeleted || ($0.role != .trash && $0.role != .spam)) }
            .sorted { $0.date < $1.date }
    }

    func unreadCount(_ scope: MailScope) -> Int {
        return messages.values.reduce(0) { count, m in
            count + ((!m.isRead && inScopeAccounts(m, scope) && matchesRole(m, scope.role)) ? 1 : 0)
        }
    }

    func totalCount(_ scope: MailScope) -> Int {
        messages.values.reduce(0) { $0 + ((inScopeAccounts($1, scope) && matchesRole($1, scope.role)) ? 1 : 0) }
    }

    // MARK: Действия

    private func messageIDs(ofThreads threadIDs: [String]) -> [String] {
        let set = Set(threadIDs)
        let visible = visibleMessages(in: scope)
        return visible.filter { set.contains($0.threadID) }.map(\.id)
    }

    func openThread(_ threadID: String) {
        let unread = thread(threadID).filter { !$0.isRead }.map(\.id)
        guard !unread.isEmpty else { return }
        setRead(messageIDs: unread, true)
    }

    func toggleRead(threadIDs: [String]) {
        let ids = messageIDs(ofThreads: threadIDs)
        let anyUnread = ids.contains { messages[$0]?.isRead == false }
        setRead(messageIDs: ids, anyUnread)
    }

    private func setRead(messageIDs: [String], _ read: Bool) {
        withAnimation(Motion.snappy) {
            for id in messageIDs { messages[id]?.isRead = read }
        }
        push(messageIDs) { .markRead(ids: $0, read: read) }
    }

    func toggleFlag(threadIDs: [String]) {
        let ids = messageIDs(ofThreads: threadIDs)
        let flag = !ids.contains { messages[$0]?.isFlagged == true }
        withAnimation(Motion.bouncy) {
            for id in ids { messages[id]?.isFlagged = flag }
        }
        push(ids) { .flag(ids: $0, flagged: flag) }
    }

    func archive(threadIDs: [String]) {
        move(threadIDs: threadIDs, to: .archive, title: "Перемещено в архив", symbol: "archivebox")
    }

    func trash(threadIDs: [String]) {
        if scope.role == .trash {
            let ids = messageIDs(ofThreads: threadIDs)
            perform(title: "Удалено навсегда", symbol: "trash.slash", ids: ids,
                    action: { .deletePermanently(ids: $0) }) { _ in }
            withAnimation(Motion.list) { for id in ids { messages[id] = nil } }
            return
        }
        move(threadIDs: threadIDs, to: .trash, title: "Перемещено в корзину", symbol: "trash")
    }

    func markSpam(threadIDs: [String]) {
        move(threadIDs: threadIDs, to: .spam, title: "Помечено как спам", symbol: "xmark.bin")
    }

    func moveToInbox(threadIDs: [String]) {
        move(threadIDs: threadIDs, to: .inbox, title: "Возвращено во входящие", symbol: "tray")
    }

    func move(threadIDs: [String], to role: MailboxRole, title: String, symbol: String) {
        let ids = messageIDs(ofThreads: threadIDs)
        perform(title: title, symbol: symbol, ids: ids, action: { .move(ids: $0, to: role) }) { message in
            message.role = role
            message.snoozedUntil = nil
        }
    }

    func snooze(threadIDs: [String], until date: Date, label: String? = nil) {
        let ids = messageIDs(ofThreads: threadIDs)
        let formatted = date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let title = label.map { "Отложено: \($0.lowercased()) · \(formatted)" } ?? "Отложено до \(formatted)"
        perform(title: title, symbol: "clock", ids: ids,
                action: { .snooze(ids: $0, until: date) }) { message in
            message.role = .snoozed
            message.snoozedUntil = date
            message.isRead = true
        }
    }

    /// Отложенные письма, у которых подошло время, возвращаются во «Входящие» непрочитанными.
    private func wakeSnoozed() {
        let due = messages.values.filter { $0.role == .snoozed && ($0.snoozedUntil ?? .distantFuture) <= .now }
        guard !due.isEmpty else { return }
        withAnimation(Motion.list) {
            for m in due {
                messages[m.id]?.role = .inbox
                messages[m.id]?.isRead = false
                messages[m.id]?.snoozedUntil = nil
                messages[m.id]?.date = .now
            }
        }
    }

    /// Общая схема: оптимистично меняем локально → показываем «Отменить» → по таймеру отправляем на сервер.
    private func perform(
        title: String,
        symbol: String,
        ids: [String],
        action: @escaping ([String]) -> MailAction,
        mutate: (inout Message) -> Void
    ) {
        guard !ids.isEmpty else { return }
        flushPending()

        let snapshot = ids.compactMap { messages[$0] }
        let before = currentThreads.map(\.id)

        withAnimation(Motion.list) {
            for id in ids {
                if var message = messages[id] {
                    mutate(&message)
                    messages[id] = message
                }
            }
            advanceSelection(previousOrder: before)
        }

        pendingRestore = { [weak self] in
            guard let self else { return }
            withAnimation(Motion.list) {
                for m in snapshot { self.messages[m.id] = m }
            }
        }
        let byAccount = Dictionary(grouping: snapshot, by: \.accountID).mapValues { $0.map(\.id) }
        pendingCommit = { [weak self] in
            guard let self else { return }
            for (accountID, ids) in byAccount {
                do {
                    try await self.providers[accountID]?.apply(action(ids))
                } catch {
                    self.accountErrors[accountID] = error.localizedDescription
                }
            }
        }
        showUndo(PendingUndo(title: title, symbol: symbol))
    }

    private func showUndo(_ value: PendingUndo) {
        withAnimation(Motion.bouncy) { undo = value }
        pendingTask?.cancel()
        let delay = max(undoSeconds, 1)
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.commitPending()
        }
    }

    private func commitPending() async {
        let commit = pendingCommit
        pendingCommit = nil
        pendingRestore = nil
        withAnimation(Motion.snappy) { undo = nil }
        await commit?()
    }

    /// Новое действие фиксирует предыдущее без ожидания таймера.
    private func flushPending() {
        guard let commit = pendingCommit else { return }
        pendingTask?.cancel()
        pendingCommit = nil
        pendingRestore = nil
        Task { await commit() }
    }

    func undoLast() {
        pendingTask?.cancel()
        pendingRestore?()
        pendingRestore = nil
        pendingCommit = nil
        withAnimation(Motion.snappy) { undo = nil }
    }

    func dismissUndo() {
        pendingTask?.cancel()
        Task { await commitPending() }
    }

    /// Действия без «Отменить» (прочитано, флаг) уходят сразу.
    private func push(_ ids: [String], _ action: @escaping ([String]) -> MailAction) {
        let byAccount = Dictionary(grouping: ids.compactMap { messages[$0] }, by: \.accountID)
            .mapValues { $0.map(\.id) }
        for (accountID, ids) in byAccount {
            guard let provider = providers[accountID] else { continue }
            Task {
                do { try await provider.apply(action(ids)) } catch {
                    self.accountErrors[accountID] = error.localizedDescription
                }
            }
        }
    }

    /// После удаления открытого треда из списка выделяем соседний.
    private func advanceSelection(previousOrder: [String]) {
        guard let selected = selectedThreadID else { return }
        let now = currentThreads.map(\.id)
        if now.contains(selected) { return }
        guard let index = previousOrder.firstIndex(of: selected) else { selectedThreadID = nil; return }
        let candidates = previousOrder[index...].dropFirst() + previousOrder[..<index].reversed()
        selectedThreadID = candidates.first { now.contains($0) }
    }

    // MARK: Написание

    func compose(_ mode: ComposeRequest.Mode = .new, from messageID: String? = nil) {
        let source = messageID.flatMap { messages[$0] }
        let accountID = source?.accountID ?? scope.accountID ?? accounts.first?.id
        guard let accountID, let account = self.account(accountID) else { return }

        var draft = OutgoingMessage(
            accountID: accountID, fromAddress: account.email,
            to: [], cc: [], bcc: [], subject: "",
            body: account.signature.isEmpty ? "" : "\n\n--\n\(account.signature)"
        )
        if let source {
            draft.threadID = source.threadID
            draft.inReplyTo = source.id
            switch mode {
            case .reply:
                draft.to = [source.role == .sent ? source.to.first ?? source.from : source.from]
                draft.subject = ComposeRequest.prefixed("Re:", source.subject)
                draft.body += ComposeRequest.quote(source)
            case .replyAll:
                draft.to = [source.from]
                draft.cc = (source.to + source.cc).filter { $0.email != account.email }
                draft.subject = ComposeRequest.prefixed("Re:", source.subject)
                draft.body += ComposeRequest.quote(source)
            case .forward:
                draft.subject = ComposeRequest.prefixed("Fwd:", source.subject)
                draft.inReplyTo = nil
                draft.body += ComposeRequest.quote(source)
            case .draft:
                draft.to = source.to
                draft.cc = source.cc
                draft.subject = source.subject
                draft.body = source.body
            case .new:
                break
            }
        }
        composeQueue.append(ComposeRequest(mode: mode, draft: draft))
    }

    func replyToSelected(all: Bool = false) {
        guard let id = selectedThreadID, let last = thread(id).last else { return }
        compose(all ? .replyAll : .reply, from: last.id)
    }

    func forwardSelected() {
        guard let id = selectedThreadID, let last = thread(id).last else { return }
        compose(.forward, from: last.id)
    }

    func saveDraft(_ draft: OutgoingMessage, requestID: UUID) {
        guard let account = self.account(draft.accountID) else { return }
        let id = "draft-\(requestID.uuidString)"
        messages[id] = Message(
            id: id, accountID: draft.accountID, threadID: draft.threadID ?? id, role: .drafts,
            from: Address(name: account.displayName, email: draft.fromAddress),
            to: draft.to, cc: draft.cc, subject: draft.subject.isEmpty ? "(без темы)" : draft.subject,
            body: draft.body, date: .now, isRead: true
        )
    }

    func discardDraft(requestID: UUID) {
        messages["draft-\(requestID.uuidString)"] = nil
    }

    /// Отправка с окном «Отменить». Если задано время — письмо уходит в «Запланированные».
    func send(_ draft: OutgoingMessage, requestID: UUID, undoTitle: String = "Письмо отправляется…") {
        discardDraft(requestID: requestID)
        flushPending()

        if let sendAt = draft.sendAt, sendAt > .now {
            let id = "scheduled-\(requestID.uuidString)"
            var message = Message(
                id: id, accountID: draft.accountID, threadID: draft.threadID ?? id, role: .scheduled,
                from: Address(name: self.account(draft.accountID)?.displayName, email: draft.fromAddress),
                to: draft.to, cc: draft.cc, subject: draft.subject, body: draft.body,
                date: .now, isRead: true
            )
            message.scheduledAt = sendAt
            withAnimation(Motion.list) { messages[id] = message }
            scheduledDrafts[id] = draft
            let when = sendAt.formatted(.dateTime.day().month().hour().minute())
            showUndo(PendingUndo(title: "Отправится \(when)", symbol: "calendar.badge.clock"))
            pendingRestore = { [weak self] in
                self?.messages[id] = nil
                self?.scheduledDrafts[id] = nil
                self?.composeQueue.append(ComposeRequest(mode: .draft, draft: draft))
            }
            return
        }

        pendingRestore = { [weak self] in
            self?.composeQueue.append(ComposeRequest(mode: .draft, draft: draft))
        }
        pendingCommit = { [weak self] in
            await self?.deliver(draft)
        }
        showUndo(PendingUndo(title: undoTitle, symbol: "paperplane"))
    }

    private var scheduledDrafts: [String: OutgoingMessage] = [:]

    private func sendDueScheduled() async {
        let due = scheduledDrafts.filter { ($0.value.sendAt ?? .distantFuture) <= .now }
        for (id, draft) in due {
            scheduledDrafts[id] = nil
            withAnimation(Motion.list) { messages[id] = nil }
            await deliver(draft)
        }
    }

    /// Письмо появляется в «Отправленных» только после подтверждения сервером.
    private func deliver(_ draft: OutgoingMessage) async {
        guard let provider = providers[draft.accountID] else { return }
        do {
            let sent = try await provider.send(draft)
            withAnimation(Motion.list) { messages[sent.id] = sent }
        } catch {
            accountErrors[draft.accountID] = "Не отправлено: \(error.localizedDescription)"
            composeQueue.append(ComposeRequest(mode: .draft, draft: draft))
        }
    }
}

/// Быстрый фильтр списка.
enum QuickFilter: String, CaseIterable, Identifiable {
    case all, unread, flagged, attachments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Все письма"
        case .unread: "Непрочитанные"
        case .flagged: "С флажком"
        case .attachments: "С вложениями"
        }
    }

    func matches(_ m: Message) -> Bool {
        switch self {
        case .all: true
        case .unread: !m.isRead
        case .flagged: m.isFlagged
        case .attachments: !m.attachments.isEmpty
        }
    }
}
