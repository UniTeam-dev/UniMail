import SwiftUI

/// Главное окно: панель аккаунтов 66 + папки 210 + список 390 + чтение (как в макете).
/// Уже 1150 pt — папки 196 и список 316.
@MainActor
struct RootView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 1150
            HStack(spacing: 0) {
                SidebarColumn(foldersWidth: narrow ? 196 : 210)

                ZStack {
                    if store.mode == .mail {
                        HStack(spacing: 0) {
                            MessageListColumn(narrow: narrow)
                                .frame(width: narrow ? 316 : 390)
                            ReaderColumn(narrow: narrow)
                        }
                        .transition(.opacity)
                    } else {
                        ScheduleView()
                            .transition(.opacity)
                    }
                }
                .animation(Motion.smooth, value: store.mode)
            }
            .overlay {
                if store.isPalettePresented {
                    CommandPalette()
                        .zIndex(10)
                }
            }
        }
        .background(UM.win)
        .foregroundStyle(UM.fg)
        .font(.system(size: 13))
        .ignoresSafeArea()
        .onChange(of: store.composeQueue) { _, queue in
            guard !queue.isEmpty else { return }
            for request in queue {
                openWindow(id: "compose", value: request)
            }
            store.composeQueue.removeAll()
        }
        .task { store.start() }
    }
}
