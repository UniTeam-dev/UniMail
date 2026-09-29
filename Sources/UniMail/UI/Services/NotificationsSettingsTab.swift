import AppKit
import SwiftUI
import UserNotifications

/// Настройки → Уведомления: баннеры, рассылки, бейдж Dock, строка меню, автозапуск.
@MainActor
struct NotificationsSettingsTab: View {
    @AppStorage(AppSettings.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(AppSettings.notifyNewsletters) private var notifyNewsletters = false
    @AppStorage(AppSettings.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(AppSettings.showDockBadge) private var showDockBadge = true
    @AppStorage(AppSettings.startHidden) private var startHidden = false

    @State private var authorization: UNAuthorizationStatus?

    private var launch: LaunchAtLoginService { .shared }
    private var notifications: NotificationService { .shared }

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 24) {
                GridRow(alignment: .top) {
                    SettingsRowLabel("Новые письма").padding(.top, 1)
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSwitchRow("Показывать уведомления",
                                          subtitle: "С кнопками «Архив», «Прочитано» и «Ответить»",
                                          isOn: $notificationsEnabled)
                        SettingsSwitchRow("Уведомлять о рассылках",
                                          subtitle: "Письма из категории «Рассылки»",
                                          isOn: $notifyNewsletters)
                            .disabled(!notificationsEnabled)
                        authorizationRow
                    }
                }

                GridRow(alignment: .top) {
                    SettingsRowLabel("Непрочитанные").padding(.top, 1)
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSwitchRow("Число на иконке в Dock", isOn: $showDockBadge)
                        SettingsSwitchRow("Иконка в строке меню",
                                          subtitle: "Последние непрочитанные и быстрые действия",
                                          isOn: $showMenuBarExtra)
                    }
                }

                GridRow(alignment: .top) {
                    SettingsRowLabel("Запуск").padding(.top, 1)
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSwitchRow("Открывать при входе в систему", isOn: Binding(
                            get: { launch.isEnabled },
                            set: { launch.setEnabled($0) }
                        ))
                        SettingsSwitchRow("Запускать без окна",
                                          subtitle: "При входе в систему UniMail проверяет почту в фоне; окно откроется по клику на иконку",
                                          isOn: $startHidden)
                            .disabled(!launch.isEnabled)
                        launchStatusRow
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            launch.refresh()
            authorization = await notifications.authorizationStatus()
        }
        .onChange(of: notificationsEnabled) { _, enabled in
            if enabled {
                Task {
                    if await notifications.authorizationStatus() == .notDetermined {
                        await notifications.requestAuthorization()
                    }
                    authorization = await notifications.authorizationStatus()
                }
            } else {
                notifications.clearAllDelivered()
            }
        }
        .onChange(of: showDockBadge) { _, _ in
            AppServices.shared.refreshBadge()
        }
    }

    @ViewBuilder
    private var authorizationRow: some View {
        if !notifications.isAvailable {
            StatusPill("Недоступно: приложение запущено не из .app", tone: .neutral)
        } else if let authorization {
            if authorization == .denied {
                HStack(spacing: 10) {
                    StatusPill("Запрещены в системе", tone: .bad)
                    Button("Открыть Системные настройки") { notifications.openSystemSettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            } else if authorization == .notDetermined {
                HStack(spacing: 10) {
                    StatusPill("Разрешение не запрошено", tone: .warn)
                    Button("Разрешить") {
                        Task {
                            await notifications.requestAuthorization()
                            self.authorization = await notifications.authorizationStatus()
                        }
                    }
                    .buttonStyle(UMButtonStyle(kind: .secondary, height: 24, radius: 7, horizontal: 10))
                }
            } else {
                StatusPill("Разрешены в системе", tone: .ok)
            }
        }
    }

    @ViewBuilder
    private var launchStatusRow: some View {
        if launch.requiresApproval {
            HStack(spacing: 10) {
                StatusPill("Нужно подтвердить в Системных настройках", tone: .warn)
                Button("Объекты входа…") { launch.openLoginItemsSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        if let error = launch.lastError {
            Text(error)
                .font(.system(size: 11.5))
                .foregroundStyle(UM.badFg)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)
        }
    }
}
