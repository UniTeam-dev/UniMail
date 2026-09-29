import SwiftUI

/// Настройки → «Правила»: правила для входящих, срок напоминания follow-up
/// и выученные категории отправителей. Данные — `AutomationStore.shared`, каждое изменение сохраняется.
@MainActor
struct RulesSettingsTab: View {
    @Environment(MailStore.self) private var store
    @State private var editing: MailRule?

    private var automation: AutomationStore { AutomationStore.shared }

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 22) {
                GridRow(alignment: .top) {
                    label("Правила").padding(.top, 6)
                    VStack(alignment: .leading, spacing: 8) {
                        rulesCard
                        HStack(spacing: 10) {
                            Button {
                                editing = MailRule.blank()
                            } label: {
                                Label("Добавить правило", systemImage: "plus")
                            }
                            .buttonStyle(UMButtonStyle(kind: .secondary))
                            Text("Применяются к новым входящим сверху вниз.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(UM.fg3)
                        }
                    }
                }
                GridRow(alignment: .top) {
                    label("Напомнить об ответе").padding(.top, 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Stepper(value: followUpBinding, in: AutomationStore.followUpRange) {
                            Text("через \(automation.followUpDays) \(plural(automation.followUpDays, "день", "дня", "дней"))")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .fixedSize()
                        Text("Если на письмо с «Напомнить, если не ответят» никто не ответил.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(UM.fg3)
                    }
                }
                GridRow(alignment: .top) {
                    label("Выученные категории").padding(.top, 6)
                    VStack(alignment: .leading, spacing: 8) {
                        overridesCard
                        Text("Появляются, когда вы переносите отправителя в другую категорию. Два адреса одного домена — и правило действует на весь домен.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(UM.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(item: $editing) { rule in
            RuleEditorSheet(
                rule: rule,
                isNew: !automation.rules.contains { $0.id == rule.id },
                accounts: store.accounts,
                onSave: { saved in
                    automation.upsertRule(saved)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    // MARK: Правила

    private var rulesCard: some View {
        VStack(spacing: 0) {
            if automation.rules.isEmpty {
                Text("Правил пока нет")
                    .foregroundStyle(UM.fg3)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                ForEach(Array(automation.rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 {
                        Rectangle().fill(UM.sep).frame(height: 0.5).padding(.leading, 50)
                    }
                    ruleRow(rule, index: index)
                }
            }
        }
        .rulesCardStyle()
    }

    private func ruleRow(_ rule: MailRule, index: Int) -> some View {
        HStack(spacing: 10) {
            Button {
                automation.setRuleEnabled(rule.id, !rule.isEnabled)
            } label: {
                MiniSwitch(isOn: rule.isEnabled, width: 30, height: 18)
            }
            .buttonStyle(.plain)
            .help(rule.isEnabled ? "Выключить правило" : "Включить правило")

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Без названия" : rule.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(summary(of: rule))
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg3)
                    .lineLimit(2)
            }
            .opacity(rule.isEnabled ? 1 : 0.55)

            Spacer(minLength: 0)

            Button { editing = rule } label: {
                Image(systemName: "pencil").frame(width: 26, height: 24)
            }
            .buttonStyle(HoverStyle(radius: 6))
            .help("Изменить")
            Button { automation.deleteRule(rule.id) } label: {
                Image(systemName: "trash").frame(width: 26, height: 24)
            }
            .buttonStyle(HoverStyle(radius: 6))
            .help("Удалить")
        }
        .foregroundStyle(UM.fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Изменить…") { editing = rule }
            Button("Выше") { automation.moveRule(rule.id, by: -1) }
                .disabled(index == 0)
            Button("Ниже") { automation.moveRule(rule.id, by: 1) }
                .disabled(index >= automation.rules.count - 1)
            Divider()
            Button("Удалить", role: .destructive) { automation.deleteRule(rule.id) }
        }
    }

    /// «Работа · От содержит «github» → в «Архив»».
    private func summary(of rule: MailRule) -> String {
        guard let id = rule.accountID else { return rule.summary }
        let name = store.accounts.first { $0.id == id }?.displayName ?? "Удалённый ящик"
        return "\(name) · \(rule.summary)"
    }

    private var followUpBinding: Binding<Int> {
        Binding(
            get: { automation.followUpDays },
            set: { value in
                automation.followUpDays = AutomationStore.clampDays(value)
                automation.save()
            }
        )
    }

    // MARK: Категории

    private var overridesCard: some View {
        VStack(spacing: 0) {
            if automation.categoryOverrides.isEmpty {
                Text("Пока ничего не выучено")
                    .foregroundStyle(UM.fg3)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                ForEach(Array(automation.categoryOverrides.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Rectangle().fill(UM.sep).frame(height: 0.5).padding(.leading, 36)
                    }
                    overrideRow(item)
                }
            }
        }
        .rulesCardStyle()
    }

    private func overrideRow(_ item: CategoryOverride) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDomain ? "globe" : "person.crop.circle")
                .font(.system(size: 13))
                .foregroundStyle(UM.fg2)
                .frame(width: 16)
            Text(item.displayKey)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.category.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(UM.fg2)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(UM.field))
            Button { automation.removeOverride(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(UM.fg3)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Забыть")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minHeight: 34)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(UM.fg2)
            .multilineTextAlignment(.trailing)
            .frame(width: 130, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

// MARK: - Редактор правила

/// Строка условия с собственной идентичностью, чтобы удаление не путало привязки.
private struct RuleConditionDraft: Identifiable {
    let id = UUID()
    var condition: MailRule.Condition
}

private struct RuleActionDraft: Identifiable {
    let id = UUID()
    var action: MailRule.Action
}

@MainActor
private struct RuleEditorSheet: View {
    let isNew: Bool
    let accounts: [Account]
    let onSave: (MailRule) -> Void
    let onCancel: () -> Void

    @State private var draft: MailRule
    @State private var conditions: [RuleConditionDraft]
    @State private var actions: [RuleActionDraft]

    init(rule: MailRule, isNew: Bool, accounts: [Account],
         onSave: @escaping (MailRule) -> Void, onCancel: @escaping () -> Void) {
        self.isNew = isNew
        self.accounts = accounts
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: rule)
        let conds = rule.conditions.isEmpty ? [MailRule.Condition(field: .from, match: .contains, value: "")] : rule.conditions
        _conditions = State(initialValue: conds.map { RuleConditionDraft(condition: $0) })
        _actions = State(initialValue: rule.actions.map { RuleActionDraft(action: $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Новое правило" : "Правило")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                    GridRow {
                        label("Название")
                        TextField("Например, «Счета в архив»", text: $draft.name)
                            .rulesFieldStyle()
                    }
                    GridRow {
                        label("Ящик")
                        Picker("", selection: $draft.accountID) {
                            Text("Все ящики").tag(UUID?.none)
                            ForEach(accounts) { account in
                                Text(account.displayName).tag(UUID?.some(account.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow(alignment: .top) {
                        label("Условия").padding(.top, 3)
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: $draft.matchAll) {
                                Text("Все условия").tag(true)
                                Text("Любое условие").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            ForEach($conditions) { $row in
                                conditionRow($row)
                            }
                            Button {
                                conditions.append(RuleConditionDraft(condition: MailRule.Condition(field: .subject, match: .contains, value: "")))
                            } label: {
                                Label("Условие", systemImage: "plus")
                            }
                            .buttonStyle(UMButtonStyle(kind: .secondary, height: 24, horizontal: 10))
                        }
                    }
                    GridRow(alignment: .top) {
                        label("Действия").padding(.top, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($actions) { $row in
                                actionRow($row)
                            }
                            Button {
                                actions.append(RuleActionDraft(action: nextActionKind.defaultAction))
                            } label: {
                                Label("Действие", systemImage: "plus")
                            }
                            .buttonStyle(UMButtonStyle(kind: .secondary, height: 24, horizontal: 10))
                            Toggle("Не применять следующие правила", isOn: $draft.stopProcessing)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                                .foregroundStyle(UM.fg2)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 8) {
                if !canSave {
                    Text("Нужны название, хотя бы одно условие с текстом и действие")
                        .font(.system(size: 11.5))
                        .foregroundStyle(UM.fg3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Отмена", action: onCancel)
                    .buttonStyle(UMButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") { onSave(result) }
                    .buttonStyle(UMButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(UM.sheetBar)
            .hairline(.top)
        }
        .frame(width: 580, height: 440)
        .background(UM.sheet)
        .foregroundStyle(UM.fg)
        .font(.system(size: 13))
    }

    // MARK: Условия

    private func conditionRow(_ row: Binding<RuleConditionDraft>) -> some View {
        let id = row.wrappedValue.id
        return HStack(spacing: 6) {
            Picker("", selection: row.condition.field) {
                ForEach(MailRule.Field.allCases, id: \.self) { field in
                    Text(field.title).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 112)
            Picker("", selection: row.condition.match) {
                ForEach(MailRule.Match.allCases, id: \.self) { match in
                    Text(match.title).tag(match)
                }
            }
            .labelsHidden()
            .frame(width: 136)
            TextField("текст", text: row.condition.value)
                .rulesFieldStyle(height: 24)
            removeButton {
                conditions.removeAll { $0.id == id }
            }
            .disabled(conditions.count <= 1)
        }
    }

    // MARK: Действия

    private func actionRow(_ row: Binding<RuleActionDraft>) -> some View {
        let id = row.wrappedValue.id
        let kind = Binding<MailRule.Action.Kind>(
            get: { row.wrappedValue.action.kind },
            set: { newKind in
                if newKind != row.wrappedValue.action.kind {
                    row.wrappedValue.action = newKind.defaultAction
                }
            }
        )
        return HStack(spacing: 6) {
            Picker("", selection: kind) {
                ForEach(MailRule.Action.Kind.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            .frame(width: 186)
            parameter(row)
            Spacer(minLength: 0)
            removeButton {
                actions.removeAll { $0.id == id }
            }
        }
    }

    /// Параметр действия: папка, категория, часы или вкл/выкл уведомления.
    @ViewBuilder
    private func parameter(_ row: Binding<RuleActionDraft>) -> some View {
        switch row.wrappedValue.action {
        case .moveTo(let role):
            Picker("", selection: Binding<MailboxRole>(
                get: { role },
                set: { row.wrappedValue.action = .moveTo($0) }
            )) {
                ForEach(MailRule.Action.movableRoles) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        case .setCategory(let category):
            Picker("", selection: Binding<InboxCategory>(
                get: { category },
                set: { row.wrappedValue.action = .setCategory($0) }
            )) {
                ForEach(InboxCategory.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        case .snooze(let hours):
            Stepper(value: Binding<Int>(
                get: { hours },
                set: { row.wrappedValue.action = .snooze(hours: max(1, $0)) }
            ), in: 1...336) {
                Text(MailRule.Action.hoursText(hours))
                    .monospacedDigit()
                    .frame(minWidth: 70, alignment: .leading)
            }
            .fixedSize()
        case .notify(let on):
            Picker("", selection: Binding<Bool>(
                get: { on },
                set: { row.wrappedValue.action = .notify($0) }
            )) {
                Text("Уведомлять").tag(true)
                Text("Не уведомлять").tag(false)
            }
            .labelsHidden()
            .frame(width: 150)
        case .markRead, .flag:
            EmptyView()
        }
    }

    /// Следующее действие по умолчанию — первый ещё не использованный тип.
    private var nextActionKind: MailRule.Action.Kind {
        let used = Set(actions.map { $0.action.kind })
        return MailRule.Action.Kind.allCases.first { !used.contains($0) } ?? .markRead
    }

    // MARK: Итог

    private var result: MailRule {
        var rule = draft
        rule.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.conditions = conditions.map(\.condition).map { (condition: MailRule.Condition) -> MailRule.Condition in
            var c = condition
            c.value = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return c
        }.filter { !$0.value.isEmpty }
        rule.actions = actions.map(\.action)
        return rule
    }

    private var canSave: Bool {
        let r = result
        return !r.name.isEmpty && !r.conditions.isEmpty && !r.actions.isEmpty
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .font(.system(size: 13))
                .foregroundStyle(UM.fg2)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(HoverStyle(radius: 6))
        .help("Убрать")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(UM.fg2)
            .frame(width: 80, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

// MARK: - Стили

private extension View {
    func rulesCardStyle() -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func rulesFieldStyle(height: CGFloat = 28) -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.card))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
    }
}
