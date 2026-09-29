import AppKit
import SwiftUI

/// Вкладка «Расписание»: лента дня 9:00–19:00 и повестка на неделю (экран 11 макета).
/// Выбор аккаунта в панели фильтрует календари.
@MainActor
struct ScheduleView: View {
    @Environment(MailStore.self) private var store
    @State private var day = Date.now

    private let hourHeight: CGFloat = 54
    private let firstHour = 9
    private let lastHour = 19

    private var accountFilter: UUID? { store.scope.accountID }

    var body: some View {
        @Bindable var store = store
        let events = store.events(on: day, accountFilter: accountFilter).filter { !store.scheduleHidden.contains($0.accountID) }
        let markers = store.markers(on: day, accountFilter: accountFilter).filter { !store.scheduleHidden.contains($0.accountID) }

        VStack(spacing: 0) {
            // Шапка 52 pt
            HStack(spacing: 10) {
                ModeSwitch()
                Color.clear.frame(width: 10, height: 1)
                Text(RelativeDate.dayTitle(day))
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .contentTransition(.opacity)
                Spacer()
                HStack(spacing: 2) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(ToolbarIconStyle(width: 28, height: 26, radius: 7))
                    Button("Сегодня") { withAnimation(Motion.smooth) { day = .now } }
                        .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
                        .font(.system(size: 12, weight: .semibold))
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(ToolbarIconStyle(width: 28, height: 26, radius: 7))
                }
                SearchField(text: $store.searchText)
                    .frame(width: 190)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .hairline(.bottom, color: UM.tbSep)

            HStack(spacing: 0) {
                timeline(events: events, markers: markers)
                    .padding(.top, 18)
                    .padding(.leading, 16)
                    .padding(.trailing, 24)
                weekPanel
                    .frame(width: 360)
                    .background(UM.list)
                    .hairline(.leading)
            }
        }
        .background(UM.win)
        .animation(Motion.smooth, value: day)
    }

    private func shift(_ days: Int) {
        withAnimation(Motion.smooth) {
            day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
        }
    }

    // MARK: Лента дня

    private func y(for date: Date) -> CGFloat {
        let cal = Calendar.current
        let hours = Double(cal.component(.hour, from: date)) + Double(cal.component(.minute, from: date)) / 60
        return CGFloat(hours - Double(firstHour)) * hourHeight
    }

