import SwiftUI

/// Месяц сеткой 7×N: в клетке — до нескольких встреч, «ещё N». Щелчок по дню — выбрать, двойной — открыть день.
@MainActor
struct ScheduleMonthView: View {
    @Environment(MailStore.self) private var store
    let interval: DateInterval
    let events: [CalendarEvent]
    let data: ScheduleData
    let actions: ScheduleActions


    private var calendar: Calendar { data.calendar }

    var body: some View {
        let days = data.days(in: interval)
        let rows = max(days.count / 7, 1)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { name in
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.fg3)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 28)
            .hairline(.bottom)

            GeometryReader { geo in
                let height = geo.size.height / CGFloat(rows)
                let maxItems = max(Int((height - 28) / 19), 1)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(days[(row * 7)..<min(row * 7 + 7, days.count)], id: \.self) { day in
                                cell(day, height: height, maxItems: maxItems)
                            }
                        }
                        .frame(height: height)
                        .hairline(.bottom)
                    }
                }
            }
        }
    }

    private func cell(_ day: Date, height: CGFloat, maxItems: Int) -> some View {
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let items = events.filter { $0.overlaps(day, next) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
        let inMonth = calendar.isDate(day, equalTo: store.scheduleDate, toGranularity: .month)
        let today = calendar.isDateInToday(day)
        let selected = calendar.isDate(day, inSameDayAs: store.scheduleDate)
        let visible = items.count > maxItems ? Array(items.prefix(maxItems - 1)) : items
        let hidden = items.count - visible.count

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer(minLength: 0)
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: today || selected ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(today ? .white : (inMonth ? UM.fg : UM.fg3))
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(today ? UM.accent : (selected ? UM.selSide : .clear)))
            }
            ForEach(visible) { event in
                chip(event, day: day)
            }
            if hidden > 0 {
                Button { actions.openDay(day) } label: {
                    Text("ещё \(hidden)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(UM.fg2)
                        .padding(.leading, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Открыть день")
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(inMonth ? Color.clear : UM.inset.opacity(0.5))
        .overlay(alignment: .leading) { Rectangle().fill(UM.sep).frame(width: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.openDay(day) }
        .onTapGesture { withAnimation(Motion.snappy) { store.scheduleDate = day } }
        .contextMenu {
            Button("Новая встреча…") {
                let start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
                actions.create(start, false)
            }
            Button("Открыть день") { actions.openDay(day) }
        }
    }

    private func chip(_ event: CalendarEvent, day: Date, key: String = "cell") -> some View {
        let color = data.color(event)
        let declined = event.myResponse == .declined || event.isCancelled
        return Button { actions.open(event) } label: {
            HStack(spacing: 4) {
                if event.isAllDay {
                    Text(event.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.2)))
                } else {
                    Circle()
                        .strokeBorder(color, lineWidth: event.needsResponse ? 1.5 : 0)
                        .background(Circle().fill(event.needsResponse ? .clear : color))
                        .frame(width: 7, height: 7)
                    Text(RelativeDate.clock(event.start))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(UM.fg3)
                    Text(event.title)
                        .font(.system(size: 11, weight: .medium))
                        .strikethrough(declined)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 17)
            .opacity(declined ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverStyle(radius: 4, pressScale: 1))
    }
}
