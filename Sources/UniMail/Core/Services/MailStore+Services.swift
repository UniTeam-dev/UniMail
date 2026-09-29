import Foundation
import SwiftUI

/// Непрочитанный тред для строки меню.
struct UnreadThreadItem: Identifiable, Hashable {
    var id: String { latest.threadID }
    var latest: Message
    var unreadCount: Int
}

/// Операции, которые нужны системным сервисам (уведомления, строка меню, Dock).
/// Построены только на публичном API `MailStore` и не зависят от того, что сейчас открыто в списке.
@MainActor
extension MailStore {
    /// Все непрочитанные во «Входящих» по всем ящикам (для бейджа Dock и строки меню).
    var totalInboxUnread: Int {
        messages.values.reduce(0) { $0 + ($1.role == .inbox && !$1.isRead ? 1 : 0) }
    }

    /// Последние непрочитанные треды во «Входящих», новые сверху.
    func latestUnreadThreads(limit: Int = 8) -> [UnreadThreadItem] {
        let unread = messages.values.filter { $0.role == .inbox && !$0.isRead }
        let grouped = Dictionary(grouping: unread, by: \.threadID)
        return grouped.values
            .compactMap { items -> UnreadThreadItem? in
                guard let latest = items.max(by: { $0.date < $1.date }) else { return nil }
                return UnreadThreadItem(latest: latest, unreadCount: items.count)
            }
            .sorted { $0.latest.date > $1.latest.date }
            .prefix(limit)
            .map { $0 }
    }

    /// Самое свежее письмо треда. По умолчанию предпочитает «Входящие»
    /// (последним в треде может быть ваш же ответ из «Отправленных»).
    func latestMessage(inThread threadID: String, preferInbox: Bool = true) -> Message? {
        let items = messages.values.filter { $0.threadID == threadID }
        if preferInbox, let inbox = items.filter({ $0.role == .inbox }).max(by: { $0.date < $1.date }) {
            return inbox
        }
        return items.max(by: { $0.date < $1.date })
    }

    private func isVisibleInCurrentList(_ threadID: String) -> Bool {
        visibleMessages(in: scope).contains { $0.threadID == threadID }
    }

    /// Показывает тред в главном окне: режим «Почта», подходящая папка, выделение, «прочитано».
    /// Текущая папка не меняется, если тред в ней уже виден.
    func reveal(threadID: String) {
        guard let latest = latestMessage(inThread: threadID) else { return }
        withAnimation(Motion.snappy) {
            if mode != .mail { mode = .mail }
            if !isVisibleInCurrentList(threadID) {
                searchText = ""
                quickFilter = .all
                categoryFilter = nil
                let role: MailboxRole = latest.role
                scope = hiddenAccountIDs.contains(latest.accountID) || scope.accountID == latest.accountID
                    ? .account(latest.accountID, role)
                    : .unified(role)
            }
            selectedThreadID = threadID
        }
        openThread(threadID)
    }

    /// Архивирует тред, даже если он не виден в текущем списке (действие из уведомления).
    /// `archive(threadIDs:)` работает по видимому списку, поэтому на время вызова
    /// подставляем папку треда и возвращаем всё как было.
    func archiveAnywhere(threadID: String) {
        if isVisibleInCurrentList(threadID) {
            archive(threadIDs: [threadID])
            return
        }
        guard let latest = latestMessage(inThread: threadID) else { return }
        let saved = (scope: scope, search: searchText, quick: quickFilter, category: categoryFilter, selected: selectedThreadID)
        scope = .account(latest.accountID, latest.role)
        searchText = ""
        quickFilter = .all
        categoryFilter = nil
        archive(threadIDs: [threadID])
        scope = saved.scope
        searchText = saved.search
        quickFilter = saved.quick
        categoryFilter = saved.category
        selectedThreadID = saved.selected == threadID ? nil : saved.selected
    }

    /// Отмечает тред прочитанным (действие «Прочитано»). Не зависит от текущей папки.
    func markThreadRead(threadID: String) {
        openThread(threadID)
    }

    /// Быстрый ответ из уведомления: ответ отправителю последнего письма треда
    /// с подписью и цитатой — как `compose(.reply)`, но без окна. Идёт через обычное
    /// «Отменить отправку».
    @discardableResult
    func sendQuickReply(threadID: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let source = thread(threadID).last ?? latestMessage(inThread: threadID),
              let account = self.account(source.accountID) else { return false }

        var body = trimmed
        let signature = account.signatureText(for: .reply)
        if !signature.isEmpty { body += "\n\n--\n\(signature)" }
        body += ComposeRequest.quote(source)

        var draft = OutgoingMessage(
            accountID: account.id,
            fromAddress: account.email,
            to: [source.role == .sent ? (source.to.first ?? source.from) : source.from],
            cc: [],
            bcc: [],
            subject: ComposeRequest.prefixed("Re:", source.subject),
            body: body
        )
        draft.threadID = source.threadID
        draft.inReplyTo = source.id
        send(draft, requestID: UUID(), undoTitle: "Ответ отправляется…")
        openThread(threadID)
        return true
    }

    /// Открывает окно написания с готовым текстом ответа (черновик от AI).
    func composeReply(threadID: String, prefilledText: String) {
        guard let last = thread(threadID).last ?? latestMessage(inThread: threadID) else { return }
        compose(.reply, from: last.id)
        guard !composeQueue.isEmpty else { return }
        let index = composeQueue.count - 1
        composeQueue[index].draft.body = prefilledText + composeQueue[index].draft.body
    }
}
