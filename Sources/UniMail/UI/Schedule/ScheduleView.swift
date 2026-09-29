import AppKit
import SwiftUI

/// Вкладка «Расписание»: день (лента + ближайшие встречи справа), неделя или месяц.
/// Встречи — из Exchange, из писем-приглашений и из Календаря macOS; выбор ящика в панели фильтрует почтовые.
@MainActor
struct ScheduleView: View {
    @Environment(MailStore.self) private var store
    @State private var editor: EventEditorRequest?
    /// Открытая карточка встречи (панель справа; не поповер — у AppKit он падает при смене размера).
    @State private var selected: CalendarEvent?
    @State private var loading = false

    private var data: ScheduleData { ScheduleData(store: store) }
    private var calendar: Calendar { data.calendar }

    var body: some View {
        @Bindable var store = store
        let interval = data.interval(for: store.scheduleRange, around: store.scheduleDate)
        let events = data.events(from: interval.start, to: interval.end)
        let actions = ScheduleActions(
            open: { event in withAnimation(Motion.snappy) { selected = event } },
            edit: { event in Task { await openEditor(for: event) } },
            create: { start, allDay in create(at: start, allDay: allDay) },
            openDay: { day in
                withAnimation(Motion.smooth) {
                    store.scheduleDate = day
                    store.scheduleRange = .day
                }
            }
        )

        VStack(spacing: 0) {
            header(interval: interval)

            Group {
                switch store.scheduleRange {
                case .day:
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            dayTitle(events: events)
                            TimeGridView(days: [interval.start], events: events,
                                         markers: store.markers(on: interval.start, accountFilter: store.scope.accountID)
                                            .filter { !store.scheduleHidden.contains($0.accountID) },
                                         data: data, actions: actions)
                        }
                        AgendaPanel(data: data, actions: actions)
                            .frame(width: 340)
                            .background(UM.list)
                            .hairline(.leading)
                    }
                case .week:
                    TimeGridView(days: data.days(in: interval), events: events, data: data, actions: actions)
                case .month:
                    ScheduleMonthView(interval: interval, events: events, data: data, actions: actions)
                }
            }
            .transition(.opacity)
            .overlay(alignment: .trailing) {
                if let event = selected {
                    detailPanel(event, actions: actions)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(UM.win)
        .onChange(of: store.scheduleRange) { selected = nil }
        .onExitCommand { if selected != nil { withAnimation(Motion.snappy) { selected = nil } } }
        .animation(Motion.smooth, value: store.scheduleRange)
        .task {
            // Встречи Календаря macOS: Google, iCloud и другие подключаются там.
            CalendarService.shared.refreshAccess()
            if CalendarService.shared.access == .notDetermined {
                _ = await CalendarService.shared.requestAccess()
            }
        }
        .task(id: loadKey(interval)) {
            await load(interval)
            // Пока «Расписание» открыто — обновляем раз в 5 минут.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await load(interval)
            }
        }
        .sheet(item: $editor) { request in
            EventEditorSheet(request: request) { editor = nil }
        }
    }

