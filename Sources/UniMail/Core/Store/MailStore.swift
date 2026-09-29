import Foundation
import Observation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Плашка «Отменить» внизу окна.
struct PendingUndo: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var symbol: String
}

/// Поиск на сервере (кнопка «Искать на сервере» под результатами).
enum ServerSearchState: Equatable {
    case idle
    case searching
    case done(found: Int)
    case failed(String)
}

/// Единственный источник правды для интерфейса.
///
/// Письма живут в памяти (словарь по id) и в SQLite (`MailDatabase`): при запуске загружаются из базы,
/// изменения сохраняются пачками через `markDirty`. Тела писем скачиваются лениво при открытии треда.
///
/// Все изменения применяются оптимистично: письмо сразу исчезает из списка,
/// а на сервер действие уходит после окна «Отменить». Если связи нет — действие ложится в журнал
/// и повторяется при следующей синхронизации.
@MainActor
@Observable
final class MailStore {
    // MARK: Состояние

    var accounts: [Account] {
        didSet {
            AccountRepository.save(accounts)
            reconnectChangedAccounts(old: oldValue)
        }
    }
    private(set) var messages: [String: Message] = [:]

    var scope: MailScope = .unified(.inbox)
    var selectedThreadID: String?
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            serverSearchState = .idle
            scheduleIndexSearch()
        }
    }
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

    /// Письма, тело которых сейчас скачивается, и ошибки скачивания.
    private(set) var loadingBodies: Set<String> = []
    private(set) var bodyErrors: [String: String] = [:]

    /// Найденное полнотекстовым индексом (тела писем) и поиском на сервере.
    private(set) var indexHits: Set<String> = []
    private(set) var serverSearchState: ServerSearchState = .idle

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
    private var idleTasks: [UUID: Task<Void, Never>] = [:]
    private var indexSearchTask: Task<Void, Never>?

    /// База писем (nil — не удалось открыть: работаем только в памяти).
    private let database: MailDatabase?
    /// Запись в базу — последовательно и не на главном потоке.
    private let persistQueue = DispatchQueue(label: "unimail.persist", qos: .utility)
    private var dirtyIDs: Set<String> = []
    private var persistTask: Task<Void, Never>?

    private var scheduledDrafts: [String: OutgoingMessage] = [:] {
        didSet { ScheduledDraftsFile.save(scheduledDrafts) }
    }

    private var undoSeconds: Double {
        let value = UserDefaults.standard.double(forKey: "undoSeconds")
        return value == 0 ? 5 : value
    }

    init() {
        let database = ProviderFactory.openDatabase()
        self.database = database
        ProviderFactory.database = database
        accounts = AccountRepository.load()
        for account in accounts {
            providers[account.id] = ProviderFactory.make(for: account)
        }
        loadStoredMessages()
    }

    /// Письма настоящих ящиков из базы + запланированные письма из файла.
    private func loadStoredMessages() {
        let live = Set(accounts.filter { $0.kind != .demo }.map(\.id))
        var loaded: [String: Message] = [:]
        if let database, !live.isEmpty {
            for message in (try? database.allMessages()) ?? [] where live.contains(message.accountID) {
                loaded[message.id] = message
            }
        }
        let known = Set(accounts.map(\.id))
        let scheduled = ScheduledDraftsFile.load().filter { known.contains($0.value.accountID) }
        for (id, draft) in scheduled where loaded[id] == nil {
            loaded[id] = scheduledMessage(id: id, draft: draft)
        }
        messages = loaded
        scheduledDrafts = scheduled
    }

    // MARK: Жизненный цикл

    func start() {
        guard backgroundLoop == nil else { return }
        Task {
            await refreshAll()
            startIdleLoops()
        }
        backgroundLoop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                self.wakeSnoozed()
                self.checkFollowUps()
                await self.sendDueScheduled()
                tick += 1
                // Ящики с IDLE сервер будит сам; полная сверка — раз в 5 минут.
                if tick % 15 == 0 {
                    await self.refreshAll()
                } else if tick % 3 == 0 {
                    await self.refreshAll(skippingIdle: true)
                }
            }
        }
    }

    func refreshAll(skippingIdle: Bool = false) async {
        let ids = accounts.map(\.id).filter { !skippingIdle || idleTasks[$0] == nil }
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
        await replayPendingActions(accountID: accountID, provider: provider)
        do {
            let result = try await provider.sync(cursor: cursors[accountID])
            cursors[accountID] = result.cursor
            accountErrors[accountID] = nil
            lastSync = .now
            merge(result, accountID: accountID)
        } catch {
            accountErrors[accountID] = error.localizedDescription
        }
    }

    /// Слияние результата синхронизации с локальным состоянием.
    private func merge(_ result: SyncResult, accountID: UUID) {
        let isDemo = account(accountID)?.kind == .demo
        var incoming: [Message] = []
        var serverFollowUps: [(MailAction, UUID)] = []
        // Для склейки тредов: письмо без References, но с In-Reply-To на уже известное письмо.
        lazy var threadByHeader: [String: String] = {
            var map: [String: String] = [:]
            for m in messages.values where m.accountID == accountID {
                if let header = m.headerMessageID { map[header] = m.threadID }
            }
            return map
        }()

        for var message in result.upserted {
            if let local = messages[message.id] {
                message = Self.merged(local: local, incoming: message)
                if message == local { continue }
            } else if !isDemo {
                let parents = [message.inReplyToHeader].compactMap { $0 } + (message.references ?? []).reversed()
                if let known = parents.lazy.compactMap({ threadByHeader[$0] }).first {
                    message.threadID = known
                }
                if let header = message.headerMessageID { threadByHeader[header] = message.threadID }
            }
            if messages[message.id] == nil && !isDemo && message.role == .inbox {
                // Новое входящее: категория и пользовательские правила.
                let original = message
                message = AutomationStore.shared.process(message, headers: result.headers[message.id] ?? [:]).0
                if message.role != original.role && message.role != .snoozed {
                    serverFollowUps.append((.move(ids: [message.id], to: message.role), accountID))
                }
                if message.isRead != original.isRead {
                    serverFollowUps.append((.markRead(ids: [message.id], read: message.isRead), accountID))
                }
                if message.isFlagged != original.isFlagged {
                    serverFollowUps.append((.flag(ids: [message.id], flagged: message.isFlagged), accountID))
                }
            }
            incoming.append(message)
        }

        // Копия отправленного письма пришла с сервера — локальная больше не нужна.
        let serverSent = Dictionary(
            incoming.filter { $0.role == .sent }.compactMap { m in m.headerMessageID.map { ($0, m.id) } },
            uniquingKeysWith: { a, _ in a }
        )
        let localSent = messages.values.filter {
            $0.accountID == accountID && $0.id.contains("|local-sent|")
                && serverSent[$0.headerMessageID ?? ""] != nil
        }

        guard !incoming.isEmpty || !result.deletedIDs.isEmpty || !localSent.isEmpty else { return }
        withAnimation(Motion.list) {
            for message in incoming { messages[message.id] = message }
            for id in result.deletedIDs { messages[id] = nil }
            for local in localSent {
                if let serverID = serverSent[local.headerMessageID ?? ""] {
                    messages[serverID]?.threadID = local.threadID
                    messages[serverID]?.followUpAt = local.followUpAt
                    messages[serverID]?.noReplyNotice = local.noReplyNotice
                }
                messages[local.id] = nil
            }
        }
        markDirty(incoming.map(\.id) + result.deletedIDs + localSent.map(\.id))

        for (action, accountID) in serverFollowUps {
            guard let provider = providers[accountID] else { continue }
            Task { await self.apply(action, provider: provider, accountID: accountID) }
        }
    }

    /// Сервер знает флаги и папку; локально — отложено, категория, напоминания, скачанное тело.
    private static func merged(local: Message, incoming: Message) -> Message {
        var m = incoming
        m.role = local.role
        m.snoozedUntil = local.snoozedUntil
        m.scheduledAt = local.scheduledAt
        m.category = local.category
        m.followUpAt = local.followUpAt
        m.noReplyNotice = local.noReplyNotice
        if local.bodyPending == false && incoming.bodyPending == true {
            m.body = local.body
            m.htmlBody = local.htmlBody
            m.attachments = local.attachments
            m.invite = local.invite
            m.bodyPending = false
        } else if local.bodyPending == true && incoming.bodyPending == true {
            // Обновление флагов пришло из базы — там сокращённая копия; оставляем то, что уже в памяти.
            m.body = local.body.count > incoming.body.count ? local.body : incoming.body
            m.attachments = local.attachments.isEmpty ? incoming.attachments : local.attachments
            m.invite = local.invite ?? incoming.invite
        }
        if let invite = local.invite, invite.response != nil { m.invite?.response = invite.response }
        return m
    }

    // MARK: IDLE

    private func startIdleLoops() {
        for account in accounts { startIdle(for: account.id) }
    }

    private func startIdle(for accountID: UUID) {
        guard idleTasks[accountID] == nil, let provider = providers[accountID], provider.isLive else { return }
        idleTasks[accountID] = Task { [weak self] in
            var backoff: Double = 30
            while !Task.isCancelled {
                do {
                    let changed = try await provider.waitForChanges(timeout: 25 * 60)
                    backoff = 30
                    if changed, !Task.isCancelled { await self?.refresh(accountID: accountID) }
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 600)
                }
            }
        }
    }

    private func stopIdle(for accountID: UUID) {
        idleTasks[accountID]?.cancel()
        idleTasks[accountID] = nil
    }

    // MARK: Хранение

    /// Отметить письма изменёнными: через ~0,7 с они запишутся в базу (или удалятся, если их больше нет).
    private func markDirty(_ ids: [String]) {
        guard database != nil, !ids.isEmpty else { return }
        dirtyIDs.formUnion(ids)
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.flushPersistence()
        }
    }

    /// Записать накопленные изменения. `wait` — дождаться записи (при выходе из приложения).
    func flushPersistence(wait: Bool = false) {
        persistTask?.cancel()
        persistTask = nil
        guard let database else { return }
        let ids = dirtyIDs
        dirtyIDs = []
        let demo = Set(accounts.filter { $0.kind == .demo }.map(\.id))
        var upserts: [Message] = []
        var deletes: [String] = []
        for id in ids {
            if let message = messages[id] {
                if !demo.contains(message.accountID) { upserts.append(Self.storageCopy(message)) }
            } else {
                deletes.append(id)
            }
        }
        let work: @Sendable () -> Void = { [upserts, deletes] in
            try? database.upsert(upserts)
            try? database.delete(ids: deletes)
        }
        if wait { persistQueue.sync(execute: work) } else if !ids.isEmpty { persistQueue.async(execute: work) }
    }

    /// В строке письма хранится только начало текста; полное тело — в таблице bodies.
    private static func storageCopy(_ message: Message) -> Message {
        guard message.bodyPending == false else { return message }
        var copy = message
        copy.htmlBody = nil
        copy.body = String(message.body.prefix(600))
        copy.bodyPending = true
        return copy
    }

    // MARK: Тела писем

    /// Скачать тела писем треда (из базы или с сервера).
    func loadBodies(threadID: String) {
        for message in thread(threadID) where message.bodyPending == true {
            loadBody(message.id)
        }
    }

    func loadBody(_ id: String) {
        guard let message = messages[id], message.bodyPending == true, !loadingBodies.contains(id) else { return }
        // Уже скачано раньше — берём из базы.
        if let stored = try? database?.body(for: id), stored.text != nil || stored.html != nil {
            messages[id]?.body = stored.text ?? MailFTS.plainText(fromHTML: stored.html ?? "")
            messages[id]?.htmlBody = stored.html
            messages[id]?.bodyPending = false
            return
        }
        guard let provider = providers[message.accountID] else { return }
        loadingBodies.insert(id)
        bodyErrors[id] = nil
        Task {
            defer { loadingBodies.remove(id) }
            do {
                let content = try await provider.fetchContent(for: message)
                applyContent(content, to: id)
            } catch {
                bodyErrors[id] = error.localizedDescription
            }
        }
    }

    private func applyContent(_ content: MessageContent, to id: String) {
        guard var message = messages[id] else { return }
        let text = content.text ?? ""
        message.body = text.isEmpty ? message.body : text
        message.htmlBody = content.html
        message.attachments = content.attachments
        message.attachmentHint = !content.attachments.isEmpty
        if var invite = content.invite {
            invite.response = message.invite?.response
            message.invite = invite
        }
        if let unsubscribe = content.listUnsubscribe {
            message.listUnsubscribe = unsubscribe
            message.listUnsubscribePost = content.listUnsubscribePost
        }
        if !content.references.isEmpty { message.references = content.references }
        message.inReplyToHeader = message.inReplyToHeader ?? content.inReplyTo
        message.headerMessageID = message.headerMessageID ?? content.messageID
        message.bodyPending = false
        withAnimation(Motion.snappy) { messages[id] = message }

        markDirty([id])
        flushPersistence()
        if let database {
            let body = StoredBody(text: content.text, html: content.html)
            persistQueue.async { try? database.setBody(body, for: id) }
        }
    }

    /// Исходник письма (.eml) с сервера — для экспорта.
    func rawSource(of messageID: String) async -> Data? {
        guard let message = messages[messageID], let provider = providers[message.accountID] else { return nil }
        return try? await provider.rawSource(for: message)
    }

    // MARK: Поиск

    private func scheduleIndexSearch() {
        indexSearchTask?.cancel()
        let terms = SearchQuery(searchText).terms.joined(separator: " ")
        guard let database, !terms.isEmpty else {
            indexHits = []
            return
        }
        let accountID = scope.accountID
        indexSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let ids = await Task.detached(priority: .userInitiated) {
                (try? database.search(terms, accountID: accountID, limit: 500)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            self?.indexHits = Set(ids)
        }
    }

    /// Можно ли искать на сервере: есть текст и хотя бы один настоящий ящик в текущем списке.
    var canSearchServer: Bool {
        !SearchQuery(searchText).terms.isEmpty && !serverSearchAccounts.isEmpty
    }

    private var serverSearchAccounts: [UUID] {
        accounts.map(\.id).filter { id in
            (scope.accountID == nil || scope.accountID == id) && providers[id]?.isLive == true
        }
    }

    func searchOnServer() {
        let terms = SearchQuery(searchText).terms.joined(separator: " ")
        guard !terms.isEmpty else { return }
        let targets = serverSearchAccounts
        guard !targets.isEmpty else { return }
        serverSearchState = .searching
        Task {
            var found: [Message] = []
            var failure: String?
            for id in targets {
                guard let provider = providers[id] else { continue }
                do { found += try await provider.serverSearch(terms) } catch { failure = error.localizedDescription }
            }
            let fresh = found.filter { messages[$0.id] == nil }
            withAnimation(Motion.list) {
                for message in fresh { messages[message.id] = message }
            }
            markDirty(fresh.map(\.id))
            indexHits.formUnion(found.map(\.id))
            if found.isEmpty, let failure {
                serverSearchState = .failed(failure)
            } else {
                serverSearchState = .done(found: Set(found.map(\.threadID)).count)
            }
        }
    }

    // MARK: Аккаунты

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func addAccount(_ account: Account, secret: String?) {
        var account = account
        account.migrateSignatures()
        // Новый ящик сразу с подписью из имени отправителя — её можно поменять в настройках.
        if account.signatureList.isEmpty, let name = account.senderName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let main = MailSignature(name: "Основная", text: name)
            account.signatures = [main]
            account.newMailSignatureID = main.id
            account.replySignatureID = main.id
        }
        if let secret, !secret.isEmpty {
            try? Keychain.set(secret, for: account.id.uuidString)
        }
        providers[account.id] = ProviderFactory.make(for: account)
        accounts.append(account)
        withAnimation(Motion.snappy) { scope = .account(account.id, .inbox) }
        Task {
            await refresh(accountID: account.id)
            startIdle(for: account.id)
        }
    }

    /// Проверка входа для мастера добавления ящика (IMAP и SMTP), без сохранения пароля.
    func verify(_ account: Account, secret: String) async throws {
        let provider = ProviderFactory.make(for: account, password: secret)
        defer { Task { await provider.disconnect() } }
        try await provider.verifyLogin()
    }

    /// Новый пароль из настроек: сохраняем в Связке ключей и переподключаемся.
    func updatePassword(_ secret: String, for accountID: UUID) {
        guard !secret.isEmpty, let account = account(accountID) else { return }
        try? Keychain.set(secret, for: accountID.uuidString)
        reconnect(account)
    }

    private func reconnect(_ account: Account) {
        stopIdle(for: account.id)
        if let old = providers[account.id] { Task { await old.disconnect() } }
        providers[account.id] = ProviderFactory.make(for: account)
        accountErrors[account.id] = nil
        Task {
            await refresh(accountID: account.id)
            startIdle(for: account.id)
        }
    }

    /// Изменились сервер, адрес или имя отправителя — провайдер пересоздаётся.
    private func reconnectChangedAccounts(old: [Account]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for account in accounts {
            guard let previous = before[account.id], providers[account.id] != nil else { continue }
            if previous.server != account.server || previous.exchange != account.exchange || previous.email != account.email
                || previous.senderName != account.senderName || previous.kind != account.kind {
                reconnect(account)
            }
        }
    }

    func removeAccount(_ id: UUID) {
        Keychain.remove(id.uuidString)
        stopIdle(for: id)
        if let provider = providers[id] { Task { await provider.disconnect() } }
        providers[id] = nil
        cursors[id] = nil
        accountErrors[id] = nil
        scheduledDrafts = scheduledDrafts.filter { $0.value.accountID != id }
        if let database { persistQueue.async { try? database.deleteAccount(id) } }
        withAnimation(Motion.snappy) {
            accounts.removeAll { $0.id == id }
            messages = messages.filter { $0.value.accountID != id }
            if scope.accountID == id { scope = .unified(.inbox) }
        }
    }

    /// Убрать все демо-ящики разом.
    func removeDemoAccounts() {
        for account in accounts where account.kind == .demo {
            removeAccount(account.id)
        }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { accounts[$0] }
        var rest = accounts.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = max(0, min(rest.count, destination - source.filter { $0 < destination }.count))
        rest.insert(contentsOf: moving, at: insertAt)
        accounts = rest
    }

    /// Для проверок на Linux: подставить провайдера с фейковым сервером.
    func installProvider(_ provider: any MailProvider, for accountID: UUID) {
        providers[accountID] = provider
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
        if accountChanged {
            if !searchText.isEmpty { scheduleIndexSearch() }
            if let first = selectedThreadID { openThread(first) }
        }
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
        // Исходящее без ответа возвращается во «Входящие» напоминанием.
        case .inbox: m.role == .inbox || (m.role == .sent && m.noReplyNotice == true)
        default: m.role == role
        }
    }

    /// Письма, видимые в текущем списке.
    func visibleMessages(in scope: MailScope) -> [Message] {
        let query = SearchQuery(searchText)
        let filter = quickFilter
        let hits = indexHits
        return messages.values.filter { m in
            guard inScopeAccounts(m, scope) else { return false }
            if !query.isEmpty {
                // Поиск идёт по всем папкам, кроме спама и корзины (если не попросили искать везде).
                guard searchEverywhere || (m.role != .trash && m.role != .spam) else { return false }
                return query.matches(m) || (hits.contains(m.id) && query.matchesFilters(m))
            }
            guard matchesRole(m, scope.role) else { return false }
            if scope.role == .inbox, let categoryFilter, m.role == .inbox, m.category != categoryFilter { return false }
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
                hasAttachments: items.contains(where: \.hasAttachments)
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

    /// Тред — напоминание «нет ответа» (последнее исходящее без ответа).
    func isAwaitingReply(threadID: String) -> Bool {
        messages.values.contains { $0.threadID == threadID && $0.role == .sent && $0.noReplyNotice == true }
    }

    // MARK: Действия

    private func messageIDs(ofThreads threadIDs: [String]) -> [String] {
        let set = Set(threadIDs)
        let visible = visibleMessages(in: scope)
        return visible.filter { set.contains($0.threadID) }.map(\.id)
    }

    func openThread(_ threadID: String) {
        loadBodies(threadID: threadID)
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
        markDirty(messageIDs)
        push(messageIDs) { .markRead(ids: $0, read: read) }
    }

    func toggleFlag(threadIDs: [String]) {
        let ids = messageIDs(ofThreads: threadIDs)
        let flag = !ids.contains { messages[$0]?.isFlagged == true }
        withAnimation(Motion.bouncy) {
            for id in ids { messages[id]?.isFlagged = flag }
        }
        markDirty(ids)
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
            markDirty(ids)
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
        let ids = withoutFollowUpReminders(messageIDs(ofThreads: threadIDs))
        perform(title: title, symbol: symbol, ids: ids, action: { .move(ids: $0, to: role) }) { message in
            message.role = role
            message.snoozedUntil = nil
        }
    }

    func snooze(threadIDs: [String], until date: Date, label: String? = nil) {
        let ids = withoutFollowUpReminders(messageIDs(ofThreads: threadIDs))
        let formatted = date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let title = label.map { "Отложено: \($0.lowercased()) · \(formatted)" } ?? "Отложено до \(formatted)"
        perform(title: title, symbol: "clock", ids: ids,
                action: { .snooze(ids: $0, until: date) }) { message in
            message.role = .snoozed
            message.snoozedUntil = date
            message.isRead = true
        }
    }

    /// Исходящие-напоминания во «Входящих» не переносятся в архив/корзину — с них просто снимается напоминание.
    private func withoutFollowUpReminders(_ ids: [String]) -> [String] {
        let reminders = ids.filter { messages[$0]?.role == .sent && messages[$0]?.noReplyNotice == true }
        guard !reminders.isEmpty else { return ids }
        withAnimation(Motion.list) {
            for id in reminders {
                messages[id]?.noReplyNotice = nil
                messages[id]?.followUpAt = nil
            }
        }
        markDirty(reminders)
        let set = Set(reminders)
        return ids.filter { !set.contains($0) }
    }

    /// «Снять напоминание» в треде.
    func dismissFollowUp(threadID: String) {
        let ids = messages.values.filter { $0.threadID == threadID && $0.followUpAt != nil }.map(\.id)
        _ = withoutFollowUpReminders(ids)
        withAnimation(Motion.list) { for id in ids { messages[id]?.followUpAt = nil } }
        markDirty(ids)
    }

    /// «Напомнить, если не ответят» для уже отправленного письма.
    func remindIfNoReply(messageID: String, at date: Date? = nil) {
        guard messages[messageID]?.role == .sent else { return }
        messages[messageID]?.followUpAt = date ?? AutomationStore.shared.followUpDate(after: .now)
        messages[messageID]?.noReplyNotice = nil
        markDirty([messageID])
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
        markDirty(due.map(\.id))
        // На сервере письмо всё это время лежало во «Входящих» прочитанным.
        push(due.map(\.id)) { .markRead(ids: $0, read: false) }
    }

    /// Напоминания «нет ответа»: подошёл срок — тред возвращается во «Входящие»; ответили — снимаем.
    func checkFollowUps() {
        let all = Array(messages.values.filter { $0.followUpAt != nil || $0.role != .sent })
        guard all.contains(where: { $0.followUpAt != nil }) else { return }
        let mine = Set(accounts.flatMap { [$0.email] + $0.aliases })
        let resolved = FollowUp.resolved(all, myAddresses: mine)
        let due = FollowUp.due(all, now: .now, myAddresses: mine).filter { $0.noReplyNotice != true }
        guard !resolved.isEmpty || !due.isEmpty else { return }
        withAnimation(Motion.list) {
            for id in resolved {
                messages[id]?.followUpAt = nil
                messages[id]?.noReplyNotice = nil
            }
            for message in due { messages[message.id]?.noReplyNotice = true }
        }
        markDirty(resolved + due.map(\.id))
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
        markDirty(ids)

        pendingRestore = { [weak self] in
            guard let self else { return }
            withAnimation(Motion.list) {
                for m in snapshot { self.messages[m.id] = m }
            }
            self.markDirty(snapshot.map(\.id))
        }
        let byAccount = Dictionary(grouping: snapshot, by: \.accountID).mapValues { $0.map(\.id) }
        pendingCommit = { [weak self] in
            guard let self else { return }
            for (accountID, ids) in byAccount {
                guard let provider = self.providers[accountID] else { continue }
                await self.apply(action(ids), provider: provider, accountID: accountID)
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
            Task { await self.apply(action(ids), provider: provider, accountID: accountID) }
        }
    }

    /// Выполнить действие на сервере; без связи — в журнал, повторим при синхронизации.
    private func apply(_ action: MailAction, provider: any MailProvider, accountID: UUID) async {
        // Локальные письма (черновики, запланированные, копии отправленных) на сервер не уходят.
        var action = action
        if provider.isLive {
            let serverIDs = action.ids.filter(Self.isServerMessageID)
            guard !serverIDs.isEmpty else { return }
            action = action.withIDs(serverIDs)
        }
        do {
            try await provider.apply(action)
        } catch {
            if Self.isRetryable(error), let database, let payload = try? JSONEncoder().encode(action) {
                let record = PendingActionRecord(id: UUID(), accountID: accountID, kind: "action",
                                                 payload: payload, createdAt: .now, attempts: 0)
                persistQueue.async { try? database.enqueue(record) }
                accountErrors[accountID] = "Нет связи — действие выполнится, когда сервер ответит"
            } else {
                accountErrors[accountID] = error.localizedDescription
            }
        }
    }

    private func replayPendingActions(accountID: UUID, provider: any MailProvider) async {
        guard let database else { return }
        let records = await withCheckedContinuation { continuation in
            persistQueue.async {
                continuation.resume(returning: (try? database.pendingActions(accountID: accountID)) ?? [])
            }
        }
        for record in records {
            let recordID = record.id
            guard let action = try? JSONDecoder().decode(MailAction.self, from: record.payload) else {
                persistQueue.async { try? database.removeAction(id: recordID) }
                continue
            }
            do {
                try await provider.apply(action)
                persistQueue.async { try? database.removeAction(id: recordID) }
            } catch {
                var updated = record
                updated.attempts += 1
                let give = updated.attempts >= 10 || !Self.isRetryable(error)
                persistQueue.async { [updated] in
                    if give { try? database.removeAction(id: updated.id) } else { try? database.updateAction(updated) }
                }
                if Self.isRetryable(error) { return }
            }
        }
    }

    /// Письмо лежит на сервере (IMAP или Exchange), а не только здесь (черновик, запланированное, копия отправленного).
    static func isServerMessageID(_ id: String) -> Bool {
        (IMAPProvider.location(of: id) != nil || EWSProvider.location(of: id) != nil) && !id.contains("|local-sent|")
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is MailTransportError || error is URLError { return true }
        if case MailProviderError.network = error { return true }
        return false
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

    // MARK: Категории и отписка

    /// «Переместить отправителя в категорию»: запоминаем и сразу пересортировываем его письма.
    func setCategory(_ category: InboxCategory, forSenderOf messageID: String) {
        guard let source = messages[messageID] else { return }
        AutomationStore.shared.learnCategory(for: source.from, category: category)
        let key = Categorizer.normalize(source.from.email)
        let ids = messages.values.filter { Categorizer.normalize($0.from.email) == key && $0.role == .inbox }.map(\.id)
        withAnimation(Motion.list) {
            for id in ids { messages[id]?.category = category }
        }
        markDirty(ids)
    }

    /// Отписка выполнена — письмо помечаем, чтобы кнопка больше не предлагалась.
    func markUnsubscribed(messageID: String) {
        guard let threadID = messages[messageID]?.threadID else { return }
        let ids = messages.values.filter { $0.threadID == threadID }.map(\.id)
        for id in ids { messages[id]?.listUnsubscribe = nil }
        markDirty(ids)
    }

    // MARK: Приглашения

    /// Ответ на приглашение: запись в Календарь и iCalendar REPLY организатору.
    @discardableResult
    func respondToInvite(messageID: String, status: ICSPartStat) async -> Bool {
        guard let message = messages[messageID], let invite = message.invite,
              let account = account(message.accountID) else { return false }
        withAnimation(Motion.snappy) { messages[messageID]?.invite?.response = status.rawValue }
        markDirty([messageID])

        var ok = true
        if status != .declined {
            ok = await CalendarService.shared.addEvent(from: invite, notes: "Из письма: \(message.subject)")
        }
        if let ics = invite.ics, let event = ICSParser.parse(ics).first,
           let organizer = invite.organizer ?? event.organizer, providers[account.id]?.isLive == true {
            let me = Address(name: account.senderName ?? account.displayName, email: account.email)
            let reply = ICSBuilder.reply(to: event, attendee: me, status: status)
            let verb: String
            switch status {
            case .accepted: verb = "Принято"
            case .tentative: verb = "Под вопросом"
            case .declined: verb = "Отклонено"
            }
            var draft = OutgoingMessage(accountID: account.id, fromAddress: account.email,
                                        to: [organizer], cc: [], bcc: [],
                                        subject: "\(verb): \(invite.title)",
                                        body: "\(verb): \(invite.title)")
            draft.threadID = message.threadID
            draft.inReplyTo = message.id
            draft.calendarReply = reply
            await deliver(draft, silent: true)
        }
        return ok
    }

    // MARK: Написание

    func compose(_ mode: ComposeRequest.Mode = .new, from messageID: String? = nil) {
        let source = messageID.flatMap { messages[$0] }
        let accountID = source?.accountID ?? scope.accountID ?? accounts.first?.id
        guard let accountID, let account = self.account(accountID) else { return }

        var requestID = UUID()
        var draft = OutgoingMessage(
            accountID: accountID, fromAddress: account.email,
            to: [], cc: [], bcc: [], subject: "",
            body: ""
        )
        // Подпись подставляется автоматически: своя для новых писем и для ответов/пересылок.
        let signature = account.signatureText(for: mode == .new ? .newMail : .reply)
        if mode != .draft && !signature.isEmpty {
            draft.body = "\n\n--\n\(signature)"
        }
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
                // Вложения пересылаемого письма, если они уже скачаны.
                draft.attachmentURLs = source.attachments.compactMap { $0.localPath }.map { URL(fileURLWithPath: $0) }
            case .draft:
                draft.to = source.to
                draft.cc = source.cc
                draft.subject = source.subject == "(без темы)" ? "" : source.subject
                draft.body = source.body
                draft.htmlBody = source.htmlBody
                draft.attachmentURLs = source.attachments.compactMap { $0.localPath }.map { URL(fileURLWithPath: $0) }
                draft.inReplyTo = source.inReplyToHeader.flatMap { messages[$0] != nil ? $0 : nil }
                draft.threadID = source.threadID == source.id ? nil : source.threadID
                // Тот же черновик: сохранение перезапишет его, а не создаст второй.
                if source.id.hasPrefix("draft-"), let uuid = UUID(uuidString: String(source.id.dropFirst(6))) {
                    requestID = uuid
                }
            case .new:
                break
            }
        }
        composeQueue.append(ComposeRequest(id: requestID, mode: mode, draft: draft))
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
        var message = Message(
            id: id, accountID: draft.accountID, threadID: draft.threadID ?? id, role: .drafts,
            from: Address(name: account.senderName ?? account.displayName, email: draft.fromAddress),
            to: draft.to, cc: draft.cc, subject: draft.subject.isEmpty ? "(без темы)" : draft.subject,
            body: draft.body, date: .now, isRead: true
        )
        message.htmlBody = draft.htmlBody
        message.attachments = draft.attachmentURLs.map(Self.attachment(for:))
        // Локальный id письма, на которое отвечаем, — чтобы восстановить заголовки треда.
        message.inReplyToHeader = draft.inReplyTo
        messages[id] = message
        markDirty([id])
    }

    static func attachment(for url: URL) -> Attachment {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Attachment(filename: url.lastPathComponent, size: size, mimeType: IMAPProvider.mimeType(for: url),
                          partID: nil, contentID: nil, localPath: url.path)
    }

    func discardDraft(requestID: UUID) {
        let id = "draft-\(requestID.uuidString)"
        guard messages[id] != nil else { return }
        messages[id] = nil
        markDirty([id])
    }

    /// Отправка с окном «Отменить». Если задано время — письмо уходит в «Запланированные».
    func send(_ draft: OutgoingMessage, requestID: UUID, undoTitle: String = "Письмо отправляется…") {
        discardDraft(requestID: requestID)
        flushPending()

        if let sendAt = draft.sendAt, sendAt > .now {
            let id = "scheduled-\(requestID.uuidString)"
            schedule(draft, id: id)
            let when = sendAt.formatted(.dateTime.day().month().hour().minute())
            showUndo(PendingUndo(title: "Отправится \(when)", symbol: "calendar.badge.clock"))
            pendingRestore = { [weak self] in
                self?.unschedule(id)
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

    private func scheduledMessage(id: String, draft: OutgoingMessage) -> Message {
        var message = Message(
            id: id, accountID: draft.accountID, threadID: draft.threadID ?? id, role: .scheduled,
            from: Address(name: account(draft.accountID)?.displayName, email: draft.fromAddress),
            to: draft.to, cc: draft.cc, subject: draft.subject, body: draft.body,
            date: .now, isRead: true
        )
        message.htmlBody = draft.htmlBody
        message.scheduledAt = draft.sendAt
        message.attachments = draft.attachmentURLs.map(Self.attachment(for:))
        return message
    }

    private func schedule(_ draft: OutgoingMessage, id: String) {
        withAnimation(Motion.list) { messages[id] = scheduledMessage(id: id, draft: draft) }
        scheduledDrafts[id] = draft
        markDirty([id])
    }

    private func unschedule(_ id: String) {
        messages[id] = nil
        scheduledDrafts[id] = nil
        markDirty([id])
    }

    /// «Отправить сейчас» для запланированного письма.
    func sendScheduledNow(messageID: String) {
        guard let draft = scheduledDrafts[messageID] else { return }
        unschedule(messageID)
        var now = draft
        now.sendAt = nil
        Task { await deliver(now) }
    }

    /// «Изменить» запланированное письмо: снимаем с отправки и открываем окно.
    func editScheduled(messageID: String) {
        guard let draft = scheduledDrafts[messageID] else { return }
        unschedule(messageID)
        composeQueue.append(ComposeRequest(mode: .draft, draft: draft))
    }

    func sendDueScheduled() async {
        let due = scheduledDrafts.filter { ($0.value.sendAt ?? .distantFuture) <= .now }
        for (id, draft) in due {
            unschedule(id)
            await deliver(draft)
        }
    }

    /// Письмо появляется в «Отправленных» только после подтверждения сервером.
    private func deliver(_ original: OutgoingMessage, silent: Bool = false) async {
        guard let provider = providers[original.accountID] else { return }
        var draft = original
        // Заголовки треда: на кого отвечаем.
        if let sourceID = draft.inReplyTo, let source = messages[sourceID] {
            if draft.inReplyToHeader == nil { draft.inReplyToHeader = source.headerMessageID }
            if draft.referenceHeaders == nil, let header = source.headerMessageID {
                var refs = source.references ?? []
                if let parent = source.inReplyToHeader, !refs.contains(parent) { refs.append(parent) }
                if !refs.contains(header) { refs.append(header) }
                draft.referenceHeaders = refs
            }
        }
        do {
            var sent = try await provider.send(draft)
            if draft.remindIfNoReply {
                sent.followUpAt = AutomationStore.shared.followUpDate(after: sent.date)
            }
            withAnimation(Motion.list) { messages[sent.id] = sent }
            markDirty([sent.id])
            if accountErrors[draft.accountID]?.hasPrefix("Не отправлено") == true { accountErrors[draft.accountID] = nil }
        } catch {
            if silent {
                accountErrors[draft.accountID] = "Ответ на приглашение не отправлен: \(error.localizedDescription)"
            } else if Self.isRetryable(error) {
                // Без связи письмо ждёт в «Запланированных» и уйдёт само через пару минут.
                var retry = original
                retry.sendAt = Date.now.addingTimeInterval(120)
                schedule(retry, id: "scheduled-\(UUID().uuidString)")
                accountErrors[draft.accountID] = "Нет связи — письмо в «Запланированных», повторим через 2 минуты"
            } else {
                accountErrors[draft.accountID] = "Не отправлено: \(error.localizedDescription)"
                composeQueue.append(ComposeRequest(mode: .draft, draft: original))
            }
        }
    }
}

/// Запланированные письма переживают перезапуск: ~/Library/Application Support/UniMail/scheduled.json.
enum ScheduledDraftsFile {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("UniMail/scheduled.json")
    }

    static func load() -> [String: OutgoingMessage] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: OutgoingMessage].self, from: data)) ?? [:]
    }

    static func save(_ drafts: [String: OutgoingMessage]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(drafts) { try? data.write(to: url, options: .atomic) }
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
        case .attachments: m.hasAttachments
        }
    }
}
