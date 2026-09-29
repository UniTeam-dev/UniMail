import AppKit
import SwiftUI

@main
struct UniMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MailStore()

    var body: some Scene {
        WindowGroup("UniMail", id: "main") {
            RootView()
                .environment(store)
                .tint(UM.accent)
                .frame(minWidth: 1000, minHeight: 620)
                .background(WindowChrome(leading: 20, headerHeight: 52))
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .auto
        mode.apply()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Почтовый клиент живёт в Dock и после закрытия окна — как Mail.app.
        false
    }
}