    /// Карточка встречи: панель поверх правой части, прокручивается, закрывается крестиком или Esc.
    private func detailPanel(_ event: CalendarEvent, actions: ScheduleActions) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { withAnimation(Motion.snappy) { selected = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                }
                .buttonStyle(ToolbarIconStyle(width: 26, height: 26, radius: 7))
                .help("Закрыть · Esc")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            ScrollView {
                EventDetailView(event: event, data: data, actions: actions) {
                    withAnimation(Motion.snappy) { selected = nil }
                }
                .id(event.id)
                .padding(.top, -10)
            }
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(UM.card)
        .overlay(alignment: .leading) { Rectangle().fill(UM.sepStrong).frame(width: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 16, x: -4, y: 0)
    }

    private func loadKey(_ interval: DateInterval) -> String {
        "\(interval.start.timeIntervalSince1970)-\(interval.end.timeIntervalSince1970)-\(store.calendarAccountIDs.count)"
    }

    /// С запасом вокруг видимого — листание соседних дней не ждёт сервера.
    private func load(_ interval: DateInterval) async {
        let start = calendar.date(byAdding: .day, value: -7, to: interval.start) ?? interval.start
        let end = calendar.date(byAdding: .day, value: 14, to: interval.end) ?? interval.end
        loading = true
        await store.loadCalendar(from: start, to: end)
        loading = false
    }

    // MARK: Шапка

    private func header(interval: DateInterval) -> some View {
        @Bindable var store = store
        let ranges = ScheduleRange.allCases.map { SlidingSegments<ScheduleRange>.Item(value: $0, title: $0.title) }
        return HStack(spacing: 10) {
            ModeSwitch()
            Color.clear.frame(width: 6, height: 1)
            Text(title(interval))
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.15)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .contentTransition(.opacity)
            if loading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)
            SlidingSegments(items: ranges, selection: $store.scheduleRange, equalWidth: true, fontSize: 12)
                .frame(width: 190)
            HStack(spacing: 2) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(ToolbarIconStyle(width: 28, height: 26, radius: 7))
                    .help("Назад")
                Button("Сегодня") { withAnimation(Motion.smooth) { store.scheduleDate = .now } }
                    .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(ToolbarIconStyle(width: 28, height: 26, radius: 7))
                    .help("Вперёд")
            }
            Button { create(at: nil, allDay: false) } label: {
                Label("Встреча", systemImage: "plus")
            }
            .buttonStyle(UMButtonStyle(kind: .primary, height: 26, radius: 7, horizontal: 10))
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()
            .help("Новая встреча · ⌘⇧E")
            .keyboardShortcut("e", modifiers: [.command, .shift])
            SearchField(text: $store.searchText)
                .frame(minWidth: 90, idealWidth: 170, maxWidth: 170)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .hairline(.bottom, color: UM.tbSep)
    }

    private func title(_ interval: DateInterval) -> String {
        switch store.scheduleRange {
        case .day:
            return RelativeDate.dayTitle(store.scheduleDate)
        case .week:
            let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            let sameMonth = calendar.isDate(interval.start, equalTo: last, toGranularity: .month)
            let start = sameMonth ? "\(calendar.component(.day, from: interval.start))" : RelativeDate.dayMonthLong(interval.start)
            return "\(start) – \(RelativeDate.dayMonthLong(last)) \(calendar.component(.year, from: last))"
        case .month:
            return RelativeDate.monthTitle(store.scheduleDate)
        }
    }

    private func dayTitle(events: [CalendarEvent]) -> some View {
        let day = store.scheduleDate
        let meetings = events.filter { !$0.isCancelled && $0.myResponse != .declined }.count
        let waiting = events.filter(\.needsResponse).count
        let sends = store.markers(on: day, accountFilter: store.scope.accountID).filter { $0.kind == .send }.count
        var parts = ["\(meetings) \(plural(meetings, "встреча", "встречи", "встреч"))"]
        if waiting > 0 { parts.append("\(waiting) ждут ответа") }
        if sends > 0 { parts.append("\(sends) \(plural(sends, "письмо уйдёт", "письма уйдут", "писем уйдут")) по расписанию") }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(calendar.isDateInToday(day) ? "Сегодня" : RelativeDate.dayMonthLong(day))
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.44)
            Text(parts.joined(separator: " · "))
                .font(.system(size: 12.5))
                .foregroundStyle(UM.fg3)
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func shift(_ delta: Int) {
        let component: Calendar.Component
        let value: Int
        switch store.scheduleRange {
        case .day: component = .day; value = delta
        case .week: component = .day; value = delta * 7
        case .month: component = .month; value = delta
        }
        withAnimation(Motion.smooth) {
            store.scheduleDate = calendar.date(byAdding: component, value: value, to: store.scheduleDate) ?? store.scheduleDate
        }
    }

    // MARK: Редактор

    private func create(at start: Date?, allDay: Bool) {
        let base: Date
        if let start {
            base = start
        } else {
            // Ближайший целый час выбранного дня (сегодня — после текущего времени).
            let day = store.scheduleDate
            let hour = calendar.isDateInToday(day) ? min(calendar.component(.hour, from: .now) + 1, 23) : 10
            base = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        var draft = EventDraft(start: base, duration: allDay ? 86400 : 3600)
        if allDay {
            draft.isAllDay = true
            draft.start = calendar.startOfDay(for: base)
            draft.end = calendar.date(byAdding: .day, value: 1, to: draft.start) ?? base
        }
        editor = EventEditorRequest(draft: draft, original: nil)
    }

    private func openEditor(for event: CalendarEvent) async {
        let detailed = await store.loadDetails(event)
        editor = EventEditorRequest(draft: EventDraft(event: detailed), original: detailed)
    }
}

// MARK: - Ближайшие встречи (справа от дня)

/// Семь дней вперёд от выбранного: встречи с ответом прямо в строке, письма по расписанию, возвраты отложенных.
@MainActor
private struct AgendaPanel: View {
    @Environment(MailStore.self) private var store
    let data: ScheduleData
    let actions: ScheduleActions
    @State private var responding: [String: EventResponse] = [:]

    private var calendar: Calendar { data.calendar }

    private struct Entry: Identifiable {
        var id: String
        var date: Date
        var event: CalendarEvent?
        var item: AgendaItem?
    }

