import SwiftUI

/// Настройки (экран 12 макета): вкладки-иконки в тулбаре окна.
@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Аккаунты", systemImage: "at") }
            AppearanceSettings()
                .tabItem { Label("Внешний вид", systemImage: "paintpalette") }
            BehaviorSettings()
                .tabItem { Label("Поведение", systemImage: "slider.horizontal.3") }
            NotificationsSettingsTab()
                .tabItem { Label("Уведомления", systemImage: "bell.badge") }
            RulesSettingsTab()
                .tabItem { Label("Правила", systemImage: "line.3.horizontal.decrease.circle") }
            TemplatesSettingsTab()
                .tabItem { Label("Шаблоны", systemImage: "text.badge.plus") }
            IntegrationsSettingsTab()
                .tabItem { Label("Интеграции", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 700, height: 540)
        .background(UM.sheet)
        .foregroundStyle(UM.fg)
        .font(.system(size: 13))
    }
}

// MARK: - Аккаунты

@MainActor
private struct AccountsSettings: View {
    @Environment(MailStore.self) private var store
    @State private var selection: UUID?
    @State private var adding = false
    @State private var pendingRemoval: Account?

    var body: some View {
        @Bindable var store = store
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.accounts) { account in
                            accountRow(account)
                                .draggable(account.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let raw = items.first, let id = UUID(uuidString: raw),
                                          let from = store.accounts.firstIndex(where: { $0.id == id }),
                                          let to = store.accounts.firstIndex(where: { $0.id == account.id }) else { return false }
                                    withAnimation(Motion.snappy) {
                                        store.moveAccounts(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
                                    }
                                    return true
                                }
                        }
                    }
                    .padding(4)
                }
                HStack(spacing: 0) {
                    // contentShape: у .plain-кнопки иначе кликабелен только сам тонкий значок.
                    Button { adding = true } label: {
                        Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .help("Добавить ящик")
                    Rectangle().fill(UM.sep).frame(width: 0.5)
                    Button {
                        pendingRemoval = selection.flatMap { store.account($0) }
                    } label: {
                        Image(systemName: "minus").frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .help("Удалить ящик")
                    .disabled(selection == nil)
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

            if let index = store.accounts.firstIndex(where: { $0.id == selection }) {
                ScrollView {
                    accountForm($store.accounts[index])
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
            } else {
                Text("Выберите аккаунт слева")
                    .foregroundStyle(UM.fg3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .sheet(isPresented: $adding) { AddAccountView() }
        .onAppear { selection = selection ?? store.accounts.first?.id }
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            // Ящик удалили (здесь или из панели аккаунтов) — выделяем первый оставшийся.
            if let current = selection, !ids.contains(current) { selection = ids.first }
            if selection == nil { selection = ids.first }
        }
        .confirmationDialog(
            "Удалить ящик «\(pendingRemoval?.displayName ?? "")»?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let account = pendingRemoval { remove(account.id) }
                pendingRemoval = nil
            }
            Button("Отмена", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval?.kind == .demo
                 ? "Демо-письма этого ящика исчезнут."
                 : "Письма и пароль удалятся с этого Mac. На сервере почта останется.")
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(Motion.snappy) { store.removeAccount(id) }
        selection = store.accounts.first?.id
    }

    private func accountRow(_ account: Account) -> some View {
        let on = account.id == selection
        return Button { selection = account.id } label: {
            HStack(spacing: 9) {
                Image(systemName: "line.3.horizontal").font(.system(size: 11)).opacity(0.4)
                AccountTile(account: account, size: 28, radius: 8, fontSize: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.displayName).fontWeight(.semibold)
                    Text(account.email).font(.system(size: 11)).opacity(on ? 0.8 : 0.5).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? Color.white : UM.fg)
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? UM.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func accountForm(_ account: Binding<Account>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                label("Название")
                TextField("", text: account.displayName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.card))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
            }
            GridRow {
                label("Адрес")
                Text("\(account.wrappedValue.email) · \(account.wrappedValue.providerTitle)")
                    .foregroundStyle(UM.fg3)
                    .lineLimit(1)
            }
            if account.wrappedValue.kind == .demo {
                GridRow(alignment: .top) {
                    label("Демо")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ящик с примерами писем из макета — без сервера. Когда подключите свои ящики, демо можно убрать.")
                            .font(.system(size: 12))
                            .foregroundStyle(UM.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Удалить все демо-ящики", role: .destructive) {
                            withAnimation(Motion.snappy) { store.removeDemoAccounts() }
                            selection = store.accounts.first?.id
                        }
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
                    }
                }
            }
            if account.wrappedValue.kind != .demo {
                GridRow {
                    label("Серверы")
                    Text(serverSummary(account.wrappedValue))
                        .foregroundStyle(UM.fg3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                GridRow {
                    label("Пароль")
                    PasswordRow(accountID: account.wrappedValue.id)
                }
            }
            GridRow {
                label("Цвет")
                HStack(spacing: 8) {
                    ForEach(AccountTint.allCases, id: \.self) { tint in
                        let on = tint == account.wrappedValue.tint
                        Circle()
                            .fill(tint.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.black.opacity(on ? 0 : 0.15), lineWidth: 0.5))
                            .background(Circle().strokeBorder(on ? tint.color : .clear, lineWidth: 2).padding(-4))
                            .onTapGesture { withAnimation(Motion.snappy) { account.wrappedValue.tint = tint } }
                            .help(tint.title)
                    }
                }
            }
            GridRow(alignment: .top) {
                label("Подписи").padding(.top, 6)
                SignaturesEditor(account: account)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("Показывать в «Все ящики»", isOn: Binding(
                    get: { account.wrappedValue.hiddenFromUnified != true },
                    set: { account.wrappedValue.hiddenFromUnified = !$0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(UM.fg2)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(UM.fg2)
            .frame(width: 86, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func serverSummary(_ account: Account) -> String {
        guard let server = account.server else { return "не заданы" }
        return "IMAP \(server.imapHost):\(server.imapPort) · SMTP \(server.smtpHost):\(server.smtpPort)"
    }
}

/// Подписи ящика: список (название + текст) и какая подставляется сама в новые письма и в ответы.
@MainActor
private struct SignaturesEditor: View {
    @Binding var account: Account

    private var list: Binding<[MailSignature]> {
        Binding(get: { account.signatures ?? [] }, set: { account.signatures = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(list) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("", text: $item.name, prompt: Text("Название").foregroundColor(UM.fg3))
                            .textFieldStyle(.plain)
                            .fontWeight(.medium)
                        Button {
                            remove(item.id)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(UM.fg3)
                        .help("Удалить подпись")
                    }
                    TextEditor(text: $item.text)
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .frame(height: 62)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.card))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
            }

            Button {
                add()
            } label: {
                Label("Добавить подпись", systemImage: "plus")
            }
            .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))

            if !list.wrappedValue.isEmpty {
                picker("Новые письма", selection: $account.newMailSignatureID)
                picker("Ответы и пересылки", selection: $account.replySignatureID)
            }
            Text("Подпись вставляется над цитатой автоматически. В окне письма её можно сменить или убрать кнопкой «Подпись».")
                .font(.system(size: 11.5))
                .foregroundStyle(UM.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func picker(_ title: String, selection: Binding<UUID?>) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(UM.fg2).frame(width: 130, alignment: .leading)
            Picker("", selection: selection) {
                Text("Без подписи").tag(UUID?.none)
                ForEach(list.wrappedValue) { item in
                    Text(item.name.isEmpty ? "Без названия" : item.name).tag(UUID?.some(item.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .font(.system(size: 12.5))
    }

    private func add() {
        let number = list.wrappedValue.count + 1
        let name = number == 1 ? "Основная" : "Подпись \(number)"
        let text = account.senderName ?? account.displayName
        let item = MailSignature(name: name, text: text)
        withAnimation(Motion.snappy) {
            account.signatures = list.wrappedValue + [item]
            // Первая подпись сразу подставляется везде.
            if account.newMailSignatureID == nil && number == 1 { account.newMailSignatureID = item.id }
            if account.replySignatureID == nil && number == 1 { account.replySignatureID = item.id }
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(Motion.snappy) {
            account.signatures = list.wrappedValue.filter { $0.id != id }
            if account.newMailSignatureID == id { account.newMailSignatureID = nil }
            if account.replySignatureID == id { account.replySignatureID = nil }
        }
    }
}

/// Новый пароль (пароль приложения) и проверка подключения.
@MainActor
private struct PasswordRow: View {
    @Environment(MailStore.self) private var store
    let accountID: UUID
    @State private var secret = ""
    @State private var checking = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SecureField("", text: $secret, prompt: Text("Новый пароль приложения").foregroundColor(UM.fg3))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.card))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
                Button("Сохранить") {
                    store.updatePassword(secret, for: accountID)
                    secret = ""
                    status = "Пароль сохранён в Связке ключей"
                }
                .buttonStyle(UMButtonStyle(kind: .secondary, height: 28, radius: 7))
                .disabled(secret.isEmpty)
                Button {
                    checking = true
                    status = nil
                    Task {
                        await store.refresh(accountID: accountID)
                        checking = false
                        status = store.accountErrors[accountID] ?? "Подключение работает"
                    }
                } label: {
                    if checking { ProgressView().controlSize(.small) } else { Text("Проверить") }
                }
                .buttonStyle(UMButtonStyle(kind: .secondary, height: 28, radius: 7))
                .disabled(checking)
            }
            if let status {
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg3)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Внешний вид

@MainActor
private struct AppearanceSettings: View {
    @AppStorage("appearance") private var appearance: AppearanceMode = .auto
    @AppStorage("listDensity") private var density: ListDensity = .comfortable

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 22) {
            GridRow(alignment: .top) {
                label("Тема").padding(.top, 4)
                HStack(spacing: 12) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button {
                            appearance = mode
                            mode.apply()
                        } label: {
                            VStack(spacing: 6) {
                                ThemeThumbnail(mode: mode)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(mode == appearance ? .clear : UM.cardBorder, lineWidth: 0.5))
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(mode == appearance ? UM.accent : .clear, lineWidth: 2)
                                        .padding(-4))
                                Text(mode.title)
                                    .font(.system(size: 12, weight: mode == appearance ? .semibold : .regular))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            GridRow(alignment: .top) {
                label("Плотность списка").padding(.top, 4)
                VStack(spacing: 8) {
                    ForEach(ListDensity.allCases) { option in
                        Button { withAnimation(Motion.snappy) { density = option } } label: {
                            DensityCard(density: option, selected: option == density)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(UM.fg2).frame(width: 120, alignment: .trailing).gridColumnAlignment(.trailing)
    }
}

private struct ThemeThumbnail: View {
    let mode: AppearanceMode

    var body: some View {
        HStack(spacing: 0) {
            sidePart.frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(lineColor).frame(width: 34, height: 4)
                Capsule().fill(lineColor).frame(width: 44, height: 4)
                Capsule().fill(Color(hex: 0x3D6AF2)).frame(width: 24, height: 4)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 76, height: 50)
        .background(backgroundPart)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var lineColor: Color {
        switch mode {
        case .light: Color(hex: 0xD0D0D6)
        case .dark: Color(hex: 0x44444B)
        case .auto: Color(hex: 0x8E8E98)
        }
    }

    @ViewBuilder private var backgroundPart: some View {
        switch mode {
        case .light: Color.white
        case .dark: Color(hex: 0x1C1C1F)
        case .auto:
            HStack(spacing: 0) {
                Color.white
                Color(hex: 0x1C1C1F)
            }
        }
    }

    @ViewBuilder private var sidePart: some View {
        switch mode {
        case .light: Color(hex: 0xE8E8EC)
        case .dark: Color(hex: 0x2A2A30)
        case .auto:
            VStack(spacing: 0) {
                Color(hex: 0xE8E8EC)
                Color(hex: 0x2A2A30)
            }
        }
    }
}

private struct DensityCard: View {
    let density: ListDensity
    let selected: Bool

    private var pad: CGFloat {
        switch density {
        case .compact: 0
        case .comfortable: 3
        case .spacious: 7
        }
    }

    private var avatar: CGFloat {
        switch density {
        case .compact: 14
        case .comfortable: 20
        case .spacious: 24
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            RadioDot(isOn: selected)
            Text(density.title).fontWeight(.semibold).frame(width: 84, alignment: .leading)
            HStack(spacing: 8) {
                Circle().fill(UM.dim).frame(width: avatar, height: avatar)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(UM.fg3).frame(width: 60, height: 5)
                    Capsule().fill(UM.dim).frame(height: 4)
                    if density.showsPreview {
                        Capsule().fill(UM.dim).frame(width: 110, height: 4)
                    }
                }
            }
            .padding(.vertical, pad)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? UM.accent : UM.cardBorder, lineWidth: selected ? 1.5 : 0.5))
        .contentShape(Rectangle())
    }
}

// MARK: - Поведение

@MainActor
private struct BehaviorSettings: View {
    @AppStorage("undoSeconds") private var undoSeconds: Double = 5
    @AppStorage("remoteImages") private var remoteImages = 0
    @AppStorage("stripTrackers") private var stripTrackers = true
    @AppStorage("reduceMotion") private var reduceMotion = false

    private let imageOptions: [(String, String)] = [
        ("Всегда спрашивать", "Показывать плашку приватности над письмом"),
        ("Загружать от известных отправителей", "Тех, кому вы писали хотя бы раз"),
        ("Загружать всегда", "Отправители увидят ваш IP и время открытия"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 22) {
            GridRow(alignment: .top) {
                label("Окно «Отменить»")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 12) {
                        Slider(value: $undoSeconds, in: 3...30, step: 1)
                        Text("\(Int(undoSeconds)) с")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("3 с")
                        Spacer()
                        Text("30 с")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(UM.fg3)
                    .padding(.trailing, 56)
                    Text("Сколько секунд после архивации, удаления и отправки можно всё вернуть.")
                        .font(.system(size: 12))
                        .foregroundStyle(UM.fg3)
                        .padding(.top, 4)
                }
            }
            GridRow(alignment: .top) {
                label("Удалённые изображения")
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(imageOptions.enumerated()), id: \.offset) { index, option in
                        Button { remoteImages = index } label: {
                            HStack(alignment: .top, spacing: 9) {
                                RadioDot(isOn: remoteImages == index)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.0).fontWeight(.medium)
                                    Text(option.1).font(.system(size: 11.5)).foregroundStyle(UM.fg3)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            GridRow(alignment: .top) {
                label("Приватность")
                VStack(alignment: .leading, spacing: 10) {
                    toggleRow("Вырезать трекинг-пиксели", isOn: $stripTrackers)
                    toggleRow("Уменьшить движение (как в системе)", isOn: $reduceMotion)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 10) {
                MiniSwitch(isOn: isOn.wrappedValue, width: 30, height: 18)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(UM.fg2).frame(width: 170, alignment: .trailing).gridColumnAlignment(.trailing)
    }
}
