import Foundation

/// Определение системных ролей папок: сначала атрибуты SPECIAL-USE (RFC 6154) и XLIST,
/// затем — эвристики по именам для серверов без SPECIAL-USE (Exchange on‑prem, старые Courier/Dovecot,
/// русские провайдеры, локализованный Gmail).
enum IMAPFolderRoles {
    /// Роль по атрибутам LIST.
    static func role(forAttributes attributes: Set<String>) -> MailboxRole? {
        let lower = Set(attributes.map { $0.lowercased() })
        if lower.contains("\\inbox") { return .inbox }          // XLIST
        if lower.contains("\\sent") { return .sent }
        if lower.contains("\\drafts") { return .drafts }
        if lower.contains("\\trash") { return .trash }
        if lower.contains("\\junk") || lower.contains("\\spam") { return .spam }
        if lower.contains("\\archive") { return .archive }
        if lower.contains("\\all") || lower.contains("\\allmail") { return .archive }
        if lower.contains("\\flagged") || lower.contains("\\starred") { return .flagged }
        return nil
    }

    /// Имена (в нижнем регистре, последний компонент пути) → роль.
    static let nameTable: [String: MailboxRole] = {
        var t: [String: MailboxRole] = [:]
        for n in ["sent", "sent items", "sent messages", "sent mail", "sent-mail", "sent e-mail",
                  "отправленные", "отправленные письма", "gesendet", "gesendete elemente", "envoyés", "enviados"] {
            t[n] = .sent
        }
        for n in ["drafts", "draft", "черновики", "entwürfe", "brouillons", "borradores"] { t[n] = .drafts }
        for n in ["trash", "deleted items", "deleted messages", "deleted", "bin", "корзина", "удаленные", "удалённые",
                  "удаленные письма", "удалённые письма", "папка удаленные", "gelöschte elemente", "papierkorb", "corbeille", "papelera"] {
            t[n] = .trash
        }
        for n in ["junk", "spam", "junk e-mail", "junk email", "junk mail", "bulk mail", "спам", "нежелательная почта",
                  "junk-e-mail", "courrier indésirable"] {
            t[n] = .spam
        }
        for n in ["archive", "archives", "архив", "all mail", "вся почта", "alle nachrichten", "archiv"] { t[n] = .archive }
        for n in ["starred", "flagged", "помеченные", "избранные", "отмеченные", "markiert"] { t[n] = .flagged }
        return t
    }()

    /// Роль по имени папки. `delimiter` нужен, чтобы брать последний компонент.
    /// Учитываются только папки верхнего уровня, дети INBOX (Courier: `INBOX.Sent`) и `[Gmail]/…` / `[Google Mail]/…`.
    /// Возвращает роль и «приоритет» (меньше — лучше) для выбора между несколькими кандидатами.
    static func role(forName name: String, delimiter: String?) -> (MailboxRole, Int)? {
        if name.uppercased() == "INBOX" { return (.inbox, 0) }
        var components = [name]
        if let d = delimiter, !d.isEmpty { components = name.components(separatedBy: d) }
        guard let last = components.last?.trimmingCharacters(in: .whitespaces).lowercased(), !last.isEmpty else { return nil }
        let priority: Int
        switch components.count {
        case 1: priority = 1
        case 2:
            let parent = components[0].lowercased()
            if parent == "[gmail]" || parent == "[google mail]" { priority = 0 }
            else if parent == "inbox" { priority = 2 }
            else { return nil }
        default: return nil
        }
        guard let role = nameTable[last] else { return nil }
        return (role, priority)
    }

    /// Проставляет роли списку папок. Атрибуты имеют приоритет; эвристика имени назначает роль
    /// только если ни одна папка не получила её по атрибутам, и только одной папке (лучшей по приоритету).
    static func assignRoles(_ folders: inout [IMAPFolder]) {
        var claimed = Set<MailboxRole>()
        for i in folders.indices {
            if folders[i].name.uppercased() == "INBOX" {
                folders[i].role = .inbox
                claimed.insert(.inbox)
                continue
            }
            if let r = role(forAttributes: folders[i].attributes) {
                // \All и \Archive одновременно: \Archive — сам архив, \All («Вся почта») — только если архива нет.
                folders[i].role = r
            }
        }
        // Если есть и \Archive, и \All — роль архива оставляем папке с \Archive.
        let archiveByAttr = folders.indices.filter { folders[$0].attributes.contains { $0.lowercased() == "\\archive" } }
        if !archiveByAttr.isEmpty {
            for i in folders.indices where folders[i].role == .archive && !archiveByAttr.contains(i) {
                folders[i].role = nil
            }
        }
        for f in folders { if let r = f.role { claimed.insert(r) } }

        var best: [MailboxRole: (index: Int, priority: Int)] = [:]
        for i in folders.indices where folders[i].role == nil && folders[i].isSelectable {
            guard let (r, p) = role(forName: folders[i].name, delimiter: folders[i].delimiter), !claimed.contains(r) else { continue }
            if let current = best[r], current.priority <= p { continue }
            best[r] = (i, p)
        }
        for (r, v) in best { folders[v.index].role = r }
    }
}