    var body: some View {
        let from = max(calendar.startOfDay(for: store.scheduleDate), calendar.isDateInToday(store.scheduleDate) ? Date.now : Date.distantPast)
        let start = calendar.startOfDay(for: store.scheduleDate)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let events = data.events(from: from, to: end).filter { !$0.isCancelled }
        let items = store.agenda(days: 8, accountFilter: store.scope.accountID)
            .flatMap(\.items)
            .filter { !$0.id.hasPrefix("inv-") && $0.date >= from && $0.date < end && !store.scheduleHidden.contains($0.accountID) }
        let entries = events.map { Entry(id: "e-\($0.id)", date: max($0.start, start), event: $0) }
            + items.map { Entry(id: "i-\($0.id)", date: $0.date, item: $0) }
        let groups = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        let days = groups.keys.sorted()
        let waiting = events.filter(\.needsResponse)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ближайшие 7 дней").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if !waiting.isEmpty {
                        Text("\(waiting.count) ждут ответа")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(UM.warnFg)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(UM.warnBg))
                    }
                }
                if days.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ничего не запланировано")
                            .font(.system(size: 12.5))
                            .foregroundStyle(UM.fg3)
                        Button { actions.create(nextSlot, false) } label: {
                            Label("Новая встреча", systemImage: "plus")
                        }
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
                    }
                }
                ForEach(days, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 5) {
                        Button { actions.openDay(day) } label: {
                            Text(RelativeDate.agendaHeader(day))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(calendar.isDateInToday(day) ? UM.accent : UM.fg3)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 1)
                        ForEach((groups[day] ?? []).sorted { $0.date < $1.date }) { entry in
                            if let event = entry.event {
                                eventRow(event, day: day)
                            } else if let item = entry.item {
                                itemRow(item)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private var nextSlot: Date {
        let hour = min(calendar.component(.hour, from: .now) + 1, 23)
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: store.scheduleDate) ?? .now
    }

    private func eventRow(_ event: CalendarEvent, day: Date) -> some View {
        let color = data.color(event)
        let declined = event.myResponse == .declined
        return VStack(alignment: .leading, spacing: 8) {
            Button { actions.open(event) } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .strikethrough(declined)
                            .lineLimit(1)
                        Text(subtitle(event))
                            .font(.system(size: 11.5))
                            .foregroundStyle(UM.fg3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(event.isAllDay ? "весь день" : RelativeDate.clock(event.start))
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(UM.fg2)
                        if event.canRespond && event.myResponse != .none {
                            Image(systemName: event.myResponse.symbol)
                                .font(.system(size: 10))
                                .foregroundStyle(event.myResponse == .accepted ? UM.green : event.myResponse == .declined ? UM.red : UM.orange)
                                .help(event.myResponse.title)
                        }
                    }
                    .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if event.needsResponse {
                HStack(spacing: 5) {
                    quickButton(event, .accepted, "Принять", "checkmark", UM.green)
                    quickButton(event, .tentative, "Возможно", "questionmark", UM.orange)
                    quickButton(event, .declined, "Отклонить", "xmark", UM.red)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.card))
        .overlay {
            if event.needsResponse {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5)
            }
        }
        .opacity(declined ? 0.55 : 1)
        .contextMenu {
            if event.canRespond {
                Button("Принять") { Task { await respond(event, .accepted) } }
                Button("Под вопросом") { Task { await respond(event, .tentative) } }
                Button("Отклонить") { Task { await respond(event, .declined) } }
                Divider()
            }
            Button("Подробнее…") { actions.open(event) }
            Button("Открыть день") { actions.openDay(day) }
        }
    }

    private func subtitle(_ event: CalendarEvent) -> String {
        var parts: [String] = []
        if !event.isAllDay { parts.append(EventTime.duration(event)) }
        if event.source == .mail, let organizer = event.organizer {
            parts.append("от \(organizer.display)")
        } else if !event.location.isEmpty {
            let location = event.location.trimmingCharacters(in: .whitespaces)
            if location.lowercased().hasPrefix("http"), let host = URL(string: location)?.host {
                parts.append("видеовстреча · \(host.replacingOccurrences(of: "www.", with: ""))")
            } else {
                parts.append(location)
            }
        } else if let organizer = event.organizer, event.myResponse != .organizer {
            parts.append(organizer.display)
        }
        return parts.joined(separator: " · ")
    }

    private func quickButton(_ event: CalendarEvent, _ response: EventResponse, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        let busy = responding[event.id] == response
        return Button {
            Task { await respond(event, response) }
        } label: {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(tint)
                }
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverStyle(radius: 7))
        .disabled(responding[event.id] != nil)
    }

    private func respond(_ event: CalendarEvent, _ response: EventResponse) async {
        responding[event.id] = response
        await store.respond(to: event, response)
        responding[event.id] = nil
    }

    private func itemRow(_ item: AgendaItem) -> some View {
        let color = store.account(item.accountID)?.tint.color ?? UM.blue
        return HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(UM.fg3).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(item.timeText)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(UM.fg2)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5))
    }
}

