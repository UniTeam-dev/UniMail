import SwiftUI

extension RichTextSize {
    var title: String {
        switch self {
        case .small: return "Мелкий текст"
        case .normal: return "Обычный текст"
        case .large: return "Крупный текст"
        }
    }

    /// Кегль буквы «A» на кнопке размера.
    var sampleSize: CGFloat {
        switch self {
        case .small: return 10.5
        case .normal: return 13
        case .large: return 16
        }
    }
}

/// Панель форматирования под полями письма: показывается кнопкой «textformat» в шапке.
@MainActor
struct FormatBar: View {
    let controller: RichTextController

    @State private var linkOpen = false
    @State private var linkText = ""

    var body: some View {
        HStack(spacing: 2) {
            toggle("bold", help: "Жирный · ⌘B", on: controller.isBold) { controller.toggleBold() }
            toggle("italic", help: "Курсив · ⌘I", on: controller.isItalic) { controller.toggleItalic() }
            toggle("underline", help: "Подчёркнутый · ⌘U", on: controller.isUnderline) { controller.toggleUnderline() }
            toggle("strikethrough", help: "Зачёркнутый", on: controller.isStrikethrough) { controller.toggleStrikethrough() }

            separator

            toggle("list.bullet", help: "Маркированный список", on: controller.list == .bullet) { controller.toggleList(.bullet) }
            toggle("list.number", help: "Нумерованный список", on: controller.list == .ordered) { controller.toggleList(.ordered) }
            toggle("text.quote", help: "Цитата", on: controller.isQuote) { controller.toggleQuote() }

            separator

            toggle("link", help: "Ссылка", on: controller.hasLink || linkOpen) {
                linkText = controller.beginLinkEditing()
                linkOpen = true
            }
            .popover(isPresented: $linkOpen, arrowEdge: .bottom) {
                LinkPopover(
                    text: $linkText,
                    canRemove: controller.hasLink,
                    apply: {
                        controller.applyLink(linkText)
                        linkOpen = false
                    },
                    remove: {
                        controller.removeLink()
                        linkOpen = false
                    }
                )
            }

            separator

            ForEach(RichTextSize.allCases, id: \.self) { size in
                let on = controller.size == size
                Button { controller.setSize(size) } label: {
                    Text("A").font(.system(size: size.sampleSize, weight: .semibold))
                }
                .buttonStyle(ToolbarIconStyle(width: 26, height: 26, radius: 6, tint: on ? UM.accent : nil, active: on))
                .help(size.title)
            }

            separator

            toggle("eraser", help: "Очистить форматирование", on: false) { controller.clearFormatting() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
        .background(UM.win)
        .hairline(.bottom)
    }

    private var separator: some View {
        Rectangle()
            .fill(UM.sepStrong)
            .frame(width: 0.5, height: 16)
            .padding(.horizontal, 5)
    }

    private func toggle(_ symbol: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(ToolbarIconStyle(width: 28, height: 26, radius: 6, tint: on ? UM.accent : nil, active: on))
        .help(help)
    }
}

/// Поповер ввода адреса ссылки.
@MainActor
private struct LinkPopover: View {
    @Binding var text: String
    let canRemove: Bool
    let apply: () -> Void
    let remove: () -> Void

    @FocusState private var focused: Bool

    init(text: Binding<String>, canRemove: Bool, apply: @escaping () -> Void, remove: @escaping () -> Void) {
        _text = text
        self.canRemove = canRemove
        self.apply = apply
        self.remove = remove
    }

    private var isValid: Bool { RichText.sanitizeLink(text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ссылка")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UM.fg2)
            TextField("", text: $text, prompt: Text("https://…").foregroundColor(UM.fg3))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.field))
                .focused($focused)
                .onSubmit { if isValid { apply() } }
            HStack(spacing: 8) {
                if canRemove {
                    Button("Убрать ссылку", action: remove)
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
                }
                Spacer(minLength: 0)
                Button("Готово", action: apply)
                    .buttonStyle(UMButtonStyle(kind: .primary, height: 26, radius: 7, horizontal: 12))
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.5)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { focused = true }
    }
}
