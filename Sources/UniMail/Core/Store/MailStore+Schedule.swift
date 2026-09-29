import Foundation

/// Данные вкладки «Расписание».
///
/// Этап 6: встречи придут из системного Календаря (EventKit). Сейчас — демо-встречи
/// плюс настоящие данные из почты: приглашения, запланированные и отложенные письма.
@MainActor
extension MailStore {
    private var calendar: Calendar { Calendar.current }

    private func today(_ hour: Int, _ minute: Int = 0, plusDays: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: plusDays, to: .now) ?? .now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private func scheduleAccounts(_ filter: UUID?) -> [Account] {
        accounts.filter { filter == nil || $0.id == filter }
    }

    /// Демо-встречи привязываются к ящикам по порядку: первый — «Работа», второй — «Личное», третий — «Студия».
    private func demoAccount(_ index: Int) -> UUID? {
        accounts.indices.contains(index) ? accounts[index].id : accounts.first?.id
    }

    func events(on day: Date, accountFilter: UUID?) -> [ScheduleEvent] {
        var result: [ScheduleEvent] = []
        if calendar.isDateInToday(day) {
            let demo: [(String, String, Int, Int, Int, Int, Int)] = [
                ("Стендап дизайна", "10:00–10:30", 10, 0, 10, 30, 0),
                ("Обед с Катей", "12:30–13:30 · «Пекарня на Литейном»", 12, 30, 13, 30, 1),
                ("Созвон с клиентом «Север»", "16:00–17:00 · видеозвонок", 16, 0, 17, 0, 2),
            ]
            for (i, item) in demo.enumerated() {
                guard let account = demoAccount(item.6) else { continue }
                let name = self.account(account)?.displayName ?? ""
                result.append(ScheduleEvent(
                    id: "demo-\(i)", title: item.0, subtitle: "\(item.1) · \(name)",
                    start: today(item.2, item.3), end: today(item.4, item.5), accountID: account
                ))
            }
        }
        if scheduleLayers.contains(.meetingsFromMail) {
            for message in messages.values where message.role != .trash {
                guard let invite = message.invite, calendar.isDate(invite.start, inSameDayAs: day) else { continue }
                result.append(ScheduleEvent(
                    id: "invite-\(message.id)", title: invite.title,
                    subtitle: "\(invite.start.formatted(.dateTime.hour().minute()))–\(invite.end.formatted(.dateTime.hour().minute())) · из письма \(message.from.display)",
                    start: invite.start, end: invite.end, accountID: message.accountID, fromMail: true
                ))
            }
        }
        return result
            .filter { accountFilter == nil || $0.accountID == accountFilter }
            .sorted { $0.start < $1.start }
    }

    func markers(on day: Date, accountFilter: UUID?) -> [ScheduleMarker] {
        var result: [ScheduleMarker] = []
        for m in messages.values where accountFilter == nil || m.accountID == accountFilter {
            if scheduleLayers.contains(.sends), m.role == .scheduled, let at = m.scheduledAt,
               calendar.isDate(at, inSameDayAs: day) {
                let to = m.to.first?.display ?? ""
                result.append(ScheduleMarker(id: "send-\(m.id)", kind: .send, date: at,
                                             text: "Отправится «\(m.subject)» → \(to)",
                                             accountID: m.accountID, threadID: m.threadID))
            }
            if scheduleLayers.contains(.snoozeReturns), m.role == .snoozed, let at = m.snoozedUntil,
               calendar.isDate(at, inSameDayAs: day) {
                result.append(ScheduleMarker(id: "snooze-\(m.id)", kind: .snoozeReturn, date: at,
                                             text: "Вернётся «\(m.subject)»",
                                             accountID: m.accountID, threadID: m.threadID))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Повестка на следующие дни (без сегодняшнего), сгруппированная по дням.
    func agenda(days: Int, accountFilter: UUID?) -> [AgendaDay] {
        var items: [AgendaItem] = []
        let time = { (d: Date) in d.formatted(.dateTime.hour().minute()) }

        if let work = demoAccount(0) {
            items.append(AgendaItem(id: "a1", kind: .event, title: "Планирование спринта", subtitle: "\(account(work)?.displayName ?? "") · 1 ч",
                                    date: today(11, plusDays: 1), timeText: "11:00", accountID: work))
            items.append(AgendaItem(id: "a2", kind: .task, title: "Срок: DS-214 «Тёмная тема для списка»", subtitle: "Из письма Трекера задач",
                                    date: today(9, plusDays: 3), timeText: "весь день", accountID: work))
        }
        if let home = demoAccount(1) {
            items.append(AgendaItem(id: "a3", kind: .event, title: "Йога", subtitle: account(home)?.displayName ?? "",
                                    date: today(19, 30, plusDays: 3), timeText: "19:30", accountID: home))
        }
        for m in messages.values where m.role != .trash {
            if let invite = m.invite, !calendar.isDateInToday(invite.start), invite.start > .now {
                items.append(AgendaItem(id: "inv-\(m.id)", kind: .fromMail, title: invite.title,
                                        subtitle: "Из письма \(m.from.display) · \(invite.location.components(separatedBy: " · ").first ?? "")",
                                        date: invite.start, timeText: time(invite.start), accountID: m.accountID,
                                        tag: "Ждёт ответа"))
            }
            if m.role == .scheduled, let at = m.scheduledAt, !calendar.isDateInToday(at), at > .now {
                items.append(AgendaItem(id: "snd-\(m.id)", kind: .send, title: "Отправится «\(m.subject)»",
                                        subtitle: "→ \(m.to.first?.display ?? "")", date: at, timeText: time(at),
                                        accountID: m.accountID))
            }
            if m.role == .snoozed, let at = m.snoozedUntil, !calendar.isDateInToday(at), at > .now {
                items.append(AgendaItem(id: "snz-\(m.id)", kind: .snoozeReturn, title: "Вернётся «\(m.subject)»",
                                        subtitle: "Отложено · \(account(m.accountID)?.displayName ?? "")", date: at,
                                        timeText: time(at), accountID: m.accountID))
            }
        }

        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: .now) ?? .now)
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        let visible = items.filter { item in
            (accountFilter == nil || item.accountID == accountFilter) && item.date >= start && item.date < end &&
            (item.kind != .fromMail || scheduleLayers.contains(.meetingsFromMail)) &&
            (item.kind != .send || scheduleLayers.contains(.sends)) &&
            (item.kind != .snoozeReturn || scheduleLayers.contains(.snoozeReturns))
        }
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            AgendaDay(day: day, items: (grouped[day] ?? []).sorted { $0.date < $1.date })
        }
    }

    /// Дни месяца, в которые что-то есть (точки в мини-календаре).
    func busyDays(inMonthOf date: Date) -> Set<Int> {
        var days: Set<Int> = []
        let add = { (d: Date) in
            if self.calendar.isDate(d, equalTo: date, toGranularity: .month) {
                days.insert(self.calendar.component(.day, from: d))
            }
        }
        for m in messages.values {
            if let i = m.invite { add(i.start) }
            if m.role == .scheduled, let at = m.scheduledAt { add(at) }
            if m.role == .snoozed, let at = m.snoozedUntil { add(at) }
        }
        for offset in [1, 3] { add(today(10, plusDays: offset)) }
        return days
    }

    func toggleLayer(_ layer: ScheduleLayer) {
        if scheduleLayers.contains(layer) { scheduleLayers.remove(layer) } else { scheduleLayers.insert(layer) }
    }
}
