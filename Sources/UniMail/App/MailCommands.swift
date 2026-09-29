import SwiftUI

/// Меню приложения и шорткаты.
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

            Menu("Отложить") {
                ForEach(TimePreset.allCases) { preset in
                    Button(preset.title) { store.snooze(threadIDs: selection, until: preset.date) }
                }
            }

            Divider()

            Button("Проверить почту") { Task { await store.refreshAll() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Перейти") {
            Button("Все ящики") { store.switchTo(index: 0) }
                .keyboardShortcut("0")
            ForEach(Array(store.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button(account.displayName) { store.switchTo(index: index + 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Button("Следующий ящик") { store.switchToNextAccount() }
                .keyboardShortcut(.tab, modifiers: .control)

            Divider()

            ForEach(Array(MailboxRole.allCases.enumerated()), id: \.element) { index, role in
                if index < 9 {
                    Button(role.title) { store.select(scope: store.scope.with(role: role)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                } else {
                    Button(role.title) { store.select(scope: store.scope.with(role: role)) }
                }
            }

            Divider()

            Button("Командная палитра…") {
                withAnimation(Motion.bouncy) { store.isPalettePresented.toggle() }
            }
            .keyboardShortcut("k")
        }
    }
}
