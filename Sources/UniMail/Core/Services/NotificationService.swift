import AppKit
import Foundation
import UserNotifications

/// Что пользователь сделал с уведомлением.
enum NotificationAction: Equatable, Sendable {
    case archive(threadID: String)
    case markRead(threadID: String)
    case reply(threadID: String, text: String)
    case open(threadID: String)
}

/// Идентификаторы категорий и действий (вне класса — доступны и из nonisolated-методов делегата).
enum NotificationIDs {
    static let messageCategory = "UNIMAIL_MESSAGE"
    static let summaryCategory = "UNIMAIL_SUMMARY"
    static let archiveAction = "UNIMAIL_ARCHIVE"
    static let readAction = "UNIMAIL_READ"
    static let replyAction = "UNIMAIL_REPLY"
    static let summaryThread = "unimail.summary"
}

/// Системные уведомления о новых письмах с действиями «Архив», «Прочитано», «Ответить».
///
/// Уведомления группируются по треду (`threadIdentifier = message.threadID`). Если в одной
/// пачке новых писем больше трёх тредов, вместо отдельных баннеров приходит одна сводка.
/// Учитываются настройки `notificationsEnabled` и `notifyNewsletters`.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Обработчик действий из уведомлений. Вызывается на главном потоке.
    var actionHandler: ((NotificationAction) -> Void)?

    /// Открыт ли этот тред прямо сейчас на экране. Если да, баннер не показывается.
    var isThreadVisible: ((String) -> Bool)?


    /// Письма, о которых уже уведомили (чтобы не повторяться после следующей синхронизации).
    private var notifiedIDs: Set<String> = []
    private var configured = false

    private override init() {
        super.init()
    }

    /// UNUserNotificationCenter падает, если процесс запущен не из .app-бандла
    /// (например, голый бинарь из `swift run`). В этом случае сервис молча выключен.
    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? {
        isAvailable ? UNUserNotificationCenter.current() : nil
    }

    // MARK: Настройка

    /// Назначает делегата и регистрирует категории. Вызывать до окончания запуска
    /// (`applicationWillFinishLaunching`), чтобы не потерять нажатие на уведомление, которым приложение запустили.
    func configure() {
        guard !configured, let center else { return }
        configured = true
        center.delegate = self

        let archive = UNNotificationAction(identifier: NotificationIDs.archiveAction, title: "Архив", options: [])
        let read = UNNotificationAction(identifier: NotificationIDs.readAction, title: "Прочитано", options: [])
        let reply = UNTextInputNotificationAction(
            identifier: NotificationIDs.replyAction,
            title: "Ответить",
            options: [],
            textInputButtonTitle: "Отправить",
            textInputPlaceholder: "Ваш ответ…"
        )
        let message = UNNotificationCategory(
            identifier: NotificationIDs.messageCategory,
            actions: [archive, read, reply],
            intentIdentifiers: [],
            options: []
        )
        let summary = UNNotificationCategory(
            identifier: NotificationIDs.summaryCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([message, summary])
    }

    /// Запрашивает разрешение. Возвращает `true`, если уведомления разрешены.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        configure()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Текущий статус разрешения в системе.
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Системные настройки → Уведомления → UniMail.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.il1ja.unimail"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Новые письма

    /// Показывает уведомления о новых письмах.
    ///
    /// - Берутся только непрочитанные письма во «Входящих», о которых ещё не уведомляли.
    /// - Рассылки — только если включено `notifyNewsletters`.
    /// - Один баннер на тред; если тредов больше трёх — одна сводка «N новых писем».
    /// - Parameter accountName: название ящика по `accountID` («Работа»); пустая строка — не показывать.
    func notifyNewMessages(_ messages: [Message], accountName: (UUID) -> String) {
        let fresh = messages.filter { !notifiedIDs.contains($0.id) }
        notifiedIDs.formUnion(fresh.map(\.id))
        guard AppSettings.bool(AppSettings.notificationsEnabled), let center else { return }

        let includeNewsletters = AppSettings.bool(AppSettings.notifyNewsletters)
        let candidates = fresh.filter { message in
            message.role == .inbox && !message.isRead && (includeNewsletters || message.category != .newsletters)
        }
        guard !candidates.isEmpty else { return }

        let byThread = Dictionary(grouping: candidates, by: \.threadID)
            .map { threadID, items in (threadID, items.sorted { $0.date > $1.date }) }
            .sorted { ($0.1.first?.date ?? .distantPast) > ($1.1.first?.date ?? .distantPast) }

        if byThread.count > 3 {
            postSummary(byThread.map { $0.1 }, center: center)
            return
        }

        for (threadID, items) in byThread {
            guard let latest = items.first else { continue }
            let content = UNMutableNotificationContent()
            content.title = latest.from.display
            let account = accountName(latest.accountID)
            var subtitle = latest.subject.isEmpty ? "(без темы)" : latest.subject
            if !account.isEmpty { subtitle = "\(account) · \(subtitle)" }
            content.subtitle = subtitle
            var body = latest.snippet
            if items.count > 1 {
                let more = items.count - 1
                body = "+\(more) \(plural(more, "письмо", "письма", "писем")) · " + body
            }
            content.body = body
            content.sound = .default
            content.threadIdentifier = threadID
            content.categoryIdentifier = NotificationIDs.messageCategory
            content.userInfo = [
                "threadID": threadID,
                "messageID": latest.id,
                "accountID": latest.accountID.uuidString,
            ]
            // Один баннер на тред: новый заменяет предыдущий из того же треда.
            let request = UNNotificationRequest(identifier: "thread-\(threadID)", content: content, trigger: nil)
            center.add(request) { error in
                if let error { NSLog("UniMail: уведомление не показано: %@", error.localizedDescription) }
            }
        }
    }

    private func postSummary(_ threads: [[Message]], center: UNUserNotificationCenter) {
        let total = threads.reduce(0) { $0 + $1.count }
        var senders: [String] = []
        for items in threads {
            guard let name = items.first?.from.display, !senders.contains(name) else { continue }
            senders.append(name)
        }
        let shown = senders.prefix(3).joined(separator: ", ")
        let rest = senders.count - min(senders.count, 3)

        let content = UNMutableNotificationContent()
        content.title = "\(total) \(plural(total, "новое письмо", "новых письма", "новых писем"))"
        content.body = rest > 0 ? "От \(shown) и ещё \(rest)" : "От \(shown)"
        content.sound = .default
        content.threadIdentifier = NotificationIDs.summaryThread
        content.categoryIdentifier = NotificationIDs.summaryCategory
        if let latestThread = threads.first?.first?.threadID {
            content.userInfo = ["threadID": latestThread]
        }
        let request = UNNotificationRequest(identifier: NotificationIDs.summaryThread, content: content, trigger: nil)
        center.add(request) { error in
            if let error { NSLog("UniMail: сводка не показана: %@", error.localizedDescription) }
        }
    }

    /// Убирает из Центра уведомлений баннеры тредов, которые уже прочитаны или убраны.
    func clearDelivered(threadIDs: Set<String>) {
        guard !threadIDs.isEmpty, let center else { return }
        let identifiers = threadIDs.map { "thread-\($0)" }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func clearAllDelivered() {
        center?.removeAllDeliveredNotifications()
    }

    // MARK: UNUserNotificationCenterDelegate

    private enum Presentation: Sendable { case hidden, quiet, full }

    private func presentation(forThread threadID: String) -> Presentation {
        if NSApp.isActive, isThreadVisible?(threadID) == true { return .hidden }
        return NSApp.isActive ? .quiet : .full
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let threadID = notification.request.content.threadIdentifier
        let mode: Presentation
        if Thread.isMainThread {
            mode = MainActor.assumeIsolated { NotificationService.shared.presentation(forThread: threadID) }
        } else {
            mode = .full
        }
        switch mode {
        case .hidden: completionHandler([])
        case .quiet: completionHandler([.banner, .list])
        case .full: completionHandler([.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let threadID = (content.userInfo["threadID"] as? String) ?? content.threadIdentifier
        let action: NotificationAction?
        switch response.actionIdentifier {
        case NotificationIDs.archiveAction:
            action = .archive(threadID: threadID)
        case NotificationIDs.readAction:
            action = .markRead(threadID: threadID)
        case NotificationIDs.replyAction:
            let text = (response as? UNTextInputNotificationResponse)?.userText
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            action = text.isEmpty ? .open(threadID: threadID) : .reply(threadID: threadID, text: text)
        case UNNotificationDefaultActionIdentifier:
            action = .open(threadID: threadID)
        default:
            action = nil
        }
        if let action, !threadID.isEmpty, threadID != NotificationIDs.summaryThread {
            Task { @MainActor in
                NotificationService.shared.actionHandler?(action)
            }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }
}
