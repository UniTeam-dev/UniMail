import Foundation

/// Значение, по которому открывается окно написания письма.
struct ComposeRequest: Codable, Hashable, Identifiable {
    enum Mode: String, Codable { case new, reply, replyAll, forward, draft }

    var id: UUID = UUID()
    var mode: Mode
    var draft: OutgoingMessage

    var windowTitle: String {
        switch mode {
        case .new, .draft: draft.subject.isEmpty ? "Новое письмо" : draft.subject
        case .reply, .replyAll: "Ответ: \(draft.subject)"
        case .forward: "Пересылка: \(draft.subject)"
        }
    }
}

extension ComposeRequest {
    static func quote(_ message: Message) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let quoted = message.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\n\n\(formatter.string(from: message.date)), \(message.from.full) пишет:\n\(quoted)"
    }

    static func prefixed(_ prefix: String, _ subject: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }
}
