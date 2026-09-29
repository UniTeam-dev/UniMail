import AppKit
import SwiftUI

// MARK: - Аватары и плитки

/// Круглый аватар отправителя с инициалами (OKLCH-пастель из макета).
struct SenderAvatar: View {
    let address: Address
    var size: CGFloat = 32
    var fontSize: CGFloat? = nil
    var isMe = false

    var body: some View {
        Circle()
            .fill(isMe ? AvatarPalette.meBackground : AvatarPalette.background(for: address.email))
            .overlay {
                Text(String(address.initials.prefix(2)))
                    .font(.system(size: fontSize ?? size * 0.375, weight: .semibold))
                    .foregroundStyle(isMe ? AvatarPalette.meForeground : AvatarPalette.foreground(for: address.email))
            }
            .frame(width: size, height: size)
    }
}

/// Плитка аккаунта: скруглённый квадрат цвета аккаунта с буквой.
struct AccountTile: View {
    let account: Account
    var size: CGFloat = 40
    var radius: CGFloat = 12
    var fontSize: CGFloat = 15

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(account.tint.color)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .overlay {
                Text(account.initial)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }
}

/// Плитка «Все ящики» с градиентом.
struct AllBoxesTile: View {
    var size: CGFloat = 40
    var radius: CGFloat = 12
    var symbolSize: CGFloat = 19

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(UM.allBoxesGradient)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .overlay {
                Image(systemName: "tray.2.fill")
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: Color(red: 59 / 255, green: 90 / 255, blue: 230 / 255).opacity(0.3), radius: 3, y: 2)
    }
}

// MARK: - Счётчики и чипы

/// Пилюля-счётчик 18 pt: акцентная (непрочитанные во «Входящих») или серая.
struct CountPill: View {
    let count: Int
    var prominent = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .foregroundStyle(prominent ? Color.white : UM.fg2)
            .background(Capsule().fill(prominent ? UM.accent : UM.seg))
    }
}

/// Красный бейдж на плитке аккаунта с обводкой цвета панели.
struct RailBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(UM.red))
            .overlay(Capsule().strokeBorder(UM.railSolid, lineWidth: 2).padding(-2))
    }
}

/// Чип аккаунта в заголовке треда: тинт цвета аккаунта + квадратик.
struct AccountChip: View {
    let account: Account

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(account.tint.color).frame(width: 8, height: 8)
            Text(account.displayName)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(UM.fg)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(Capsule().fill(account.tint.tint))
    }
}

/// Серый информационный чип (число писем в треде, «Рассылка»).
struct InfoChip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 5, content: content)
            .font(.system(size: 12))
            .foregroundStyle(UM.fg2)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(UM.field))
    }
}

/// Клавиша на карточке горячих клавиш.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(UM.fg)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(UM.inset))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(UM.sepStrong).offset(y: 1))
    }
}

/// Маленькая подсказка клавиши (R, esc, ⌘N).
struct KeyHint: View {
    let text: String
    var inverted = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(inverted ? Color.white : UM.fg3)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(inverted ? Color.white.opacity(0.2) : UM.seg))
    }
}

/// Подпись секции: 11 / 650 / fg3, высота 32 с прижатием к низу.
struct SectionLabel: View {
    let text: String
    var leading: CGFloat = 9

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(UM.fg3)
            .padding(.leading, leading)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .bottomLeading)
    }
}

// MARK: - Переключатели

/// Маленький тумблер из макета (26×16, 28×17, 30×18).
struct MiniSwitch: View {
    let isOn: Bool
    var width: CGFloat = 28
    var height: CGFloat = 17

    var body: some View {
        let knob = height - 4
        Capsule()
            .fill(isOn ? UM.accent : UM.sepStrong)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .offset(x: 2 + (isOn ? width - knob - 4 : 0))
            }
            .animation(Motion.bouncy, value: isOn)
    }
}

/// Радиокнопка 16 pt.
struct RadioDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? UM.accent : UM.fg3, lineWidth: isOn ? 5 : 1)
            .background(Circle().fill(isOn ? Color.white : .clear).padding(4))
            .frame(width: 16, height: 16)
            .animation(Motion.snappy, value: isOn)
    }
}

