import AppKit
import SwiftUI

/// Настройки → Интеграции: доступ к Календарю и AI — Anthropic, сервисы с API OpenAI или своя модель (vLLM, Ollama, LM Studio).
@MainActor
struct IntegrationsSettingsTab: View {
    @AppStorage(AppSettings.aiEnabled) private var aiEnabled = false
    @State private var selectedID: UUID?

    private var calendar: CalendarService { .shared }
    private var ai: AIService { .shared }

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 22) {
                calendarRow

                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Rectangle().fill(UM.sep).frame(height: 0.5).frame(maxWidth: 420)
                }

                GridRow(alignment: .top) {
                    SettingsRowLabel("AI").padding(.top, 1)
                    SettingsSwitchRow("Сводка треда и черновик ответа",
                                      subtitle: "Модель на выбор: Claude, сервисы с API OpenAI или своя — на vLLM, Ollama, LM Studio. Выключено — никакие данные не отправляются.",
                                      isOn: $aiEnabled)
                        .frame(maxWidth: 420, alignment: .leading)
                }

                GridRow(alignment: .top) {
                    SettingsRowLabel("Модели").padding(.top, 6)
                    connectionsList
                }

                if let current = ai.connections.first(where: { $0.id == (selectedID ?? ai.active?.id) }) {
                    GridRow(alignment: .top) {
                        Color.clear.frame(width: 1, height: 1)
                        // Привязка по id, а не по индексу: подключение могут удалить, пока редактор открыт.
                        AIConnectionEditor(connection: Binding(
                            get: { ai.connections.first { $0.id == current.id } ?? current },
                            set: { ai.update($0) }
                        ))
                        .id(current.id)
                        .frame(maxWidth: 420, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            calendar.refreshAccess()
            calendar.reloadCalendars()
            if selectedID == nil { selectedID = ai.active?.id }
        }
    }

    // MARK: Календарь

    private var calendarTone: StatusPill.Tone {
        switch calendar.access {
        case .granted: .ok
        case .writeOnly, .notDetermined: .warn
        case .denied, .restricted: .bad
        }
    }

    private var calendarRow: some View {
        GridRow(alignment: .top) {
            SettingsRowLabel("Календарь").padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    StatusPill(calendar.access.title, tone: calendarTone)
                    switch calendar.access {
                    case .notDetermined, .writeOnly:
                        Button("Разрешить доступ") {
                            Task { await calendar.requestAccess() }
                        }
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 24, radius: 7, horizontal: 10))
                    case .denied, .restricted:
                        Button("Открыть Системные настройки") { calendar.openPrivacySettings() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    case .granted:
                        EmptyView()
                    }
                }
                Text("Расписание берётся из Календаря macOS: Google, Exchange и iCloud подключаются там. Встречи из приглашений добавляются в календарь по умолчанию.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                if !calendar.calendars.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(calendar.calendars) { item in
                            HStack(spacing: 5) {
                                Circle().fill(item.color).frame(width: 8, height: 8)
                                Text(item.title).lineLimit(1)
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(UM.fg2)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().fill(UM.field))
                            .help(item.sourceTitle)
                        }
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }
                if let error = calendar.lastError {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(UM.badFg)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }
        }
    }

    // MARK: AI

    private var connectionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                ForEach(ai.connections) { connection in
                    connectionRow(connection)
                    if connection.id != ai.connections.last?.id {
                        Rectangle().fill(UM.sep).frame(height: 0.5).padding(.leading, 34)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))

            Menu {
                ForEach(AIPreset.all) { preset in
                    Button(preset.name) {
                        let connection = ai.add(preset)
                        withAnimation(Motion.snappy) { selectedID = connection.id }
                    }
                }
            } label: {
                Label("Добавить модель", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12.5, weight: .medium))
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func connectionRow(_ connection: AIConnection) -> some View {
        let active = connection.id == ai.active?.id
        let selected = connection.id == (selectedID ?? ai.active?.id)
        return HStack(spacing: 10) {
            Button {
                ai.activate(connection.id)
            } label: {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(active ? UM.accent : UM.fg3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(active ? "Используется для сводок и черновиков" : "Использовать эту модель")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(connection.name).fontWeight(.medium).lineLimit(1)
                    if connection.isLocal {
                        Text("локально")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(UM.privFg)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule().fill(UM.privBg))
                    }
                }
                Text([connection.model.isEmpty ? "модель не выбрана" : connection.model,
                      URL(string: connection.baseURL)?.host ?? connection.baseURL].joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg3)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                withAnimation(Motion.snappy) {
                    ai.remove(connection.id)
                    if selectedID == connection.id { selectedID = ai.active?.id }
                }
            } label: {
                Image(systemName: "trash").font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(UM.fg3)
            .help("Удалить подключение")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? UM.accentSoft.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.snappy) { selectedID = connection.id } }
    }
}

/// Настройки одного подключения: адрес, ключ, модель (со списком с сервера), маскировка, проверка.
@MainActor
private struct AIConnectionEditor: View {
    @Binding var connection: AIConnection

