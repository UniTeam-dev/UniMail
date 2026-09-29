import SwiftUI

/// Плашка «Отменить» после архивации, удаления, отправки.
@MainActor
struct UndoToast: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        ZStack {
            if let undo = store.undo {
                HStack(spacing: 12) {
                    Image(systemName: undo.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: undo.id)
                    Text(undo.title)
                        .font(.callout.weight(.medium))
                    Divider().frame(height: 16)
                    Button("Отменить") { store.undoLast() }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .keyboardShortcut("z", modifiers: .command)
                    Button {
                        store.dismissUndo()
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                .id(undo.id)
                .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Motion.bouncy, value: store.undo)
    }
}
