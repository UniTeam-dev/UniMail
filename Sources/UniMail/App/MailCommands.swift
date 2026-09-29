import SwiftUI

/// Меню приложения и шорткаты. ⌘1 — «Все ящики», ⌘2…⌘9 — ящики по порядку (как в макете).
@MainActor
struct MailCommands: Commands {
    let store: MailStore

    private var selection: [String] { store.selectedThreadID.map { [$0] } ?? [] }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новое письмо") { store.compose() }
                .keyboardShortcut("n")
        }

        CommandMenu("Письмо") {
            Button("Ответить") { store.replyToSelected() }
                .keyboardShortcut("r")
            Button("Ответить всем") { store.replyToSelected(all: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Переслать") { store.forwardSelected() }
                .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Group {
                Button("В архив") { store.archive(threadIDs: selection) }
                    .keyboardShortcut("a", modifiers: [.command, .control])
                Button("Удалить") { store.trash(threadIDs: selection) }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Прочитано / не прочитано") { store.toggleRead(threadIDs: selection) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Отметить флажком") { store.toggleFlag(threadIDs: selection) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Это спам") { store.markSpam(threadIDs: selection) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }

            Menu("Отложить") {
                ForEach(TimePreset.allCases) { preset in
                    Button("\(preset.title) — \(preset.subtitle)") {
                        store.snooze(threadIDs: selection, until: preset.date, label: preset.title)
                    }
                }
            }

            Divider()

            Button("Проверить почту") { Task { await store.refreshAll() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Перейти") {
            Button("Почта") { withAnimation(Motion.smooth) { store.mode = .mail } }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Button("Расписание") { withAnimation(Motion.smooth) { store.mode = .schedule } }
                .keyboardShortcut("2", modifiers: [.command, .shift])

            Divider()

            Button("Все ящики") { store.switchTo(index: 1) }
                .keyboardShortcut("1")
            ForEach(Array(store.accounts.prefix(8).enumerated()), id: \.element.id) { index, account in
                Button(account.displayName) { store.switchTo(index: index + 2) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")))
            }
            Button("Следующий ящик") { store.switchToNextAccount() }
                .keyboardShortcut(.tab, modifiers: .control)

            Divider()

            ForEach(Array(MailboxRole.allCases.enumerated()), id: \.element) { index, role in
                Button(role.title) { store.select(scope: store.scope.with(role: role)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }

            Divider()

            Button("Командная палитра…") { store.isPalettePresented.toggle() }
                .keyboardShortcut("k")
        }

        CommandGroup(after: .toolbar) {
            Button("Сменить тему") { AppearanceMode.cycle() }
                .keyboardShortcut("l", modifiers: [.command, .shift, .option])
        }
    }
}

extension AppearanceMode {
    /// Светлая → Тёмная → Как в системе.
    @MainActor
    static func cycle() {
        let current = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .auto
        let next: AppearanceMode
        switch current {
        case .light: next = .dark
        case .dark: next = .auto
        case .auto: next = .light
        }
        UserDefaults.standard.set(next.rawValue, forKey: "appearance")
        next.apply()
    }
}