    @State private var keyDraft = ""
    @State private var maskedKey: String?
    @State private var keyError: String?
    @State private var models: [String] = []
    @State private var modelsState: Phase = .idle
    @State private var test: Phase = .idle

    private enum Phase: Equatable { case idle, running, ok(String), failed(String) }

    private var ai: AIService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Название") {
                TextField("", text: $connection.name).umFieldStyle()
            }
            row("Протокол") {
                Picker("", selection: $connection.kind) {
                    ForEach(AIProtocol.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Адрес API") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $connection.baseURL, prompt: Text("http://gpu-server:8000/v1").foregroundColor(UM.fg3))
                        .umFieldStyle()
                        .font(UM.mono(12))
                    Text(connection.kind == .anthropic
                         ? "Обычно https://api.anthropic.com."
                         : "Базовый адрес с /v1: vLLM — http://сервер:8000/v1, Ollama — http://localhost:11434/v1.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(UM.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            row("API-ключ") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        SecureField("", text: $keyDraft, prompt: Text(connection.isLocal ? "необязательно" : "ключ").foregroundColor(UM.fg3))
                            .umFieldStyle()
                            .onSubmit(saveKey)
                        Button("Сохранить", action: saveKey)
                            .buttonStyle(UMButtonStyle(kind: .secondary))
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(spacing: 6) {
                        if let maskedKey {
                            Image(systemName: "key.fill").font(.system(size: 10))
                            Text("В Связке ключей: \(maskedKey)")
                            Button("Удалить") {
                                try? ai.saveKey("", for: connection)
                                reloadKey()
                            }
                            .buttonStyle(.link)
                        } else {
                            Text(connection.isLocal ? "Для своего сервера без --api-key ключ не нужен." : "Ключ хранится только в Связке ключей этого Mac.")
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg3)
                    if let keyError {
                        Text(keyError).font(.system(size: 11.5)).foregroundStyle(UM.badFg)
                    }
                }
            }
            row("Модель") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("", text: $connection.model, prompt: Text("название модели").foregroundColor(UM.fg3))
                            .umFieldStyle()
                            .font(UM.mono(12))
                        if models.isEmpty {
                            Button {
                                loadModels()
                            } label: {
                                if modelsState == .running { ProgressView().controlSize(.small) } else { Text("Загрузить список") }
                            }
                            .buttonStyle(UMButtonStyle(kind: .secondary))
                            .disabled(modelsState == .running)
                        } else {
                            Menu("Выбрать") {
                                ForEach(models, id: \.self) { id in
                                    Button(id) { connection.model = id }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    if case .failed(let text) = modelsState {
                        Text(text).font(.system(size: 11.5)).foregroundStyle(UM.badFg).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            row("") {
                Toggle("Маскировать адреса и телефоны", isOn: $connection.redact)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            row("") {
                HStack(spacing: 10) {
                    Button("Проверить", action: runTest)
                        .buttonStyle(UMButtonStyle(kind: .secondary))
                        .disabled(test == .running || connection.model.isEmpty)
                    if ai.active?.id != connection.id {
                        Button("Использовать эту модель") { ai.activate(connection.id) }
                            .buttonStyle(UMButtonStyle(kind: .primary))
                    }
                    testStatus
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(UM.privFg)
                Text(privacyText).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(UM.fg2)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .umInset(radius: 10)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UM.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
        .onAppear(perform: reloadKey)
        .onChange(of: connection.baseURL) { models = []; modelsState = .idle }
    }

    private var privacyText: String {
        let where_ = connection.isLocal ? "на ваш сервер (\(URL(string: connection.baseURL)?.host ?? ""))" : "в \(connection.name)"
        let masking = connection.redact ? "Адреса почты и номера телефонов перед отправкой заменяются на [email] и [телефон]. " : "Текст уходит без маскировки. "
        return masking + "Письма уходят \(where_) только по вашей кнопке."
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(UM.fg2)
                .frame(width: 78, alignment: .trailing)
            content()
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .ok(let text):
            StatusPill(text, tone: .ok)
        case .failed(let text):
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(UM.badFg)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reloadKey() {
        maskedKey = ai.maskedKey(for: connection)
    }

    private func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try ai.saveKey(value, for: connection)
            keyDraft = ""
            keyError = nil
            test = .idle
        } catch {
            keyError = "Не удалось сохранить ключ в Связке ключей: \(error.localizedDescription)"
        }
        reloadKey()
    }

    private func loadModels() {
        modelsState = .running
        let current = connection
        Task {
            do {
                models = try await ai.listModels(current)
                modelsState = .idle
                if connection.model.isEmpty, let first = models.first { connection.model = first }
            } catch {
                modelsState = .failed(error.localizedDescription)
            }
        }
    }

    private func runTest() {
        test = .running
        let current = connection
        Task {
            do {
                _ = try await ai.testConnection(current)
                test = .ok("Работает · \(current.model)")
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}