/// Сегментированный переключатель с «бегунком», который переезжает к выбранному пункту.
struct SlidingSegments<Value: Hashable>: View {
    struct Item: Identifiable {
        var value: Value
        var title: String
        var symbol: String? = nil
        var id: Value { value }
    }

    let items: [Item]
    @Binding var selection: Value
    var equalWidth = false
    var fontSize: CGFloat = 12
    var height: CGFloat = 24
    var horizontalPadding: CGFloat = 10

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let on = item.value == selection
                Button {
                    withAnimation(Motion.snappy) { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = item.symbol {
                            Image(systemName: symbol).font(.system(size: 13))
                        }
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: fontSize, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? UM.fg : UM.fg2)
                    .padding(.horizontal, equalWidth ? 4 : horizontalPadding)
                    .frame(maxWidth: equalWidth ? .infinity : nil)
                    .frame(height: height)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(UM.segThumb)
                                .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UM.seg))
    }
}

// MARK: - Кнопки

/// Кнопка-иконка тулбара: hover — мгновенная подсветка, нажатие — scale .84, отпускание — пружина.
struct ToolbarIconStyle: ButtonStyle {
    var width: CGFloat = 32
    var height: CGFloat = 28
    var radius: CGFloat = 8
    var tint: Color? = nil
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, width: width, height: height, radius: radius, tint: tint, active: active)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let width: CGFloat
        let height: CGFloat
        let radius: CGFloat
        let tint: Color?
        let active: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 15))
                .foregroundStyle(tint ?? (hovering || active ? UM.fg : UM.fg2))
                .frame(minWidth: width, minHeight: height)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(active ? UM.press : (hovering ? UM.hover : .clear)))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.84 : 1)
                .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Кнопка с подсветкой при наведении (строки меню, чипы).
struct HoverStyle: ButtonStyle {
    var radius: CGFloat = 8
    var pressScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, radius: radius, pressScale: pressScale)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        let pressScale: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hovering ? UM.hover : .clear))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? pressScale : 1)
                .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Основная (акцентная) и вторичная (серая) кнопки из макета.
struct UMButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, custom(Color, Color) }
    var kind: Kind = .primary
    var height: CGFloat = 28
    var radius: CGFloat = 8
    var horizontal: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        let colors: (Color, Color) = {
            switch kind {
            case .primary: return (UM.accent, .white)
            case .secondary: return (UM.field, UM.fg)
            case .custom(let bg, let fg): return (bg, fg)
            }
        }()
        return configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(colors.1)
            .padding(.horizontal, horizontal)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(colors.0))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.release, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

// MARK: - Меню

