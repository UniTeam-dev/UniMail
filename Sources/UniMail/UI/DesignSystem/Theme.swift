import AppKit
import SwiftUI

// MARK: - Цвет

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: CGFloat(alpha)))
    }

    /// Цвет, который сам переключается между светлой и тёмной темой.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Токены из макета «UniMail — Макеты · Дизайн-система».
enum UM {
    private static let black = { (a: CGFloat) in NSColor.rgba(0, 0, 0, a) }
    private static let white = { (a: CGFloat) in NSColor.rgba(255, 255, 255, a) }

    // Фоны
    static let win = Color.dynamic(NSColor(hex: 0xFFFFFF), NSColor(hex: 0x1C1C1F))
    static let list = Color.dynamic(NSColor(hex: 0xF9F9FA), NSColor(hex: 0x202024))
    static let side = Color.dynamic(.rgba(240, 240, 243, 0.86), .rgba(40, 40, 46, 0.86))
    static let rail = Color.dynamic(.rgba(229, 229, 234, 0.7), .rgba(28, 28, 33, 0.7))
    static let railSolid = Color.dynamic(NSColor(hex: 0xE6E6EB), NSColor(hex: 0x26262B))
    static let card = Color.dynamic(NSColor(hex: 0xFFFFFF), NSColor(hex: 0x27272C))
    static let cardHover = Color.dynamic(NSColor(hex: 0xFAFAFB), NSColor(hex: 0x2B2B31))
    static let inset = Color.dynamic(NSColor(hex: 0xF6F6F8), NSColor(hex: 0x212125))
    /// Фон окон настроек и мастера.
    static let sheet = Color.dynamic(NSColor(hex: 0xF4F4F7), NSColor(hex: 0x1E1E22))
    static let sheetBar = Color.dynamic(NSColor(hex: 0xECECF0), NSColor(hex: 0x26262B))
    static let dim = Color.dynamic(NSColor(hex: 0xDADADF), NSColor(hex: 0x44444B))

    // Текст
    static let fg = Color.dynamic(NSColor(hex: 0x1C1C1F), NSColor(hex: 0xF1F1F4))
    static let fg2 = Color.dynamic(NSColor(hex: 0x5C5C66), NSColor(hex: 0xABABB5))
    static let fg3 = Color.dynamic(NSColor(hex: 0x8E8E98), NSColor(hex: 0x767680))

    // Линии и заливки
    static let sep = Color.dynamic(black(0.07), white(0.07))
    static let sepStrong = Color.dynamic(black(0.11), white(0.11))
    static let tbSep = Color.dynamic(black(0.05), white(0.05))
    static let hover = Color.dynamic(black(0.045), white(0.055))
    static let press = Color.dynamic(black(0.08), white(0.1))
    static let selSide = Color.dynamic(black(0.07), white(0.09))
    static let cardBorder = Color.dynamic(black(0.08), white(0.07))
    static let field = Color.dynamic(black(0.05), white(0.065))
    static let seg = Color.dynamic(black(0.055), white(0.07))
    static let segThumb = Color.dynamic(NSColor(hex: 0xFFFFFF), white(0.15))
    static let menu = Color.dynamic(.rgba(250, 250, 252, 0.92), .rgba(46, 46, 52, 0.92))
    static let scrim = Color.dynamic(.rgba(24, 24, 32, 0.26), black(0.45))

