import SwiftUI

/// Капсула «Отменить»: выезжает снизу с лёгким масштабом (раскадровка 07).
@MainActor
struct UndoToast: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        ZStack {
            if let undo = store.undo {
                HStack(spacing: 10) {
                    Image(systemName: undo.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(UM.fg2)
                        .symbolEffect(.bounce, value: undo.id)
                    Text(undo.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Button("Отменить") { store.undoLast() }
                        .buttonStyle(ToastButtonStyle())
                        .keyboardShortcut("z", modifiers: .command)
                        .padding(.leading, 6)
                    Button { store.dismissUndo() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(ToolbarIconStyle(width: 30, height: 30, radius: 15, tint: UM.fg3))
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .frame(height: 44)
                .umMenuSurface(radius: 22)
                .fixedSize()
                .id(undo.id)
                .transition(Motion.reduce ? AnyTransition.opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 24)).combined(with: .scale(scale: 0.94)),
                    removal: .opacity.combined(with: .offset(y: 8))
                ))
            }
        }
        .animation(store.undo == nil ? Motion.toastOut : Motion.toastIn, value: store.undo)
    }
}

private struct ToastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UM.accent)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(hovering ? UM.accentSoft : .clear))
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .onHover { hovering = $0 }
        }
    }
}