/// Строка всплывающего меню: при наведении заливается акцентом.
struct MenuRow: View {
    let symbol: String?
    let title: String
    var detail: String? = nil
    var trailingSymbol: String? = nil
    var highlighted = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        let on = hovering || highlighted
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.system(size: 12)).monospacedDigit().opacity(0.6)
                }
                if let trailingSymbol {
                    Image(systemName: trailingSymbol).font(.system(size: 12, weight: .semibold))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(on ? Color.white : UM.fg)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? UM.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuSeparator: View {
    var body: some View {
        Rectangle().fill(UM.sepStrong).frame(height: 0.5).padding(.horizontal, 8).padding(.vertical, 5)
    }
}

// MARK: - Мини-календарь

/// Сетка месяца: понедельник первый, соседние месяцы серые, сегодня — акцентный кружок.
struct MonthGrid: View {
    let month: Date
    var selected: Date? = nil
    var busyDays: Set<Int> = []
    var cellHeight: CGFloat = 24
    var circle: CGFloat = 22
    var fontSize: CGFloat = 11
    var disablePast = false
    /// Дни соседних месяцев тоже выбираются (мини-календарь «Расписания»).
    var selectsOutside = false
    var onSelect: ((Date) -> Void)? = nil

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.locale = Locale(identifier: "ru_RU")
        return cal
    }

    private struct Cell: Identifiable {
        var id: Int
        var date: Date
        var inMonth: Bool
    }

    private var cells: [Cell] {
        let cal = calendar
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let weekday = cal.component(.weekday, from: first)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let total = Int(ceil(Double(lead + days) / 7)) * 7
        return (0..<total).compactMap { i in
            guard let date = cal.date(byAdding: .day, value: i - lead, to: first) else { return nil }
            return Cell(id: i, date: date, inMonth: i >= lead && i < lead + days)
        }
    }

    var body: some View {
        let cal = calendar
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { day in
                Text(day)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UM.fg3)
                    .padding(.bottom, 4)
            }
            ForEach(cells) { cell in
                let day = cal.component(.day, from: cell.date)
                let today = cal.isDateInToday(cell.date)
                let isSelected = selected.map { cal.isDate($0, inSameDayAs: cell.date) } ?? false
                let past = cell.date < cal.startOfDay(for: .now)
                let fg: Color = isSelected || (today && selected == nil) ? .white
                    : (!cell.inMonth || (disablePast && past) ? UM.fg3 : UM.fg)
                let bg: Color = isSelected || (today && selected == nil) ? UM.accent : .clear
                Button {
                    if (cell.inMonth || selectsOutside) && !(disablePast && past) { onSelect?(cell.date) }
                } label: {
                    ZStack(alignment: .bottom) {
                        Text("\(day)")
                            .font(.system(size: fontSize, weight: today || isSelected ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(fg)
                            .frame(width: circle, height: circle)
                            .background(Circle().fill(bg))
                            .overlay(Circle().strokeBorder(today && selected != nil && !isSelected ? UM.accent : .clear, lineWidth: 1))
                            .frame(maxWidth: .infinity, minHeight: cellHeight)
                        if cell.inMonth && !today && busyDays.contains(day) {
                            Circle().fill(UM.fg3).frame(width: 3, height: 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onSelect == nil)
            }
        }
    }
}

// MARK: - Раскладка

/// Раскладка «в строку с переносом» — для адресов-токенов и вложений.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Вложение

struct AttachmentChip: View {
    let attachment: Attachment
    var removable = false
    var onRemove: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: attachment.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(attachment.kind.color)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(attachment.kind.tileBackground))
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(UM.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200, alignment: .leading)
                Text(attachment.sizeText).font(.system(size: 11)).foregroundStyle(UM.fg3)
            }
            if removable {
                Button { onRemove?() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(UM.fg3)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, removable ? 8 : 12)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? UM.hover : UM.inset))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
        .onHover { hovering = $0 }
    }
}

// MARK: - Пресеты времени

/// Пресеты «Отложить» и «Отправить позже».
enum TimePreset: CaseIterable, Identifiable {
    case laterToday, tonight, tomorrowMorning, weekend, nextWeek

    var id: Self { self }

    var title: String {
        switch self {
        case .laterToday: "Через 3 часа"
        case .tonight: "Сегодня вечером"
        case .tomorrowMorning: "Завтра утром"
        case .weekend: "В выходные"
        case .nextWeek: "На следующей неделе"
        }
    }

    var symbol: String {
        switch self {
        case .laterToday: "hourglass"
        case .tonight: "sunset"
        case .tomorrowMorning: "sun.max"
        case .weekend: "sofa"
        case .nextWeek: "calendar"
        }
    }

    var date: Date {
        let cal = Calendar.current
        let now = Date.now
        func at(_ hour: Int, daysAhead: Int) -> Date {
            let day = cal.date(byAdding: .day, value: daysAhead, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        switch self {
        case .laterToday:
            return now.addingTimeInterval(3 * 3600)
        case .tonight:
            let evening = at(19, daysAhead: 0)
            return evening > now ? evening : at(19, daysAhead: 1)
        case .tomorrowMorning:
            return at(8, daysAhead: 1)
        case .weekend:
            let weekday = cal.component(.weekday, from: now) // 1 = Вс, 7 = Сб
            let ahead = weekday == 7 ? 7 : (7 - weekday)
            return at(9, daysAhead: max(ahead, 1))
        case .nextWeek:
            let weekday = cal.component(.weekday, from: now)
            let ahead = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
            return at(8, daysAhead: ahead)
        }
    }

    /// «15:40», «Ср, 08:00», «Сб, 3 окт., 09:00».
    var subtitle: String { RelativeDate.preset(date) }
}
