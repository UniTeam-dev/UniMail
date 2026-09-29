import SwiftUI

/// Встроенные настройки серверов популярных провайдеров. Этап 2: + Mozilla ISPDB и SRV-записи.
enum ServerPresets {
    static func settings(for email: String) -> ServerSettings? {
        guard let domain = email.split(separator: "@").last?.lowercased() else { return nil }
        let map: [String: (String, String)] = [
            "yandex.ru": ("imap.yandex.ru", "smtp.yandex.ru"),
            "ya.ru": ("imap.yandex.ru", "smtp.yandex.ru"),
            "mail.ru": ("imap.mail.ru", "smtp.mail.ru"),
            "bk.ru": ("imap.mail.ru", "smtp.mail.ru"),
            "inbox.ru": ("imap.mail.ru", "smtp.mail.ru"),
            "list.ru": ("imap.mail.ru", "smtp.mail.ru"),
            "rambler.ru": ("imap.rambler.ru", "smtp.rambler.ru"),
            "icloud.com": ("imap.mail.me.com", "smtp.mail.me.com"),
            "me.com": ("imap.mail.me.com", "smtp.mail.me.com"),
            "gmail.com": ("imap.gmail.com", "smtp.gmail.com"),
            "outlook.com": ("outlook.office365.com", "smtp.office365.com"),
            "hotmail.com": ("outlook.office365.com", "smtp.office365.com"),
        ]
        if let pair = map[domain] {
            let (imap, smtp) = pair
            let icloud = imap == "imap.mail.me.com"
            let office = imap == "outlook.office365.com"
            return ServerSettings(
                imapHost: imap, imapPort: 993,
                smtpHost: smtp, smtpPort: icloud || office ? 587 : 465,
                username: icloud ? String(email.split(separator: "@").first ?? "") : email
            )
        }
        return ServerSettings(imapHost: "imap.\(domain)", smtpHost: "smtp.\(domain)", username: email)
    }
}

/// Мастер добавления аккаунта: выбор провайдера → данные входа.
@MainActor
struct AddAccountView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ProviderKind?
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var server = ServerSettings(imapHost: "", smtpHost: "", username: "")
    @State private var tint: AccountTint = .green
    @State private var showServer = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if kind != nil {
                    Button {
                        withAnimation(Motion.smooth) { kind = nil }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .transition(.opacity)
                }
                Text(kind.map { "Подключить \($0.title)" } ?? "Добавить почтовый ящик")
                    .font(.title2.weight(.bold))
                    .contentTransition(.opacity)
                Spacer()
            }
            .padding(20)

            ZStack {
                if let kind {
                    form(kind)
                        .transition(.push(from: .trailing))
                } else {
                    picker
                        .transition(.push(from: .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let kind {
                    Button("Добавить") { add(kind) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdd(kind))
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .animation(Motion.smooth, value: kind)
    }

    // MARK: Шаг 1 — выбор провайдера

    private var picker: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(ProviderKind.allCases) { option in
                ProviderCard(kind: option) {
                    kind = option
                    tint = AccountTint.allCases[(store.accounts.count + 3) % AccountTint.allCases.count]
                    if option == .demo {
                        name = "Демо \(store.accounts.count + 1)"
                        email = "demo\(store.accounts.count + 1)@example.com"
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Шаг 2 — данные

    @ViewBuilder
    private func form(_ kind: ProviderKind) -> some View {
        Form {
            if !kind.isAvailable {
                Section {
                    Label {
                        Text(stageNote(kind))
                    } icon: {
                        Image(systemName: "hammer.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }

            Section {
                TextField("Имя", text: $name, prompt: Text("Например, «Работа»"))
                TextField("Адрес", text: $email, prompt: Text("you@example.com"))
                    .onChange(of: email) { _, value in
                        if let preset = ServerPresets.settings(for: value) { server = preset }
                    }
                if kind.usesPassword {
                    SecureField(kind == .icloud || kind == .gmail ? "Пароль приложения" : "Пароль", text: $password)
                    if let help = passwordHelp(kind) {
                        Link(help.title, destination: help.url).font(.caption)
                    }
                }
                Picker("Цвет", selection: $tint) {
                    ForEach(AccountTint.allCases, id: \.self) { t in
                        HStack { Circle().fill(t.color).frame(width: 10, height: 10); Text(t.rawValue.capitalized) }
                            .tag(t)
                    }
                }
            }

            if kind == .imap || kind == .outlook {
                Section(isExpanded: $showServer) {
                    TextField("IMAP-сервер", text: $server.imapHost)
                    TextField("IMAP-порт", value: $server.imapPort, format: .number.grouping(.never))
                    TextField("SMTP-сервер", text: $server.smtpHost)
                    TextField("SMTP-порт", value: $server.smtpPort, format: .number.grouping(.never))
                    TextField("Логин", text: $server.username)
                } header: {
                    Text("Серверы (заполнены автоматически)")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func stageNote(_ kind: ProviderKind) -> String {
        switch kind {
        case .gmail: "IMAP появится на этапе 2. Нужна двухэтапная аутентификация и пароль приложения Google; пароль уже сейчас сохраняется в Связке ключей."
        case .outlook: "IMAP появится на этапе 2. Укажите сервер Exchange (например, mail.company.ru). Если сервер outlook.office365.com, нужен OAuth — это этап 4."
        case .icloud, .imap: "IMAP/SMTP появится на этапе 2. Пароль уже сейчас сохраняется в Связке ключей."
        case .demo: ""
        }
    }

    private func passwordHelp(_ kind: ProviderKind) -> (title: String, url: URL)? {
        switch kind {
        case .gmail: return ("Как получить пароль приложения Google", URL(string: "https://myaccount.google.com/apppasswords")!)
        case .icloud: return ("Как получить пароль приложения Apple", URL(string: "https://account.apple.com")!)
        default: return nil
        }
    }

    private func canAdd(_ kind: ProviderKind) -> Bool {
        let emailOK = email.contains("@")
        switch kind {
        case .imap, .icloud, .gmail, .outlook: return emailOK && !password.isEmpty
        default: return emailOK
        }
    }

    private func add(_ kind: ProviderKind) {
        let account = Account(
            displayName: name.isEmpty ? (email.split(separator: "@").first.map(String.init) ?? email) : name,
            email: email.trimmingCharacters(in: .whitespaces),
            kind: kind,
            tint: tint,
            server: kind.usesPassword ? server : nil
        )
        store.addAccount(account, secret: password.isEmpty ? nil : password)
        dismiss()
    }
}

@MainActor
private struct ProviderCard: View {
    let kind: ProviderKind
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kind.title).font(.headline)
                        if !kind.isAvailable {
                            Text("скоро")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(kind.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08))
            )
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.bouncy) { hovering = h } }
    }
}
