import SwiftUI

/// Настройки → «Шаблоны»: быстрые ответы. Слева список, справа редактор.
/// Данные — `AutomationStore.shared`, каждое изменение сохраняется.
@MainActor
struct TemplatesSettingsTab: View {
    @State private var selection: UUID?

    private var automation: AutomationStore { AutomationStore.shared }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        if automation.templates.isEmpty {
                            Text("Шаблонов нет")
                                .foregroundStyle(UM.fg3)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        ForEach(automation.templates) { template in
                            templateRow(template)
                        }
                    }
                    .padding(4)
                }
                HStack(spacing: 0) {
                    Button {
                        let created = automation.addTemplate()
                        selection = created.id
                    } label: {
                        Image(systemName: "plus").frame(width: 28, height: 28)
                    }
                    .help("Новый шаблон")
                    Rectangle().fill(UM.sep).frame(width: 0.5)
                    Button {
                        deleteSelected()
                    } label: {
                        Image(systemName: "minus").frame(width: 28, height: 28)
                    }
                    .disabled(selection == nil)
                    .help("Удалить шаблон")
                    Rectangle().fill(UM.sep).frame(width: 0.5)
                    Spacer()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(UM.fg2)
                .frame(height: 28)
                .hairline(.top)
            }
            .frame(width: 210)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let id = selection, let template = binding(for: id) {
                form(template)
            } else {
                Text(automation.templates.isEmpty ? "Нажмите «+», чтобы добавить шаблон" : "Выберите шаблон слева")
                    .foregroundStyle(UM.fg3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .onAppear { selection = selection ?? automation.templates.first?.id }
    }

    // MARK: Список

    private func templateRow(_ template: MailTemplate) -> some View {
        let on = template.id == selection
        return Button { selection = template.id } label: {
            HStack(spacing: 9) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .opacity(on ? 1 : 0.6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(template.name.isEmpty ? "Без названия" : template.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(preview(template))
                        .font(.system(size: 11))
                        .opacity(on ? 0.8 : 0.5)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? Color.white : UM.fg)
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? UM.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Удалить", role: .destructive) { delete(template.id) }
        }
    }

    private func preview(_ template: MailTemplate) -> String {
        let text = template.body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Пустой текст" : text
    }

    // MARK: Редактор

    private func form(_ template: Binding<MailTemplate>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                label("Название")
                TextField("", text: template.name)
                    .templatesFieldStyle()
            }
            GridRow {
                label("Тема")
                TextField("Необязательно", text: template.subject)
                    .templatesFieldStyle()
            }
            GridRow(alignment: .top) {
                label("Текст").padding(.top, 8)
                TextEditor(text: template.body)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.card))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text("Шаблоны вставляются в окне письма и в быстром ответе. Пустая тема не меняет тему ответа.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Привязка к шаблону по id (а не по индексу): удаление не ломает открытый редактор.
    private func binding(for id: UUID) -> Binding<MailTemplate>? {
        guard let current = automation.templates.first(where: { $0.id == id }) else { return nil }
        let store = automation
        return Binding(
            get: { store.templates.first { $0.id == id } ?? current },
            set: { value in
                guard let index = store.templates.firstIndex(where: { $0.id == id }),
                      store.templates[index] != value else { return }
                store.templates[index] = value
                store.save()
            }
        )
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        delete(id)
    }

    private func delete(_ id: UUID) {
        let index = automation.templates.firstIndex { $0.id == id }
        if selection == id { selection = nil }
        automation.deleteTemplate(id)
        if selection == nil, let index, !automation.templates.isEmpty {
            selection = automation.templates[min(index, automation.templates.count - 1)].id
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(UM.fg2)
            .frame(width: 70, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

private extension View {
    func templatesFieldStyle() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.card))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
    }
}
