import AppKit
import SwiftUI

/// Общие элементы вкладок настроек «Уведомления» и «Интеграции» — в стиле вкладки «Поведение».

/// Подпись слева в сетке настроек (выравнивание по правому краю).
struct SettingsRowLabel: View {
    let text: String
    var width: CGFloat = 150

    init(_ text: String, width: CGFloat = 150) {
        self.text = text
        self.width = width
    }

    var body: some View {
        Text(text)
            .foregroundStyle(UM.fg2)
            .frame(width: width, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

/// Строка с маленьким тумблером из макета и необязательной подписью.
struct SettingsSwitchRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                MiniSwitch(isOn: isOn, width: 30, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(UM.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Цветная пилюля состояния: разрешено / требует внимания / запрещено.
struct StatusPill: View {
    enum Tone { case ok, warn, bad, neutral }

    let text: String
    var tone: Tone = .neutral

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    private var colors: (Color, Color, String) {
        switch tone {
        case .ok: (UM.privBg, UM.privFg, "checkmark.circle.fill")
        case .warn: (UM.warnBg, UM.warnFg, "exclamationmark.circle.fill")
        case .bad: (UM.bad, UM.badFg, "xmark.octagon.fill")
        case .neutral: (UM.field, UM.fg2, "circle.dotted")
        }
    }

    var body: some View {
        let palette = colors
        HStack(spacing: 5) {
            Image(systemName: palette.2).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(palette.1)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(palette.0))
    }
}

extension View {
    /// Поле ввода настроек: карточный фон и тонкая рамка (как «Название» у аккаунта).
    func umFieldStyle(height: CGFloat = 28) -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.card))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
    }
}