    private func timeline(events: [ScheduleEvent], markers: [ScheduleMarker]) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        let meetings = events.count
        let sends = markers.filter { $0.kind == .send }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(isToday ? "Сегодня" : RelativeDate.dayMonthShort(day))
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.44)
                Text("\(meetings) \(plural(meetings, "встреча", "встречи", "встреч")) · \(sends) \(plural(sends, "письмо уйдёт", "письма уйдут", "писем уйдут")) по расписанию")
                    .font(.system(size: 12.5))
                    .foregroundStyle(UM.fg3)
            }
            .padding(.leading, 52)
            .padding(.bottom, 12)

            ScrollView {
                ZStack(alignment: .topLeading) {
                    ForEach(firstHour...lastHour, id: \.self) { hour in
                        HStack(alignment: .top, spacing: 10) {
                            Text(String(format: "%02d:00", hour))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(UM.fg3)
                                .frame(width: 42, alignment: .trailing)
                                .offset(y: -7)
                            Rectangle().fill(UM.sep).frame(height: 0.5)
                        }
                        .offset(y: CGFloat(hour - firstHour) * hourHeight)
                    }

                    ForEach(events) { event in
                        eventBlock(event)
                            .padding(.leading, 62)
                            .padding(.trailing, 10)
                            .offset(y: y(for: event.start) + 1)
                    }

                    ForEach(markers) { marker in
                        markerView(marker)
                            .padding(.leading, 52)
                            .padding(.trailing, 10)
                            .offset(y: y(for: marker.date) - 12)
                    }

                    if isToday {
                        let now = y(for: .now)
                        if now >= 0 && now <= CGFloat(lastHour - firstHour) * hourHeight {
                            HStack(spacing: 0) {
                                Circle().fill(UM.red).frame(width: 8, height: 8).offset(x: -4)
                                Rectangle().fill(UM.red).frame(height: 1.5)
                            }
                            .padding(.leading, 46)
                            .offset(y: now - 4)
                            .allowsHitTesting(false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: CGFloat(lastHour - firstHour) * hourHeight + 20, alignment: .topLeading)
            }
            .scrollIndicators(.never)
        }
    }

    private func eventBlock(_ event: ScheduleEvent) -> some View {
        let tint = store.account(event.accountID)?.tint ?? .blue
        let color = tint.color
        let tintNS = NSColor(hex: tint.hex)
        let height = max(CGFloat(event.end.timeIntervalSince(event.start) / 3600) * hourHeight - 3, 24)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 8, height: 8)
                Text(event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if event.fromMail {
                    HStack(spacing: 4) {
                        Image(systemName: "envelope").font(.system(size: 10))
                        Text("из письма")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(UM.fg2)
                }
            }
            Text(event.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(UM.fg2)
                .lineLimit(1)
                .padding(.leading, 15)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background {
            if event.fromMail {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.dynamic(tintNS.withAlphaComponent(0.14), tintNS.withAlphaComponent(0.24)))
            }
        }
        .clipped()
    }

    private func markerView(_ marker: ScheduleMarker) -> some View {
        let color = store.account(marker.accountID)?.tint.color ?? UM.blue
        return HStack(spacing: 8) {
            Circle()
                .fill(UM.win)
                .overlay(Circle().strokeBorder(color, lineWidth: 2))
                .frame(width: 9, height: 9)
            HStack(spacing: 6) {
                Image(systemName: marker.kind == .send ? "paperplane.circle" : "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                Text(RelativeDate.clock(marker.date))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(UM.fg)
                Text(marker.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UM.fg2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(UM.card))
            .overlay(Capsule().strokeBorder(UM.cardBorder, lineWidth: 0.5))
            .modifier(CardShadow(small: true))
            .onTapGesture {
                withAnimation(Motion.smooth) { store.mode = .mail }
                store.selectedThreadID = marker.threadID
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Неделя

    private var weekPanel: some View {
        let groups = store.agenda(days: 7, accountFilter: accountFilter)
            .map { group in
                AgendaDay(day: group.day, items: group.items.filter { !store.scheduleHidden.contains($0.accountID) })
            }
            .filter { !$0.items.isEmpty }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Неделя")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.bottom, -4)
                if groups.isEmpty {
                    Text("На неделе ничего не запланировано")
                        .font(.system(size: 12.5))
                        .foregroundStyle(UM.fg3)
                        .padding(.horizontal, 4)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(RelativeDate.agendaHeader(group.day))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(UM.fg3)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 2)
                        ForEach(group.items) { item in agendaRow(item) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private func agendaRow(_ item: AgendaItem) -> some View {
        let color = store.account(item.accountID)?.tint.color ?? UM.blue
        return HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 13))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11.5)).foregroundStyle(UM.fg3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let tag = item.tag {
                Text(tag)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(UM.warnFg)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(UM.warnBg))
                    .fixedSize()
            }
            Text(item.timeText)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(UM.fg2)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UM.card))
        .overlay {
            if item.dashed {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UM.cardBorder, lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Боковая панель расписания

@MainActor
struct ScheduleSidebar: View {
    @Environment(MailStore.self) private var store
    @State private var month = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(RelativeDate.monthTitle(month)).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                HStack(spacing: 2) {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(UM.fg3)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 8)

            MonthGrid(month: month, busyDays: store.busyDays(inMonthOf: month))

            SectionLabel(text: "Календари", leading: 2).padding(.top, 6)
            ForEach(store.accounts) { account in
                let on = !store.scheduleHidden.contains(account.id)
                Button {
                    withAnimation(Motion.snappy) {
                        if on { store.scheduleHidden.insert(account.id) } else { store.scheduleHidden.remove(account.id) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(on ? account.tint.color : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(account.tint.color, lineWidth: on ? 0 : 1.5))
                            .overlay {
                                if on {
                                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 14, height: 14)
                        Text(account.displayName).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                }
                .buttonStyle(HoverStyle(radius: 7, pressScale: 1))
            }
        }
        .padding(.horizontal, 14)
    }

    private func shiftMonth(_ delta: Int) {
        withAnimation(Motion.smooth) {
            month = Calendar.current.date(byAdding: .month, value: delta, to: month) ?? month
        }
    }
}
