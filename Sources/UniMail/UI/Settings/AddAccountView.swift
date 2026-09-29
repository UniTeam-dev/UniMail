import SwiftUI

/// Встроенные настройки серверов популярных провайдеров. Этап 2: + Mozilla ISPDB и SRV-записи.
enum ServerPresets {
    static func settings(for email: String) -> ServerSettings? {
        guard let domain = email.split(separator: "@").last?.lowercased(), domain.contains(".") else { return nil }
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
            "fastmail.com": ("imap.fastmail.com", "smtp.fastmail.com"),
            "outlook.com": ("outlook.office365.com", "smtp.office365.com"),
            "hotmail.com": ("outlook.office365.com", "smtp.office365.com"),
        ]
        if let pair = map[domain] {
            let (imap, smtp) = pair
            let icloud = imap == "imap.mail.me.com"
            let office = imap == "outlook.office365.com"
            let starttls = icloud || office
            return ServerSettings(
                imapHost: imap, imapPort: 993,
                smtpHost: smtp, smtpPort: starttls ? 587 : 465,
                username: icloud ? String(email.split(separator: "@").first ?? "") : email,
                imapSecurity: .tls, smtpSecurity: starttls ? .starttls : .tls
            )
        }
        return ServerSettings(imapHost: "imap.\(domain)", smtpHost: "smtp.\(domain)", username: email)
    }

    /// Выбран Gmail или iCloud — их серверы и для своего домена (Google Workspace, iCloud+).
    static func settings(for email: String, kind: ProviderKind) -> ServerSettings? {
        switch kind {
        case .gmail: return retarget(settings(for: "x@gmail.com"), email: email)
        case .icloud:
            var preset = settings(for: "x@icloud.com")
            preset?.username = email
            return preset
        default: return settings(for: email)
        }
    }

    private static let known: Set<String> = ["yandex.ru", "ya.ru", "mail.ru", "bk.ru", "inbox.ru", "list.ru", "rambler.ru",
                                             "icloud.com", "me.com", "gmail.com", "fastmail.com", "outlook.com", "hotmail.com"]

    private static func retarget(_ preset: ServerSettings?, email: String) -> ServerSettings? {
        guard var preset else { return nil }
        preset.username = email
        return preset
    }

    /// Свой домен на Яндексе, Google, Mail.ru, Microsoft 365 или iCloud: смотрим MX-записи (DNS over HTTPS).
    /// Возвращает настройки и название почтового сервиса.
    static func detectByMX(_ email: String) async -> (ServerSettings, String)? {
        guard let domain = email.split(separator: "@").last?.lowercased(), domain.contains("."),
              !known.contains(domain),
              let url = URL(string: "https://dns.google/resolve?name=\(domain)&type=MX") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else { return nil }
        let hosts = answers.compactMap { ($0["data"] as? String)?.lowercased() }.joined(separator: " ")
        let map: [(String, String, String)] = [
            ("yandex", "x@yandex.ru", "Яндекс 360"),
            ("google", "x@gmail.com", "Google Workspace"),
            ("mail.ru", "x@mail.ru", "Почта Mail.ru для бизнеса"),
            ("outlook.com", "x@outlook.com", "Microsoft 365"),
            ("icloud", "x@icloud.com", "iCloud+"),
            ("messagingengine", "x@fastmail.com", "Fastmail"),
        ]
        for (needle, sample, title) in map where hosts.contains(needle) {
            guard var preset = settings(for: sample) else { continue }
            preset.username = email
            return (preset, title)
        }
        return nil
    }
}

