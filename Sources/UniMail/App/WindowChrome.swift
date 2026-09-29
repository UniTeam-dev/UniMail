import AppKit
import SwiftUI

/// Настраивает окно под макет: заголовок скрыт, контент под заголовком,
/// «светофор» по центру собственной шапки высотой `headerHeight` и с отступом `leading`.
struct WindowChrome: NSViewRepresentable {
    var leading: CGFloat = 20
    var headerHeight: CGFloat = 52

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.leading = leading
        view.headerHeight = headerHeight
        return view
    }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.leading = leading
        view.headerHeight = headerHeight
        view.layoutTrafficLights()
    }

    final class ChromeView: NSView {
        var leading: CGFloat = 20
        var headerHeight: CGFloat = 52
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard let window else { return }
            // Наблюдатели снимаются здесь же при уходе из окна (window == nil).

            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutTrafficLights() }
                })
            }
            Task { @MainActor [weak self] in self?.layoutTrafficLights() }
        }

        /// Сдвигаем контейнер заголовка вниз, чтобы кнопки оказались по центру шапки,
        /// и расставляем их с шагом 20 pt от `leading`.
        func layoutTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview,
                  let container = titlebar.superview else { return }

            let barHeight = titlebar.frame.height
            var frame = container.frame
            frame.origin.y = window.frame.height - barHeight - (headerHeight - barHeight) / 2
            container.frame = frame

            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, type) in buttons.enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                let y = (barHeight - button.frame.height) / 2
                button.setFrameOrigin(NSPoint(x: leading + CGFloat(index) * 20, y: y))
            }
        }
    }
}
