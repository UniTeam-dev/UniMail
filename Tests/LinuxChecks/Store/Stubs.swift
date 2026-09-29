import Foundation

// Заглушки macOS-частей (SwiftUI, Связка ключей, EventKit) для проверки MailStore на Linux.

struct Animation {}

@MainActor
func withAnimation<R>(_ animation: Animation? = nil, _ body: () throws -> R) rethrows -> R { try body() }

enum Motion {
    static var list: Animation? { nil }
    static var snappy: Animation? { nil }
    static var bouncy: Animation? { nil }
    static var smooth: Animation? { nil }
}

enum Keychain {
    nonisolated(unsafe) static var items: [String: String] = [:]
    static func set(_ secret: String, for key: String) throws { items[key] = secret }
    static func get(_ key: String) -> String? { items[key] }
    static func remove(_ key: String) { items[key] = nil }
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()
    var added: [Invite] = []
    func addEvent(from invite: Invite, notes: String? = nil) async -> Bool {
        added.append(invite)
        return true
    }
}