// MARK: - Боковая панель расписания

@MainActor
struct ScheduleSidebar: View {
    @Environment(MailStore.self) private var store
    @State private var month = Date.now

    var body: some View {
        let data = ScheduleData(store: store)
        let service = CalendarService.shared
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(RelativeDate.monthTitle(month)).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    HStack(spacing: 2) {
                        Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 22).contentShape(Rectangle()) }
                        Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UM.fg3)
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 8)

                MonthGrid(month: month, selected: store.scheduleDate, busyDays: busyDays(data),
                          selectsOutside: true) { day in
                    withAnimation(Motion.smooth) { store.scheduleDate = day }
                }

                SectionLabel(text: "Почтовые ящики", leading: 2).padding(.top, 6)
                ForEach(store.accounts) { account in
                    let on = !store.scheduleHidden.contains(account.id)
                    toggleRow(title: account.displayName, color: account.tint.color, on: on,
                              badge: store.calendarAccountIDs.contains(account.id) ? "Exchange" : nil,
                              error: store.calendarErrors[account.id]) {
                        withAnimation(Motion.snappy) {
                            if on { store.scheduleHidden.insert(account.id) } else { store.scheduleHidden.remove(account.id) }
                        }
                    }
                }

                SectionLabel(text: "Календарь macOS", leading: 2)
                if service.access.canRead {
                    ForEach(service.calendars) { item in
                        let on = !service.hiddenCalendarIDs.contains(item.id)
                        toggleRow(title: item.title, color: item.color, on: on, badge: nil, error: nil,
                                  help: item.sourceTitle) {
                            withAnimation(Motion.snappy) { service.toggleHidden(item.id) }
                        }
                    }
                    if service.calendars.isEmpty {
                        Text("Календарей нет").font(.system(size: 12)).foregroundStyle(UM.fg3).padding(.horizontal, 4)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Google, iCloud и другие календари, добавленные в Календарь macOS.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(UM.fg3)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(service.access == .denied ? "Открыть настройки доступа" : "Подключить") {
                            if service.access == .denied || service.access == .restricted {
                                service.openPrivacySettings()
                            } else {
                                Task { await service.requestAccess() }
                            }
                        }
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 24, radius: 7, horizontal: 10))
                    }
                    .padding(.horizontal, 4)
                }

                SectionLabel(text: "На ленте", leading: 2)
                ForEach(ScheduleLayer.allCases, id: \.self) { layer in
                    let on = store.scheduleLayers.contains(layer)
                    Button {
                        withAnimation(Motion.snappy) { store.toggleLayer(layer) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: layer.symbol).font(.system(size: 12)).foregroundStyle(UM.fg2).frame(width: 16)
                            Text(layer.title).font(.system(size: 12.5))
                            Spacer()
                            MiniSwitch(isOn: on, width: 26, height: 16)
                        }
                        .padding(.horizontal, 4)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverStyle(radius: 7, pressScale: 1))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .onAppear { month = store.scheduleDate }
        .onChange(of: store.scheduleDate) { _, day in
            if !Calendar.current.isDate(day, equalTo: month, toGranularity: .month) {
                withAnimation(Motion.smooth) { month = day }
            }
        }
    }

    private func toggleRow(title: String, color: Color, on: Bool, badge: String?, error: String?,
                           help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(on ? color : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(color, lineWidth: on ? 0 : 1.5))
                    .overlay {
                        if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) }
                    }
                    .frame(width: 14, height: 14)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                if error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(UM.orange)
                } else if let badge {
                    Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(UM.fg3)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(error ?? help ?? title)
    }

    /// Точки под днями с встречами и письмами по расписанию.
    private func busyDays(_ data: ScheduleData) -> Set<Int> {
        var days = store.busyDays(inMonthOf: month)
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: month) else { return days }
        for event in data.events(from: interval.start, to: interval.end) where !event.isCancelled {
            var day = max(cal.startOfDay(for: event.start), interval.start)
            while day < min(event.end, interval.end) {
                days.insert(cal.component(.day, from: day))
                day = cal.date(byAdding: .day, value: 1, to: day) ?? interval.end
            }
        }
        return days
    }

    private func shiftMonth(_ delta: Int) {
        withAnimation(Motion.smooth) {
            month = Calendar.current.date(byAdding: .month, value: delta, to: month) ?? month
        }
    }
}
