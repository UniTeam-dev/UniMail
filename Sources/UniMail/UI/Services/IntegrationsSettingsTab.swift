import AppKit
import SwiftUI

/// Настройки → Интеграции: доступ к Календарю и AI (Anthropic API на ключе пользователя).
@MainActor
struct IntegrationsSettingsTab: View {
    @AppStorage(AppSettings.aiEnabled) private var aiEnabled = false
    @AppStorage(AppSettings.aiModel) private var aiModel = AppSettings.defaultAIModel

    @State private var keyDraft = ""
    @State private var maskedKey: String?
    @State private var keyError: String?
    @State private var test: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

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
                                      subtitle: "Через Anthropic API на вашем ключе. Выключено — никакие данные не отправляются.",
                                      isOn: $aiEnabled)
                        .frame(maxWidth: 420, alignment: .leading)
                }

                GridRow(alignment: .top) {
                    SettingsRowLabel("API-ключ").padding(.top, 6)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SecureField("sk-ant-…", text: $keyDraft)
                                .umFieldStyle()
                                .frame(width: 260)
                                .onSubmit(saveKey)
                            Button("Сохранить", action: saveKey)
                                .buttonStyle(UMButtonStyle(kind: .primary))
                                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        HStack(spacing: 8) {
                            if let maskedKey {
                                Image(systemName: "key.fill").font(.system(size: 10))
                                Text("Сохранён в Связке ключей: \(maskedKey)")
                                Button("Удалить") {
                                    ai.removeAPIKey()
                                    reloadKey()
                                    test = .idle
                                }
                                .buttonStyle(.link)
                            } else {
                                Text("Ключ хранится только в Связке ключей этого Mac.")
                            }
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(UM.fg3)
                        if let keyError {
                            Text(keyError).font(.system(size: 11.5)).foregroundStyle(UM.badFg)
                        }
                    }
                }

                GridRow(alignment: .top) {
                    SettingsRowLabel("Модель").padding(.top, 6)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(AppSettings.defaultAIModel, text: $aiModel)
                            .umFieldStyle()
                            .font(UM.mono(12))
                            .frame(width: 260)
                        Text("Например, claude-sonnet-4-5 или claude-haiku-4-5.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(UM.fg3)
                    }
                }

                GridRow(alignment: .top) {
                    Color.clear.frame(width: 1, height: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button("Проверить подключение", action: runTest)
                                .buttonStyle(UMButtonStyle(kind: .secondary))
                                .disabled(maskedKey == nil || test == .running)
                            testStatus
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.shield").foregroundStyle(UM.privFg)
                            Text("Перед отправкой адреса почты и номера телефонов заменяются на [email] и [телефон]. Письма уходят в Anthropic только по вашей кнопке.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(UM.fg2)
                        .padding(10)
                        .frame(maxWidth: 420, alignment: .leading)
                        .umInset(radius: 10)
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
            reloadKey()
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
                .lineLimit(3)
                .frame(maxWidth: 260, alignment: .leading)
        }
    }

    private func reloadKey() {
        maskedKey = ai.maskedKey
    }

    private func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try ai.saveAPIKey(value)
            keyDraft = ""
            keyError = nil
            test = .idle
        } catch {
            keyError = "Не удалось сохранить ключ в Связке ключей: \(error.localizedDescription)"
        }
        reloadKey()
    }

    private func runTest() {
        test = .running
        Task {
            do {
                _ = try await ai.testConnection()
                test = .ok("Работает · \(ai.model)")
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}