    // Акцент
    static let accentNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x5B84FF) : NSColor(hex: 0x3D6AF2)
    }
    static let accent = Color(nsColor: accentNS)
    static let accentSoft = Color.dynamic(.rgba(61, 106, 242, 0.12), .rgba(91, 132, 255, 0.18))
    static let selRow = Color.dynamic(.rgba(61, 106, 242, 0.11), .rgba(91, 132, 255, 0.18))

    // Статусы
    static let privBg = Color.dynamic(.rgba(51, 189, 115, 0.11), .rgba(51, 189, 115, 0.14))
    static let privFg = Color.dynamic(NSColor(hex: 0x16714A), NSColor(hex: 0x62D69D))
    static let privBtn = Color.dynamic(.rgba(51, 189, 115, 0.16), .rgba(51, 189, 115, 0.2))
    static let warnBg = Color.dynamic(.rgba(250, 140, 51, 0.12), .rgba(250, 140, 51, 0.16))
    static let warnFg = Color.dynamic(NSColor(hex: 0xB35A12), NSColor(hex: 0xFFB067))
    static let bad = Color.dynamic(.rgba(240, 69, 69, 0.12), .rgba(240, 69, 69, 0.2))
    static let badFg = Color.dynamic(NSColor(hex: 0xD12F2F), NSColor(hex: 0xFF7A7A))

    // Фиксированные цвета
    static let red = Color(hex: 0xF04545)
    static let orange = Color(hex: 0xFA8C33)
    static let green = Color(hex: 0x33BD73)
    static let teal = Color(hex: 0x14B8BF)
    static let purple = Color(hex: 0x8C5CF5)
    static let blue = Color(hex: 0x3B82F6)

    /// Градиент плитки «Все ящики».
    static let allBoxesGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x5C59E6), location: 0),
            .init(color: Color(hex: 0x3B82F6), location: 0.45),
            .init(color: Color(hex: 0x14B8BF), location: 1),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Моноширинный шрифт (коды, серверы).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension AccountTint {
    var hex: UInt32 {
        switch self {
        case .blue: 0x3B82F6
        case .orange: 0xFA8C33
        case .purple: 0x8C5CF5
        case .pink: 0xED4A99
        case .green: 0x33BD73
        case .teal: 0x14B8BF
        case .indigo: 0x5C59E6
        case .red: 0xF04545
        }
    }

    var color: Color { Color(hex: hex) }

    /// Тинт чипа: 13% в светлой теме, 22% в тёмной.
    var tint: Color {
        Color.dynamic(NSColor(hex: hex, alpha: 0.13), NSColor(hex: hex, alpha: 0.22))
    }
}

extension Attachment.Kind {
    var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .design: "paintbrush.pointed.fill"
        case .image: "photo.fill"
        case .table: "tablecells.fill"
        case .slides: "play.rectangle.fill"
        case .archive: "doc.zipper"
        case .document: "doc.text.fill"
        }
    }

    var hex: UInt32 {
        switch self {
        case .pdf: 0xF04545
        case .design: 0x8C5CF5
        case .image, .table: 0x33BD73
        case .slides: 0xFA8C33
        case .archive: 0x8E8E98
        case .document: 0x3B82F6
        }
    }

    var color: Color { Color(hex: hex) }
    /// Плитка иконки: 14% / 24%.
    var tileBackground: Color {
        Color.dynamic(NSColor(hex: hex, alpha: 0.14), NSColor(hex: hex, alpha: 0.24))
    }
}

// MARK: - Аватары: OKLCH, как в макете

enum OKLCH {
    /// oklch(L C h) → sRGB.
    static func nsColor(_ l: Double, _ c: Double, _ hDegrees: Double) -> NSColor {
        let h = hDegrees * .pi / 180
        let a = c * cos(h), b = c * sin(h)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func gamma(_ x: Double) -> CGFloat {
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return CGFloat(min(max(v, 0), 1))
        }
        return NSColor(srgbRed: gamma(r), green: gamma(g), blue: gamma(bl), alpha: 1)
    }
}

enum AvatarPalette {
    /// Оттенок 0…360 из адреса — стабилен между запусками.
    static func hue(for email: String) -> Double {
        let hash = email.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Double(hash % 360)
    }

    static func background(for email: String) -> Color {
        let h = hue(for: email)
        return .dynamic(OKLCH.nsColor(0.91, 0.05, h), OKLCH.nsColor(0.36, 0.07, h))
    }

    static func foreground(for email: String) -> Color {
        let h = hue(for: email)
        return .dynamic(OKLCH.nsColor(0.42, 0.11, h), OKLCH.nsColor(0.9, 0.07, h))
    }

    /// Свои письма — нейтральный серый.
    static let meBackground = Color.dynamic(NSColor(hex: 0xE6E6EC), NSColor(hex: 0x3A3A42))
    static let meForeground = Color.dynamic(NSColor(hex: 0x555555), NSColor(hex: 0xDDDDDD))
}

// MARK: - Движение (раскадровка «Motion»)

