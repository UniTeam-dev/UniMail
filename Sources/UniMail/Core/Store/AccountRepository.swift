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

    /// При первом запуске — три демо-аккаунта, чтобы было на что посмотреть.
    /// Почта подобрана так, чтобы DemoProvider выдал три разных набора писем.
    static var defaultDemoAccounts: [Account] {
        [
            Account(displayName: "Работа", email: "il1ja@company.ru", kind: .demo, tint: .blue),
            Account(displayName: "Личная", email: "il1ja.home@gmail.com", kind: .demo, tint: .orange),
            Account(displayName: "iCloud", email: "il1ja@icloud.com", kind: .demo, tint: .purple),
        ]
    }
}