/// Мастер «Добавить почтовый ящик»: шаг 1 — провайдер, шаг 2 — данные и серверы (экран 10 макета).
@MainActor
struct AddAccountView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var kind: ProviderKind = .imap
    @State private var senderName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var label = ""
    @State private var tint: AccountTint = .green
    @State private var server = ServerSettings(imapHost: "", smtpHost: "", username: "")
    @State private var serversOpen = true
    /// Проверка входа перед добавлением.
    @State private var verifying = false
    @State private var verifyError: String?
    /// Откуда взялись серверы: готовые настройки, MX-записи домена или догадка.
    @State private var serverSource: String?
    @State private var mxTask: Task<Void, Never>?
    /// Outlook / Exchange: EWS (как Outlook для Mac) или IMAP/SMTP.
    @State private var useEWS = true
    @State private var exchangeServer = ""
    @State private var exchangeLogin = ""

    var body: some View {
        VStack(spacing: 0) {
            // Шапка 40 pt со шкалой шагов
            HStack {
                Spacer()
                HStack(spacing: 5) {
                    Capsule().fill(UM.accent).frame(width: 18, height: 4)
                    Capsule().fill(step == 2 ? UM.accent : UM.dim).frame(width: 18, height: 4)
                }
                .animation(Motion.smooth, value: step)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)

            ZStack(alignment: .top) {
                if step == 1 {
                    providerStep
                        .transition(Motion.reduce ? AnyTransition.opacity : .push(from: .leading))
                } else {
                    detailsStep
                        .transition(Motion.reduce ? AnyTransition.opacity : .push(from: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .animation(Motion.smooth, value: step)

            // Ошибка проверки входа — отдельной плашкой на всю ширину, текст целиком (можно выделить и скопировать).
            if step == 2, let verifyError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(UM.orange)
                        .padding(.top, 1)
                    Text(verifyError)
                        .font(.system(size: 12))
                        .foregroundStyle(UM.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UM.orange.opacity(0.12)))
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                if step == 2 {
                    Button { step = 1 } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text("Назад")
                        }
                        .foregroundStyle(UM.fg2)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                    }
                    .buttonStyle(HoverStyle(radius: 7))
                }
                Spacer()
                Button("Отмена") { dismiss() }
                    .buttonStyle(UMButtonStyle(kind: .secondary, height: 28, radius: 7))
                    .keyboardShortcut(.cancelAction)
                if step == 2 && verifyError != nil {
                    Button { add() } label: { Text("Добавить всё равно").lineLimit(1).fixedSize() }
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 28, radius: 7))
                }
                Button {
                    if step == 1 { prepareDetails() } else { verifyAndAdd() }
                } label: {
                    HStack(spacing: 6) {
                        if verifying { ProgressView().controlSize(.small) }
                        Text(step == 1 ? "Продолжить" : (verifying ? "Проверяю вход…" : "Добавить ящик"))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(UMButtonStyle(kind: .primary, height: 28, radius: 7, horizontal: 16))
                .keyboardShortcut(.defaultAction)
                .disabled(step == 2 && (!canAdd || verifying))
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
            .hairline(.top)
        }
        .animation(Motion.snappy, value: verifyError)
        .frame(width: 560, height: 520)
        .background(UM.sheet)
        .foregroundStyle(UM.fg)
        .font(.system(size: 13))
    }

    // MARK: Шаг 1

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Добавить почтовый ящик")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.44)
            Text("Письма скачиваются и хранятся только на этом Mac. UniMail не пересылает их на свои серверы.")
                .font(.system(size: 13))
                .foregroundStyle(UM.fg2)
                .lineSpacing(3)
                .padding(.top, 6)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ProviderKind.allCases) { option in
                    ProviderCard(kind: option, selected: option == kind) {
                        withAnimation(Motion.snappy) { kind = option }
                    }
                }
            }
            .padding(.top, 22)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 12))
                Text("Пароль хранится в Связке ключей macOS, а не в UniMail")
            }
            .font(.system(size: 12))
            .foregroundStyle(UM.fg3)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 32)
        .padding(.top, 6)
    }

    // MARK: Шаг 2

    private var detailsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(String((label.isEmpty ? kind.title : label).prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.color))
                        .animation(Motion.smooth, value: tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.title).font(.system(size: 19, weight: .bold)).tracking(-0.38)
                        Text(kind.detail).font(.system(size: 12.5)).foregroundStyle(UM.fg2)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    formRow("Имя") { field("Как вас подписывать", text: $senderName) }
                    formRow("Адрес") {
                        field("name@example.com", text: $email)
                            .onChange(of: email) { _, value in detectServers(for: value) }
                    }
                    if kind.usesPassword {
                        formRow("Пароль") {
                            VStack(alignment: .leading, spacing: 4) {
                                field("Пароль или пароль приложения", text: $password, secure: true)
                                if let help = passwordHelp {
                                    Link(help.0, destination: help.1).font(.system(size: 11.5))
                                }
                            }
                        }
                    }
                    formRow("Название ящика") { field("Например, Работа", text: $label) }
                    formRow("Цвет") {
                        HStack(spacing: 8) {
                            ForEach(AccountTint.allCases, id: \.self) { option in
                                let on = option == tint
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.black.opacity(on ? 0 : 0.15), lineWidth: 0.5))
                                    .padding(on ? 2 : 0)
                                    .overlay(Circle().strokeBorder(on ? option.color : .clear, lineWidth: 2).padding(on ? -2 : 0))
                                    .scaleEffect(on ? 1.1 : 1)
                                    .animation(Motion.bouncy, value: on)
                                    .onTapGesture { tint = option }
                                    .help(option.title)
                            }
                        }
                    }
                }
                .padding(.top, 22)

                if kind == .outlook {
                    Picker("", selection: $useEWS) {
                        Text("Exchange (EWS)").tag(true)
                        Text("IMAP и SMTP").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.top, 18)
                }
                if kind == .outlook && useEWS {
                    exchangeCard.padding(.top, 12)
                } else if kind.usesPassword {
                    serversCard.padding(.top, kind == .outlook ? 12 : 18)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }

    private var exchangeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                formRow("Сервер") { field("mail.company.ru — как в Outlook", text: $exchangeServer) }
                formRow("Логин") { field("DOMAIN\\user или адрес почты", text: $exchangeLogin) }
            }
            Text("Тот же сервер, что указан в Outlook. Логин можно не заполнять — тогда используется адрес почты. Письма отправляются через Exchange.")
                .font(.system(size: 11.5))
                .foregroundStyle(UM.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UM.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
    }

    /// Серверы по адресу: готовые настройки, потом MX-записи домена (свой домен на Яндексе, Google…).
    private func detectServers(for value: String) {
        mxTask?.cancel()
        if let preset = ServerPresets.settings(for: value, kind: kind) {
            server = preset
            let domain = value.split(separator: "@").last.map(String.init) ?? ""
            serverSource = (kind == .gmail || kind == .icloud || !preset.imapHost.hasSuffix(domain)) ? "Найдены автоматически" : nil
        }
        if kind == .outlook, exchangeServer.isEmpty || exchangeServer.hasPrefix("mail.") {
            let domain = value.split(separator: "@").last.map(String.init) ?? ""
            if domain.contains(".") { exchangeServer = "mail.\(domain)" }
        }
        guard kind == .imap || kind == .outlook, serverSource == nil else { return }
        mxTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let (preset, title) = await ServerPresets.detectByMX(value), !Task.isCancelled else { return }
            withAnimation(Motion.snappy) {
                server = preset
                serverSource = "Почта на \(title)"
            }
        }
    }

    private var serversCard: some View {
        VStack(spacing: 0) {
            Button { withAnimation(Motion.smooth) { serversOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.fg3)
                        .rotationEffect(.degrees(serversOpen ? 90 : 0))
                    Text("Серверы IMAP и SMTP").fontWeight(.semibold)
                    Spacer()
                    if let serverSource, !server.imapHost.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle").font(.system(size: 12))
                            Text(serverSource)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(UM.privFg)
                    } else if !server.imapHost.isEmpty {
                        Text("Проверьте адреса у почтового сервиса")
                            .font(.system(size: 11.5))
                            .foregroundStyle(UM.fg3)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if serversOpen {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Color.clear.frame(width: 44, height: 1)
                        Text("Сервер").foregroundStyle(UM.fg3)
                        Text("Порт").foregroundStyle(UM.fg3)
                        Text("Защита").foregroundStyle(UM.fg3)
                    }
                    serverRow("IMAP", host: $server.imapHost, port: imapPort, security: imapSecurity)
                    serverRow("SMTP", host: $server.smtpHost, port: smtpPort, security: smtpSecurity)
                }
                .font(.system(size: 12))
                .padding(12)
                .hairline(.top)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UM.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
    }

    /// Защита и порт связаны: STARTTLS на 993 не заработает — порт меняется вместе с защитой и наоборот.
    private var imapSecurity: Binding<ConnectionSecurity> {
        Binding(get: { server.imapSecurity ?? .tls }, set: { value in
            server.imapSecurity = value
            if value == .starttls && server.imapPort == 993 { server.imapPort = 143 }
            if value == .tls && server.imapPort == 143 { server.imapPort = 993 }
        })
    }

    private var smtpSecurity: Binding<ConnectionSecurity> {
        Binding(get: { server.smtpSecurity ?? .tls }, set: { value in
            server.smtpSecurity = value
            if value == .starttls && server.smtpPort == 465 { server.smtpPort = 587 }
            if value == .tls && server.smtpPort == 587 { server.smtpPort = 465 }
        })
    }

    private var imapPort: Binding<Int> {
        Binding(get: { server.imapPort }, set: { value in
            server.imapPort = value
            if value == 993 { server.imapSecurity = .tls }
            if value == 143 { server.imapSecurity = .starttls }
        })
    }

    private var smtpPort: Binding<Int> {
        Binding(get: { server.smtpPort }, set: { value in
            server.smtpPort = value
            if value == 465 { server.smtpSecurity = .tls }
            if value == 587 || value == 25 { server.smtpSecurity = .starttls }
        })
    }

    private func serverRow(_ title: String, host: Binding<String>, port: Binding<Int>,
                           security: Binding<ConnectionSecurity>) -> some View {
        GridRow {
            Text(title).fontWeight(.semibold).foregroundStyle(UM.fg2)
            TextField("", text: host)
                .textFieldStyle(.plain)
                .font(UM.mono(11.5))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(UM.field))
            TextField("", value: port, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(UM.mono(11.5))
                .padding(.horizontal, 8)
                .frame(width: 70, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(UM.field))
            Picker("", selection: security) {
                ForEach(ConnectionSecurity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(UM.fg2)
                .frame(width: 120, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        Group {
            if secure {
                SecureField("", text: text, prompt: Text(placeholder).foregroundColor(UM.fg3))
            } else {
                TextField("", text: text, prompt: Text(placeholder).foregroundColor(UM.fg3))
            }
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.field))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
    }

    private var passwordHelp: (String, URL)? {
        switch kind {
        case .gmail: return ("Как получить пароль приложения Google", URL(string: "https://myaccount.google.com/apppasswords")!)
        case .icloud: return ("Как получить пароль приложения Apple", URL(string: "https://account.apple.com")!)
        default: return nil
        }
    }

    // MARK: Логика

    private func prepareDetails() {
        let used = Set(store.accounts.map(\.tint))
        tint = AccountTint.allCases.first { !used.contains($0) } ?? .green
        if kind == .demo {
            label = "Демо \(store.accounts.count + 1)"
            email = "demo\(store.accounts.count + 1)@example.com"
        }
        serverSource = nil
        if !email.isEmpty { detectServers(for: email) }
        step = 2
    }

    private var canAdd: Bool {
        let emailOK = Address(name: nil, email: email).isValid
        if kind == .outlook && useEWS { return emailOK && !password.isEmpty && EWSEndpoint.url(for: exchangeServer) != nil }
        return kind.usesPassword ? emailOK && !password.isEmpty : emailOK
    }

    /// Сначала проверяем вход по IMAP и SMTP: неверный пароль виден сразу, а не после добавления.
    private func verifyAndAdd() {
        guard kind.usesPassword else { add(); return }
        verifying = true
        verifyError = nil
        let account = makeAccount()
        let secret = password
        Task {
            do {
                try await store.verify(account, secret: secret)
                verifying = false
                add()
            } catch {
                verifying = false
                verifyError = error.localizedDescription
            }
        }
    }

    private func add() {
        store.addAccount(makeAccount(), secret: password.isEmpty ? nil : password)
        dismiss()
    }

    private func makeAccount() -> Account {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return Account(
            displayName: label.isEmpty ? (trimmed.split(separator: "@").first.map(String.init) ?? trimmed) : label,
            email: trimmed,
            kind: kind,
            tint: tint,
            server: kind.usesPassword && !(kind == .outlook && useEWS) ? server : nil,
            exchange: kind == .outlook && useEWS
                ? ExchangeSettings(server: exchangeServer.trimmingCharacters(in: .whitespaces),
                                   username: exchangeLogin.trimmingCharacters(in: .whitespaces))
                : nil,
            senderName: senderName.isEmpty ? nil : senderName
        )
    }
}

@MainActor
private struct ProviderCard: View {
    let kind: ProviderKind
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let letter = kind.letter {
                        Text(letter).font(.system(size: 17, weight: .heavy))
                    } else {
                        Image(systemName: kind.symbol).font(.system(size: 17))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(hex: kind.tileHex)))
                Spacer()
                Text(kind.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(kind.subtitle).font(.system(size: 11.5)).foregroundStyle(UM.fg3).padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 128, maxHeight: 128, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UM.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? UM.accent : UM.cardBorder, lineWidth: selected ? 2 : 0.5))
            .shadow(color: selected ? Color(red: 40 / 255, green: 80 / 255, blue: 220 / 255).opacity(0.14) : .black.opacity(0.04),
                    radius: selected ? 7 : 1, y: selected ? 4 : 1)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(UM.accent))
                        .padding(12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TileStyle())
    }
}
