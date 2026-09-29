import AppKit
import SwiftUI

/// Встречи для «Расписания» из всех источников: Exchange, приглашения из писем, Календарь macOS, демо.
@MainActor
struct ScheduleData {
    let store: MailStore
    var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    /// Все встречи, пересекающие интервал, с учётом скрытых календарей и поиска.
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        let service = CalendarService.shared
        _ = service.revision
        var list = store.mailCalendarEvents(from: start, to: end, accountFilter: store.scope.accountID)
            .filter { $0.accountID.map { !store.scheduleHidden.contains($0) } ?? true }
        // Exchange, подключённый ещё и в Календаре macOS, не дублируем: остаётся версия с ответами и участниками.
        let known = list.map { (CalendarEvent.normalizedTitle($0.title), $0.start) }
        let exchangeDomains = Set(store.calendarAccountIDs.compactMap { store.account($0)?.email.split(separator: "@").last.map { $0.lowercased() } })
        list += service.calendarEvents(from: start, to: end)
            .filter { event in
                let title = CalendarEvent.normalizedTitle(event.title)
                return !known.contains { $0.0 == title && abs($0.1.timeIntervalSince(event.start)) < 60 }
            }
            .map { event in
                // Встреча из Exchange, подключённого в Календаре macOS, — отвечаем через ящик Exchange.
                var event = event
                let domains = Set(([event.organizer].compactMap { $0 } + event.attendees)
                    .compactMap { $0.email.split(separator: "@").last.map { $0.lowercased() } })
                event.serverLinked = event.isMeeting && !exchangeDomains.isEmpty
                    && (event.calendarIsExchange || !domains.isDisjoint(with: exchangeDomains))
                if let response = store.eventResponseOverrides[event.id] { event.myResponse = response }
                return event
            }
        list += demoEvents(from: start, to: end)
        let query = store.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) || $0.location.lowercased().contains(query)
                    || ($0.organizer?.display.lowercased().contains(query) ?? false)
            }
        }
        return list.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// Демо-встречи, пока подключены только демо-ящики.
    private func demoEvents(from start: Date, to end: Date) -> [CalendarEvent] {
        guard store.onlyDemoAccounts else { return [] }
        var result: [CalendarEvent] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            for item in store.events(on: day, accountFilter: store.scope.accountID) where item.id.hasPrefix("demo-") {
                var event = CalendarEvent(id: item.id, source: .system, accountID: item.accountID, remoteID: item.id,
                                          title: item.title, start: item.start, end: item.end)
                event.calendarTitle = item.accountID.flatMap { store.account($0)?.displayName } ?? "Демо"
                event.canEdit = false
                event.location = item.subtitle.components(separatedBy: " · ").dropFirst().first ?? ""
                if !store.scheduleHidden.contains(item.accountID ?? UUID()) { result.append(event) }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
        }
        return result
    }

    func color(_ event: CalendarEvent) -> Color {
        if let hex = event.colorHex { return Color(hex: hex) }
        if let id = event.accountID, let account = store.account(id) { return account.tint.color }
        return UM.blue
    }

    /// Интервал, который показывает вид (день, неделя с понедельника, месяц сеткой по неделям).
    func interval(for range: ScheduleRange, around date: Date) -> DateInterval {
        switch range {
        case .day:
            let start = calendar.startOfDay(for: date)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start) ?? start)
        case .month:
            let month = calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 86400 * 30)
            let first = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start ?? month.start
            let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.end
            let last = calendar.dateInterval(of: .weekOfYear, for: lastDay)?.end ?? month.end
            return DateInterval(start: first, end: last)
        }
    }

    func days(in interval: DateInterval) -> [Date] {
        var result: [Date] = []
        var day = interval.start
        while day < interval.end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? interval.end
        }
        return result
    }

    /// Раскладка пересекающихся встреч по колонкам: (встреча, колонка, всего колонок в группе).
    struct Placed: Identifiable {
        var event: CalendarEvent
        var column: Int
        var count: Int
        var id: String { event.id }
    }

    static func columns(_ events: [CalendarEvent]) -> [Placed] {
        let sorted = events.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        var result: [Placed] = []
        var cluster: [(CalendarEvent, Int)] = []
        var clusterEnd = Date.distantPast
        var columnEnds: [Date] = []

        func flush() {
            let count = (cluster.map(\.1).max() ?? 0) + 1
            result += cluster.map { Placed(event: $0.0, column: $0.1, count: count) }
            cluster = []
            columnEnds = []
        }
        for event in sorted {
            let end = max(event.end, event.start.addingTimeInterval(20 * 60))
            if event.start >= clusterEnd { flush() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = end
                cluster.append((event, free))
            } else {
                columnEnds.append(end)
                cluster.append((event, columnEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, end)
        }
        flush()
        return result
    }
}

/// Что открыть в редакторе встречи.
struct EventEditorRequest: Identifiable {
    let id = UUID()
    var draft: EventDraft
    /// Изменяемая встреча (nil — новая).
    var original: CalendarEvent?
}

/// Действия с встречами, общие для всех видов.
@MainActor
struct ScheduleActions {
    var edit: (CalendarEvent) -> Void
    var create: (Date, Bool) -> Void
    var openDay: (Date) -> Void
}

/// Время встречи одной строкой: «10:00–11:00», «весь день», «29 сент., 10:00 – 1 окт., 12:00».
enum EventTime {
    static func text(_ event: CalendarEvent, calendar: Calendar = .current) -> String {
        if event.isAllDay {
            let lastDay = calendar.date(byAdding: .second, value: -1, to: event.end) ?? event.end
            if calendar.isDate(event.start, inSameDayAs: lastDay) { return "весь день" }
            return "\(RelativeDate.dayMonthShort(event.start)) – \(RelativeDate.dayMonthShort(lastDay))"
        }
        if calendar.isDate(event.start, inSameDayAs: event.end) || event.end == calendar.startOfDay(for: event.end) && event.end.timeIntervalSince(event.start) < 86400 {
            return "\(RelativeDate.clock(event.start))–\(RelativeDate.clock(event.end))"
        }
        return "\(RelativeDate.dayMonthShort(event.start)), \(RelativeDate.clock(event.start)) – \(RelativeDate.dayMonthShort(event.end)), \(RelativeDate.clock(event.end))"
    }

    static func duration(_ event: CalendarEvent) -> String {
        let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
        if minutes < 60 { return "\(minutes) мин" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) ч" : "\(hours) ч \(rest) мин"
    }
}
