import AppKit
import SwiftUI

/// Показ главного окна из мест, где нет SwiftUI-окружения (уведомления, строка меню, Dock).
///
/// `OpenWindowAction` запоминается из любой вью (см. `OpenWindowCapture`), чтобы можно было
/// заново создать главное окно, если пользователь его закрыл.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    /// Последний `openWindow` из SwiftUI-окружения.
    var openWindow: OpenWindowAction?

    private init() {}

    /// Главное окно, если оно есть на экране или свёрнуто в Dock.
    /// SwiftUI называет окна WindowGroup как «<id>-AppWindow-<n>».
    var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            (window.identifier?.rawValue.hasPrefix("main") ?? false)
                && (window.isVisible || window.isMiniaturized)
        }
    }

    /// Выводит приложение на передний план и показывает главное окно (создаёт, если его нет).
    func showMain(using action: OpenWindowAction? = nil) {
        if let action { openWindow = action }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            openWindow(id: "main")
        }
    }

    /// Прячет приложение целиком (старт «без окна» при входе в систему).
    /// Окно при этом не закрывается: клик по иконке в Dock или «Открыть UniMail» вернёт его.
    func hideForBackgroundLaunch() {
        NSApp.hide(nil)
        // Окна SwiftUI могут появиться на следующем витке цикла — прячем ещё раз.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { NSApp.hide(nil) }
        }
    }
}
