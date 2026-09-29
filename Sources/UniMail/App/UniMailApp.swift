import AppKit
import SwiftUI

@main
struct UniMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: MailStore
    @AppStorage(AppSettings.showMenuBarExtra) private var showMenuBarExtra = true

    init() {
        AppSettings.registerDefaults()
        let store = MailStore()
        _store = State(initialValue: store)
        // Бейдж Dock, уведомления о новых письмах и действия из них (см. Core/Services/AppServices.swift).
        AppServices.shared.attach(store)
    }

    var body: some Scene {
        WindowGroup("UniMail", id: "main") {
            RootView()
                .environment(store)
                .tint(UM.accent)
                .frame(minWidth: 1000, minHeight: 620)
                .background(WindowChrome(leading: 20, headerHeight: 52))
                .background(OpenWindowCapture())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1320, height: 820)
        .commands { MailCommands(store: store) }

        WindowGroup("Новое письмо", id: "compose", for: ComposeRequest.self) { $request in
            if let request = request {
                ComposeView(request: request)
                    .environment(store)
                    .tint(UM.accent)
                    .frame(minWidth: 600, minHeight: 480)
                    .background(WindowChrome(leading: 16, headerHeight: 44))
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 640)

        Settings {
            SettingsView()
                .environment(store)
                .tint(UM.accent)
        }

        // Иконка в строке меню: непрочитанные и быстрые действия. Включается в Настройках → Уведомления.
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarPanel()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Делегат уведомлений назначается до конца запуска, чтобы не потерять клик, которым нас запустили.
        AppServices.shared.applicationWillFinishLaunching()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .auto
        mode.apply()
        // Запуск при входе в систему с «Запускать без окна»: приложение скрыто, почта проверяется в фоне.
        let startHidden = AppServices.shared.applicationDidFinishLaunching()
        if !startHidden {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Несохранённые изменения писем — в базу до выхода.
        MainActor.assumeIsolated {
            AppServices.shared.store?.flushPersistence(wait: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Почтовый клиент живёт в Dock и после закрытия окна — как Mail.app.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Клик по иконке в Dock, когда окно свёрнуто, — разворачиваем его, а не создаём второе.
        if !flag, let window = WindowRouter.shared.mainWindow, window.isMiniaturized {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return false
        }
        // Иначе SwiftUI сам откроет главное окно, если его нет.
        return true
    }
}
