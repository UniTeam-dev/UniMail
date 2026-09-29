import SwiftUI

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Аккаунты", systemImage: "person.2") }
            AppearanceSettings()
                .tabItem { Label("Внешний вид", systemImage: "paintbrush") }
            BehaviorSettings()
                .tabItem { Label("Поведение", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 620, height: 460)
    }
}

@MainActor
private struct AccountsSettings: View {
    @Environment(MailStore.self) private var store
    @State private var selection: UUID?
    @State private var adding = false

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 10) {
                            AccountAvatar(account: account, size: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(account.displayName)
                                Text(account.kind.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(account.id)
                    }
                    .onMove { store.moveAccounts(from: $0, to: $1) }
                }
                HStack(spacing: 0) {
                    Button { adding = true } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button {
                        let removed = selection
                        selection = nil
                        if let removed { store.removeAccount(removed) }
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 210)

            Divider()

            if let index = store.accounts.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("Имя", text: $store.accounts[index].displayName)
                    LabeledContent("Адрес", value: store.accounts[index].email)
                    Picker("Цвет", selection: $store.accounts[index].tint) {
                        ForEach(AccountTint.allCases, id: \.self) { t in
                            Text(t.rawValue.capitalized).tag(t)
                        }
                    }
                    Section("Подпись") {
                        TextEditor(text: $store.accounts[index].signature)
                            .frame(height: 90)
                            .font(.system(size: 13))
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Выберите аккаунт", systemImage: "person.crop.circle",
                                       description: Text("Порядок в списке = порядок в панели и шорткаты ⌘1…⌘9"))
            }
        }
        .sheet(isPresented: $adding) { AddAccountView() }
        .onAppear { selection = selection ?? store.accounts.first?.id }
    }
}

@MainActor
private struct AppearanceSettings: View {
    @AppStorage("listDensity") private var density: ListDensity = .comfortable

    var body: some View {
        Form {
            Picker("Плотность списка", selection: $density) {
                ForEach(ListDensity.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Акцентный цвет", value: "Системный (Системные настройки → Оформление)")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct BehaviorSettings: View {
    @AppStorage("undoSeconds") private var undoSeconds: Double = 5
    @AppStorage("loadRemoteImages") private var loadRemoteImages = false

    var body: some View {
        Form {
            Section("Отмена действий") {
                Slider(value: $undoSeconds, in: 3...30, step: 1) {
                    Text("Окно «Отменить»: \(Int(undoSeconds)) с")
                }
                Text("Архивация, удаление и отправка уходят на сервер только после этого окна.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Приватность") {
                Toggle("Загружать удалённые изображения", isOn: $loadRemoteImages)
                Text("Трекинг-пиксели вырезаются всегда, даже если изображения разрешены.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