enum Motion {
    /// Системное «Уменьшить движение» или переключатель в настройках приложения.
    static var reduce: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "reduceMotion")
    }

    private static let fade = Animation.easeInOut(duration: 0.15)

    /// 01 · Подложка аккаунта: spring(response .30, damping .72).
    static var rail: Animation { reduce ? fade : .spring(response: 0.30, dampingFraction: 0.72) }
    /// 02 · Выбор папки и сегмента: spring(response .32, damping .78).
    static var snappy: Animation { reduce ? fade : .spring(response: 0.32, dampingFraction: 0.78) }
    /// Смена содержимого: opacity + y 10, 300–380 мс (.2,.8,.2,1).
    static var smooth: Animation { reduce ? fade : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.38) }
    /// 03 · Строки списка: вход — spring .35, уход — 200 мс + смыкание 320 мс.
    static var list: Animation { reduce ? fade : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32) }
    /// 04 · Флажок, бейджи: spring(response .25, damping .5).
    static var bouncy: Animation { reduce ? fade : .spring(response: 0.25, dampingFraction: 0.5) }
    /// 05 · Отпускание кнопки тулбара: spring(response .28, damping .55).
    static var release: Animation { reduce ? fade : .spring(response: 0.28, dampingFraction: 0.55) }
    static var press: Animation { reduce ? fade : .easeOut(duration: 0.08) }
    /// 06 · Палитра: spring(response .32, damping .82); закрытие 150 мс ease-in.
    static var paletteIn: Animation { reduce ? fade : .spring(response: 0.32, dampingFraction: 0.82) }
    static var paletteOut: Animation { reduce ? fade : .easeIn(duration: 0.15) }
    /// 07 · Тост: spring(response .35, damping .8); уход 200 мс.
    static var toastIn: Animation { reduce ? fade : .spring(response: 0.35, dampingFraction: 0.8) }
    static var toastOut: Animation { reduce ? fade : .easeIn(duration: 0.2) }
    /// Всплывающие меню: .2 ease + transform .32 (.3,1.3,.6,1).
    static var pop: Animation { reduce ? fade : .spring(response: 0.3, dampingFraction: 0.72) }

    /// Строка уходит влево на 60 pt с затуханием, приходит сверху на 8 pt.
    static var rowTransition: AnyTransition {
        reduce ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)),
            removal: .opacity.combined(with: .offset(x: -60))
        )
    }

    /// Содержимое колонки при переключении ящика: opacity + y 10.
    static var contentTransition: AnyTransition {
        reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity)
    }

    /// Всплывающая панель: scale .96 от верхнего края.
    static var popTransition: AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)).combined(with: .offset(y: -6))
    }
}

// MARK: - Тени и поверхности

struct CardShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var small = false

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        if small {
            content.shadow(color: .black.opacity(dark ? 0.3 : 0.04), radius: 1, y: 1)
        } else {
            content
                .shadow(color: .black.opacity(dark ? 0.3 : 0.04), radius: 1, y: 1)
                .shadow(color: dark ? .black.opacity(0.22) : Color(red: 20 / 255, green: 20 / 255, blue: 40 / 255).opacity(0.05),
                        radius: dark ? 12 : 10, y: dark ? 8 : 6)
        }
    }
}

struct MenuShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.13) : Color.black.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.55 : 0.18), radius: dark ? 30 : 25, y: dark ? 24 : 20)
    }
}

extension View {
    /// Карточка письма: фон, тонкая рамка, двойная тень.
    func umCard(radius: CGFloat = 14, small: Bool = false, fill: Color = UM.card) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
            .modifier(CardShadow(small: small))
    }

    /// Плашка внутри карточки (приглашение, код, вложение).
    func umInset(radius: CGFloat = 12) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(UM.inset))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
    }

    /// Материал меню, палитры и тоста: полупрозрачный фон + размытие + тень.
    func umMenuSurface(radius: CGFloat = 12) -> some View {
        background(
            ZStack {
                VisualEffect(material: .popover, blending: .withinWindow)
                UM.menu
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        )
        .modifier(MenuShadow(radius: radius))
    }

    /// Пиксельная линия 0.5 pt.
    func hairline(_ edge: Edge, color: Color = UM.sep) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle().fill(color)
                .frame(width: edge.isHorizontal ? nil : 0.5, height: edge.isHorizontal ? 0.5 : nil)
        }
    }
}

