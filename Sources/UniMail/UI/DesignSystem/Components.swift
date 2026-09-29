import SwiftUI

/// Круглый аватар отправителя с инициалами.
struct SenderAvatar: View {
    let address: Address
    var size: CGFloat = 34

    var body: some View {
        let color = AvatarPalette.color(for: address.email)
        Circle()
            .fill(LinearGradient(colors: [color.opacity(0.9), color.blended(with: .black, by: 0.25)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Text(address.initials.isEmpty ? "?" : String(address.initials.prefix(2)))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.25), radius: 3, y: 1)
    }
}

/// Аватар аккаунта: скруглённый квадрат цвета аккаунта.
struct AccountAvatar: View {
    let account: Account
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(account.tint.gradient)
            .overlay {
                Text(account.initials.prefix(2))
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: account.tint.color.opacity(0.35), radius: 4, y: 2)
    }
}

/// Счётчик непрочитанных с анимацией смены числа.
struct CountBadge: View {
    let count: Int
    var tint: Color = .accentColor
    var prominent = true

    var body: some View {
        if count > 0 {
            Text(count > 999 ? "999+" : "\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(prominent ? .white : .secondary)
                .background(Capsule().fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary)))
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Маленькая цветная метка аккаунта (в едином ящике).
struct AccountChip: View {
    let account: Account

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(account.tint.color).frame(width: 6, height: 6)
            Text(account.displayName)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(account.tint.color.opacity(0.14)))
        .foregroundStyle(account.tint.color.blended(with: .primary, by: 0.35))
    }
}

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

/// Кнопка-иконка для тулбаров с «пружинкой» на нажатие.
struct BounceIconButton: View {
    let title: String
    let symbol: String
    var action: () -> Void
    @State var trigger = 0

    var body: some View {
        Button {
            trigger += 1
            action()
        } label: {
            Label(title, systemImage: symbol)
                .symbolEffect(.bounce, value: trigger)
        }
        .help(title)
    }
}

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
        case .laterToday: "clock"
        case .tonight: "moon"
        case .tomorrowMorning: "sunrise"
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

    var subtitle: String { date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()) }
}
