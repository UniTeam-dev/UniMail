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
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1320, height: 820)
        .commands { MailCommands(store: store) }

        WindowGroup("Новое письмо", id: "compose", for: ComposeRequest.self) { $request in
            if let request = request {
                ComposeView(request: request)
                    .environment(store)
            }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 720, height: 640)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Почтовый клиент живёт в Dock и после закрытия окна — как Mail.app.
        false
    }
}
