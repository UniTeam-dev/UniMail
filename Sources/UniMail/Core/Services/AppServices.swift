import AppKit
import Foundation
import Observation

/// Связывает `MailStore` с системными сервисами: бейдж Dock, уведомления о новых письмах,
/// действия из уведомлений, старт «без окна».
///
/// Новые письма определяются наблюдением за `MailStore.messages` (Observation), поэтому
/// в `MailStore` ничего менять не нужно. Первая порция писем каждого ящика (начальная
/// синхронизация) считается уже известной и уведомлений не вызывает.
@MainActor
final class AppServices {
    static let shared = AppServices()

    private(set) var store: MailStore?

    /// Все ID писем, которые мы уже видели (уведомляем только о новых ID).
    private var seenIDs: Set<String> = []
    /// Ящики, у которых первая порция писем уже пришла.
    private var primedAccounts: Set<UUID> = []
    /// Треды с непрочитанными во «Входящих» на прошлом шаге — чтобы убирать их баннеры.
    private var unreadThreads: Set<String> = []
    private var pendingUpdate: Task<Void, Never>?

    private init() {}

    // MARK: Запуск

    /// Вызывать один раз при создании приложения (`UniMailApp.init`).
    func attach(_ store: MailStore) {
        guard self.store == nil else { return }
        self.store = store

        let notifications = NotificationService.shared
        notifications.actionHandler = { action in
            AppServices.shared.handle(action)
        }
        notifications.isThreadVisible = { threadID in
            AppServices.shared.store?.selectedThreadID == threadID
                && WindowRouter.shared.mainWindow?.isKeyWindow == true
        }
        observe()
    }

    /// `applicationWillFinishLaunching`: делегат уведомлений должен быть назначен до конца запуска.
    func applicationWillFinishLaunching() {
        NotificationService.shared.configure()
    }

    /// `applicationDidFinishLaunching`: автозапуск «без окна», разрешение на уведомления, синхронизация.
    /// Возвращает `true`, если приложение нужно оставить скрытым.
    @discardableResult
    func applicationDidFinishLaunching() -> Bool {
        let launch = LaunchAtLoginService.shared
        launch.captureLaunchContext()
        let hidden = launch.shouldStartHidden
        if hidden {
            WindowRouter.shared.hideForBackgroundLaunch()
        }
        // Синхронизация нужна и без окна (RootView тоже вызывает start — вызов идемпотентен).
        store?.start()
        refreshBadge()

        if AppSettings.bool(AppSettings.notificationsEnabled) {
            Task {
                let service = NotificationService.shared
                if await service.authorizationStatus() == .notDetermined {
                    await service.requestAuthorization()
                }
            }
        }
        return hidden
    }

    // MARK: Действия из уведомлений

    func handle(_ action: NotificationAction) {
        guard let store else { return }
        switch action {
        case .archive(let threadID):
            store.archiveAnywhere(threadID: threadID)
        case .markRead(let threadID):
            store.markThreadRead(threadID: threadID)
        case .reply(let threadID, let text):
            store.sendQuickReply(threadID: threadID, text: text)
        case .open(let threadID):
            WindowRouter.shared.showMain()
            store.reveal(threadID: threadID)
        }
    }

    // MARK: Бейдж Dock

    func refreshBadge() {
        let count = store?.totalInboxUnread ?? 0
        applyBadge(count)
    }

    private func applyBadge(_ count: Int) {
        // attach() вызывается из UniMailApp.init, когда NSApp ещё nil: бейдж выставит refreshBadge()
        // в applicationDidFinishLaunching.
        guard let app = NSApp else { return }
        let show = AppSettings.bool(AppSettings.showDockBadge) && count > 0
        let label = show ? (count > 999 ? "999+" : "\(count)") : nil
        if app.dockTile.badgeLabel != label {
            app.dockTile.badgeLabel = label
        }
    }

    // MARK: Наблюдение за хранилищем

    private struct Snapshot {
        var allIDs: Set<String>
        var accountsWithMail: Set<UUID>
        var unreadInbox: [Message]
    }

    private func observe() {
        guard let store else { return }
        let snapshot = withObservationTracking {
            Self.makeSnapshot(store)
        } onChange: {
            Task { @MainActor in AppServices.shared.scheduleUpdate() }
        }
        process(snapshot)
    }

    private static func makeSnapshot(_ store: MailStore) -> Snapshot {
        var ids = Set<String>()
        var accounts = Set<UUID>()
        var unread: [Message] = []
        ids.reserveCapacity(store.messages.count)
        for message in store.messages.values {
            ids.insert(message.id)
            accounts.insert(message.accountID)
            if message.role == .inbox && !message.isRead { unread.append(message) }
        }
        // Названия ящиков тоже наблюдаем — для подписи в уведомлении.
        _ = store.accounts.count
        return Snapshot(allIDs: ids, accountsWithMail: accounts, unreadInbox: unread)
    }

    /// Изменения приходят пачками (синхронизация, анимации) — обрабатываем не чаще раза в 250 мс.
    private func scheduleUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            AppServices.shared.observe()
        }
    }

    private func process(_ snapshot: Snapshot) {
        applyBadge(snapshot.unreadInbox.count)

        // Новые письма: ID ещё не встречался, а ящик уже прошёл первую синхронизацию.
        let fresh = snapshot.unreadInbox.filter { !seenIDs.contains($0.id) && primedAccounts.contains($0.accountID) }
        seenIDs.formUnion(snapshot.allIDs)
        primedAccounts.formUnion(snapshot.accountsWithMail)

        if !fresh.isEmpty, let store {
            NotificationService.shared.notifyNewMessages(fresh) { accountID in
                store.accounts.count > 1 ? (store.account(accountID)?.displayName ?? "") : ""
            }
        }

        // Тред прочитан, заархивирован или удалён — его баннер больше не нужен.
        let nowUnread = Set(snapshot.unreadInbox.map(\.threadID))
        let cleared = unreadThreads.subtracting(nowUnread)
        unreadThreads = nowUnread
        NotificationService.shared.clearDelivered(threadIDs: cleared)
    }
}
