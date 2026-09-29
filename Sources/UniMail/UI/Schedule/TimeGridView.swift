import AppKit
import SwiftUI

/// Сетка времени на один день или неделю: часы 0–24, встречи блоками, «весь день» сверху,
/// линия текущего времени. Двойной щелчок по пустому месту — новая встреча на это время.
@MainActor
struct TimeGridView: View {
    @Environment(MailStore.self) private var store
    let days: [Date]
    let events: [CalendarEvent]
    var markers: [ScheduleMarker] = []
    let data: ScheduleData
    let actions: ScheduleActions

    private let hourHeight: CGFloat = 50
    private let gutter: CGFloat = 54

    private var calendar: Calendar { data.calendar }

    var body: some View {
        let allDay = events.filter { $0.isAllDay || $0.end.timeIntervalSince($0.start) >= 86400 }
        let timed = events.filter { !($0.isAllDay || $0.end.timeIntervalSince($0.start) >= 86400) }

        VStack(spacing: 0) {
            if days.count > 1 { weekHeader }
            if !allDay.isEmpty { allDayRow(allDay) }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        hourLines
                        HStack(spacing: 0) {
                            Color.clear.frame(width: gutter, height: 1)
                            ForEach(days, id: \.self) { day in
                                dayColumn(day, events: timed.filter { $0.overlaps(day, nextDay(day)) })
                                    .overlay(alignment: .leading) {
                                        if days.count > 1 { Rectangle().fill(UM.sep).frame(width: 0.5) }
                                    }
                            }
                        }
                        .padding(.trailing, 10)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.automatic)
                .onAppear { scrollToStart(proxy, timed: timed) }
                .onChange(of: days.first) { scrollToStart(proxy, timed: timed) }
            }
        }
    }

    private func nextDay(_ day: Date) -> Date { calendar.date(byAdding: .day, value: 1, to: day) ?? day }

    /// К первому событию дня или к текущему часу, но не раньше 7:00 без причины.
    private func scrollToStart(_ proxy: ScrollViewProxy, timed: [CalendarEvent]) {
        let first = timed.map { calendar.component(.hour, from: $0.start) }.min()
        var hour = first.map { max(0, $0 - 1) } ?? 8
        if days.contains(where: { calendar.isDateInToday($0) }) {
            let now = calendar.component(.hour, from: .now)
            hour = min(hour, max(0, now - 1))
            if first == nil { hour = max(7, now - 2) }
        }
        hour = min(hour, 16)
        // После раскладки сетки (и ещё раз — если данные Exchange пришли чуть позже).
        for delay in [0.05, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(nil) { proxy.scrollTo(hour, anchor: .top) }
            }
        }
    }

    // MARK: Шапка недели

    private var weekHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let today = calendar.isDateInToday(day)
                let selected = calendar.isDate(day, inSameDayAs: store.scheduleDate)
                Button { actions.openDay(day) } label: {
                    HStack(spacing: 6) {
                        Text(RelativeDate.weekdayShort(day))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(today ? UM.accent : UM.fg3)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(today ? .white : UM.fg)
                            .frame(minWidth: 26, minHeight: 26)
                            .background(Circle().fill(today ? UM.accent : (selected ? UM.selSide : .clear)))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverStyle(radius: 8, pressScale: 1))
                .help("Открыть день")
            }
        }
        .padding(.trailing, 10)
        .fixedSize(horizontal: false, vertical: true)
        .hairline(.bottom)
    }

    // MARK: Весь день

    private func allDayRow(_ items: [CalendarEvent]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("весь день")
                .font(.system(size: 10.5))
                .foregroundStyle(UM.fg3)
                .frame(width: gutter - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 6)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 3) {
                    ForEach(items.filter { $0.overlaps(day, nextDay(day)) }) { event in
                        chip(event, key: "allday-\(day.timeIntervalSince1970)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
        .padding(.trailing, 10)
        .fixedSize(horizontal: false, vertical: true)
        .hairline(.bottom)
    }

    private func chip(_ event: CalendarEvent, key: String) -> some View {
        let color = data.color(event)
        return Button { actions.open(event) } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 12)
                Text(event.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.16)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Часы

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(UM.fg3)
                        .frame(width: gutter - 8, alignment: .trailing)
                        .offset(y: -6)
                        .opacity(hour == 0 ? 0 : 1)
                    Rectangle().fill(UM.sep).frame(height: 0.5)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: gutter - 8, height: 1)
                Rectangle().fill(UM.sep).frame(height: 0.5)
            }
        }
        .padding(.trailing, 10)
    }

    private func y(_ date: Date, on day: Date) -> CGFloat {
        let seconds = date.timeIntervalSince(day)
        return CGFloat(max(0, min(seconds, 86400)) / 3600) * hourHeight
    }

    // MARK: Колонка дня

    private func dayColumn(_ day: Date, events: [CalendarEvent]) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                // Пустое место: двойной щелчок — новая встреча.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, coordinateSpace: .local) { point in
                        let minutes = Int(point.y / hourHeight * 60) / 30 * 30
                        let start = calendar.date(byAdding: .minute, value: minutes, to: day) ?? day
                        actions.create(start, false)
                    }

                ForEach(ScheduleData.columns(events)) { item in
                    let event = item.event
                    let top = y(event.start, on: day)
                    let bottom = y(event.end, on: day)
                    let columnWidth = (width - 4) / CGFloat(item.count)
                    eventBlock(event, height: max(bottom - top - 2, 20), compact: days.count > 1, day: day)
                        .frame(width: max(columnWidth - 2, 10))
                        .offset(x: 2 + CGFloat(item.column) * columnWidth, y: top + 1)
                }

                ForEach(markers) { marker in
                    markerView(marker)
                        .offset(y: y(marker.date, on: day) - 11)
                }

                if calendar.isDateInToday(day) {
                    let now = y(.now, on: day)
                    HStack(spacing: 0) {
                        Circle().fill(UM.red).frame(width: 8, height: 8).offset(x: -4)
                        Rectangle().fill(UM.red).frame(height: 1.5)
                    }
                    .offset(y: now - 4)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: hourHeight * 24)
    }

    private func eventBlock(_ event: CalendarEvent, height: CGFloat, compact: Bool, day: Date) -> some View {
        let color = data.color(event)
        let tint = NSColor(color)
        let declined = event.myResponse == .declined
        let pending = event.needsResponse
        return Button { actions.open(event) } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if pending {
                        Image(systemName: "envelope.badge").font(.system(size: 9.5))
                    } else if event.myResponse == .tentative {
                        Image(systemName: "questionmark.circle").font(.system(size: 9.5))
                    }
                    Text(event.title)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .strikethrough(declined || event.isCancelled)
                        .lineLimit(height > 40 ? 2 : 1)
                }
                if height > 34 {
                    Text(compact ? RelativeDate.clock(event.start) : subtitle(event))
                        .font(.system(size: compact ? 10.5 : 11.5))
                        .foregroundStyle(UM.fg2)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(UM.fg)
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(pending ? Color.clear : Color.dynamic(tint.withAlphaComponent(0.15), tint.withAlphaComponent(0.26)))
                    if pending || event.myResponse == .tentative {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(color, style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
                    }
                    Rectangle().fill(color).frame(width: 3).padding(.vertical, 3).clipShape(Capsule()).padding(.leading, 2)
                }
            }
            .opacity(declined || event.isCancelled ? 0.5 : 1)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ event: CalendarEvent) -> String {
        var parts = [EventTime.text(event)]
        let location = event.location.trimmingCharacters(in: .whitespaces)
        if location.lowercased().hasPrefix("http") {
            parts.append("видеовстреча")
        } else if !location.isEmpty {
            parts.append(location)
        }
        if event.source == .mail { parts.append("из письма") }
        return parts.joined(separator: " · ")
    }

    private func markerView(_ marker: ScheduleMarker) -> some View {
        let color = store.account(marker.accountID)?.tint.color ?? UM.blue
        return HStack(spacing: 6) {
            Image(systemName: marker.kind == .send ? "paperplane.circle" : "clock.arrow.circlepath")
                .font(.system(size: 11.5))
                .foregroundStyle(color)
            Text(RelativeDate.clock(marker.date))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
            Text(marker.text)
                .font(.system(size: 11))
                .foregroundStyle(UM.fg2)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(UM.card))
        .overlay(Capsule().strokeBorder(UM.cardBorder, lineWidth: 0.5))
        .modifier(CardShadow(small: true))
        .padding(.leading, 6)
        .onTapGesture {
            withAnimation(Motion.smooth) { store.mode = .mail }
            store.selectedThreadID = marker.threadID
        }
    }

}