private extension Edge {
    var isHorizontal: Bool { self == .top || self == .bottom }
    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

/// NSVisualEffectView для вибрантных фонов (сайдбар, меню).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: - Настройки отображения

/// Плотность списка писем (Настройки → Внешний вид).
enum ListDensity: String, CaseIterable, Identifiable {
    case compact, comfortable, spacious
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Компактная"
        case .comfortable: "Обычная"
        case .spacious: "Просторная"
        }
    }

    /// Отступы строки (верх, низ, право), размер аватара и шрифта — из макета.
    var padding: EdgeInsets {
        switch self {
        case .compact: EdgeInsets(top: 7, leading: 6, bottom: 7, trailing: 12)
        case .comfortable: EdgeInsets(top: 10, leading: 6, bottom: 11, trailing: 12)
        case .spacious: EdgeInsets(top: 14, leading: 6, bottom: 15, trailing: 14)
        }
    }
    var avatar: CGFloat {
        switch self {
        case .compact: 24
        case .comfortable: 32
        case .spacious: 38
        }
    }
    var avatarFont: CGFloat {
        switch self {
        case .compact: 10
        case .comfortable: 12
        case .spacious: 13.5
        }
    }
    var subjectSize: CGFloat {
        switch self {
        case .compact: 12.5
        case .comfortable: 13
        case .spacious: 13.5
        }
    }
    var subjectTop: CGFloat {
        switch self {
        case .compact: 1
        case .comfortable: 2
        case .spacious: 4
        }
    }
    var showsPreview: Bool { self != .compact }
}

/// Тема приложения (Настройки → Внешний вид).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, auto
    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Светлая"
        case .dark: "Тёмная"
        case .auto: "Как в системе"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .auto: NSApp.appearance = nil
        }
    }
}

// MARK: - Даты по-русски

enum RelativeDate {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = format
        return f
    }

    private static let time = formatter("HH:mm")
    private static let weekday = formatter("EE")
    private static let dayMonth = formatter("d MMM")
    private static let dayMonthFull = formatter("d MMMM")
    private static let weekdayTime = formatter("EE, HH:mm")
    private static let weekdayDayMonthTime = formatter("EE, d MMM, HH:mm")
    private static let dayMonthTime = formatter("d MMM, HH:mm")
    private static let longDay = formatter("EEEE, d MMMM")
    private static let monthYear = formatter("LLLL yyyy")
    private static let upperDay = formatter("EEEE, d MMMM")
    private static let shortMonth = formatter("LLL")

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// Время в строке списка: 12:24 · Вчера · Пн · 25 сент.
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Вчера" }
        if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7, date < .now {
            return capitalized(weekday.string(from: date))
        }
        return dayMonth.string(from: date)
    }

    /// Время в карточке письма: «Сегодня, 12:24», «Вчера, 18:10», «25 сент., 14:02».
    static func long(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня, " + time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Вчера, " + time.string(from: date) }
        if cal.isDateInTomorrow(date) { return "Завтра, " + time.string(from: date) }
        return dayMonthTime.string(from: date)
    }

    /// Подпись пресета «Отложить»: «15:40», «Ср, 08:00», «Сб, 3 окт., 09:00».
    static func preset(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInTomorrow(date) { return capitalized(weekdayTime.string(from: date)) }
        return capitalized(weekdayDayMonthTime.string(from: date))
    }

    static func clock(_ date: Date) -> String { time.string(from: date) }
    static func dayTitle(_ date: Date) -> String { capitalized(longDay.string(from: date)) }
    static func agendaHeader(_ date: Date) -> String { upperDay.string(from: date).uppercased() }
    static func monthTitle(_ date: Date) -> String { capitalized(monthYear.string(from: date)) }
    static func monthShortUpper(_ date: Date) -> String {
        shortMonth.string(from: date).replacingOccurrences(of: ".", with: "").uppercased()
    }
    static func dayMonthShort(_ date: Date) -> String { dayMonth.string(from: date) }
    /// «Пн», «Вт»…
    static func weekdayShort(_ date: Date) -> String { capitalized(weekday.string(from: date)).replacingOccurrences(of: ".", with: "") }
    /// «29 сентября»
    static func dayMonthLong(_ date: Date) -> String { dayMonthFull.string(from: date) }
}
