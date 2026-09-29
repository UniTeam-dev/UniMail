import Foundation

/// Список аккаунтов в ~/Library/Application Support/UniMail/accounts.json.
/// Секреты туда не попадают — они в Keychain.
enum AccountRepository {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("UniMail", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("accounts.json") }

    static func load() -> [Account] {
        guard let data = try? Data(contentsOf: file),
              let accounts = try? JSONDecoder().decode([Account].self, from: data) else {
            return defaultDemoAccounts
        }
        // Старые демо-ящики первой сборки заменяем на ящики из макета.
        let legacy: Set<String> = ["il1ja@company.ru", "il1ja.home@gmail.com", "il1ja@icloud.com"]
        if !accounts.isEmpty && accounts.allSatisfy({ $0.kind == .demo && legacy.contains($0.email) }) {
            return defaultDemoAccounts
        }
        return accounts
    }

    static func save(_ accounts: [Account]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(accounts).write(to: file, options: .atomic)
        } catch {
            NSLog("UniMail: не удалось сохранить аккаунты: \(error)")
        }
    }

    /// При первом запуске — три демо-ящика из макета, чтобы было на что посмотреть.
    static var defaultDemoAccounts: [Account] {
        [
            Account(displayName: "Работа", email: "a.volkova@severlab.ru", kind: .demo, tint: .blue,
                    signature: "Анна Волкова\nВедущий дизайнер · Северлаб", aliases: ["design@severlab.ru"],
                    senderName: "Анна Волкова", providerLabel: "Google Workspace"),
            Account(displayName: "Личное", email: "anna.volkova@icloud.com", kind: .demo, tint: .orange,
                    signature: "Аня", senderName: "Анна Волкова", providerLabel: "iCloud"),
            Account(displayName: "Студия", email: "hello@volkova.studio", kind: .demo, tint: .purple,
                    signature: "Volkova Studio — интерфейсы и шрифт", senderName: "Анна Волкова",
                    providerLabel: "IMAP · Fastmail"),
        ]
    }
}
