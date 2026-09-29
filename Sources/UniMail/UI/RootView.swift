import SwiftUI

@MainActor
struct RootView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 272, max: 340)
        } content: {
            MessageListView()
                .navigationSplitViewColumnWidth(min: 330, ideal: 390, max: 560)
        } detail: {
            ThreadDetailView()
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Поиск  ·  from: subject: has:attachment")
        .overlay(alignment: .bottom) {
            UndoToast()
                .padding(.bottom, 18)
        }
        .overlay {
            if store.isPalettePresented {
                CommandPalette()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
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
