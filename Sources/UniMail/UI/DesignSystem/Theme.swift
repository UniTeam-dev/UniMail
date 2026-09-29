import AppKit
import SwiftUI

/// Анимации приложения. Если включено «Уменьшить движение» — короткие затухания вместо пружин.
@MainActor
enum Motion {
    private static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Переключение аккаунтов и папок.
    static var snappy: Animation { reduce ? .easeInOut(duration: 0.12) : .snappy(duration: 0.28, extraBounce: 0.04) }
    /// Вставка и удаление строк списка.
    static var list: Animation { reduce ? .easeInOut(duration: 0.12) : .spring(duration: 0.38, bounce: 0.18) }
    /// Флажки, бейджи, тосты.
    static var bouncy: Animation { reduce ? .easeInOut(duration: 0.12) : .bouncy(duration: 0.4, extraBounce: 0.12) }
    /// Появление панелей.
    static var smooth: Animation { reduce ? .easeInOut(duration: 0.12) : .smooth(duration: 0.32) }

    static var rowTransition: AnyTransition {
        reduce ? .opacity : .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

extension AccountTint {
    var color: Color {
        switch self {
        case .blue: Color(red: 0.23, green: 0.51, blue: 0.96)
        case .purple: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .pink: Color(red: 0.93, green: 0.29, blue: 0.60)
        case .orange: Color(red: 0.98, green: 0.55, blue: 0.20)
        case .green: Color(red: 0.20, green: 0.74, blue: 0.45)
        case .teal: Color(red: 0.08, green: 0.72, blue: 0.75)
        case .indigo: Color(red: 0.36, green: 0.35, blue: 0.90)
        case .red: Color(red: 0.94, green: 0.27, blue: 0.27)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [color.opacity(0.95), color.blended(with: .black, by: 0.18)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// Простое смешивание (Color.mix появился только в macOS 15).
    /// Названо не `mix`, чтобы не конфликтовать с `Color.mix(with:by:in:)` из SDK macOS 15.
    func blended(with other: Color, by amount: Double) -> Color {
        // Запасной цвет — обязательно в sRGB: у NSColor.gray (grayscale) redComponent бросает исключение.
        let fallback = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let a = NSColor(self).usingColorSpace(.sRGB) ?? fallback
        let b = NSColor(other).usingColorSpace(.sRGB) ?? fallback
        let t = CGFloat(amount)
        return Color(
            red: Double(a.redComponent * (1 - t) + b.redComponent * t),
            green: Double(a.greenComponent * (1 - t) + b.greenComponent * t),
            blue: Double(a.blueComponent * (1 - t) + b.blueComponent * t)
        )
    }
}

/// Детерминированный цвет аватара отправителя по его адресу.
enum AvatarPalette {
    static func color(for email: String) -> Color {
        let tints = AccountTint.allCases
        let hash = email.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return tints[hash % tints.count].color
    }
}

/// Плотность списка писем (Настройки → Внешний вид).
enum ListDensity: String, CaseIterable, Identifiable {
    case compact, comfortable, spacious
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Компактно"
        case .comfortable: "Обычно"
        case .spacious: "Просторно"
        }
    }
    var verticalPadding: CGFloat {
        switch self {
        case .compact: 6
        case .comfortable: 10
        case .spacious: 14
        }
    }
    var showsSnippet: Bool { self != .compact }
}

enum RelativeDate {
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) { return "Вчера" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func long(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().hour().minute())
    }
}
