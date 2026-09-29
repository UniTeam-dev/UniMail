import AppKit
import EventKit
import Observation
import SwiftUI

/// Календарь в системе пользователя (EventKit): доступ, список календарей, события и
/// добавление встречи из приглашения. Google, Exchange и iCloud подключаются в Календаре macOS,
/// приложению OAuth не нужен.
@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService()

    /// Состояние доступа, понятное интерфейсу.
    enum Access: Equatable {
        case notDetermined
        case granted
        /// Только запись (пользователь дал ограниченный доступ): добавлять можно, читать — нет.
        case writeOnly
        case denied
        case restricted

        var title: String {
            switch self {
            case .notDetermined: "Доступ не запрошен"
            case .granted: "Доступ открыт"
            case .writeOnly: "Только добавление событий"
            case .denied: "Доступ запрещён"
            case .restricted: "Доступ ограничен политикой"
            }
        }

        var canRead: Bool { self == .granted }
        var canWrite: Bool { self == .granted || self == .writeOnly }
    }

    /// Календарь для списков и чипов в настройках.
    struct CalendarInfo: Identifiable, Hashable {
        var id: String
        var title: String
        var sourceTitle: String
        var color: Color
        var allowsModifications: Bool
    }

    /// Событие без ссылок на EventKit — безопасно хранить во вью.
    struct EventItem: Identifiable, Hashable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var location: String?
        var calendarID: String
        var calendarTitle: String
        var color: Color
    }

    private(set) var access: Access = .notDetermined
    private(set) var calendars: [CalendarInfo] = []
    /// Последняя ошибка по-русски (для плашки в интерфейсе).
    private(set) var lastError: String?

    @ObservationIgnored private let store = EKEventStore()

    private init() {
        refreshAccess()
        if access.canRead { reloadCalendars() }
        // Календари и события меняются в Календаре macOS — перечитываем список.
        _ = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                CalendarService.shared.refreshAccess()
                if CalendarService.shared.access.canRead { CalendarService.shared.reloadCalendars() }
            }
        }
    }

    // MARK: Доступ

    func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: access = .notDetermined
        case .fullAccess: access = .granted
        case .writeOnly: access = .writeOnly
        case .denied: access = .denied
        case .restricted: access = .restricted
        @unknown default: access = .denied
        }
    }

    /// Запрашивает полный доступ (macOS 14). Возвращает `true`, если читать события можно.
    @discardableResult
    func requestAccess() async -> Bool {
        refreshAccess()
        guard access == .notDetermined || access == .writeOnly else {
            if access == .denied {
                lastError = "Доступ к Календарю запрещён. Разрешите его в Системных настройках → Конфиденциальность → Календари."
            }
            return access.canRead
        }
        do {
            let granted = try await store.requestFullAccessToEvents()
            refreshAccess()
            if granted {
                lastError = nil
                reloadCalendars()
            } else {
                lastError = "Доступ к Календарю не выдан."
            }
            return granted
        } catch {
            refreshAccess()
            lastError = "Не удалось запросить доступ к Календарю: \(error.localizedDescription)"
            return false
        }
    }

    /// Открывает Системные настройки → Конфиденциальность → Календари.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Календари и события

    func reloadCalendars() {
        guard access.canRead else {
            calendars = []
            return
        }
        calendars = store.calendars(for: .event)
            .map { calendar in
                CalendarInfo(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source?.title ?? "",
                    color: Color(nsColor: calendar.color ?? .systemBlue),
                    allowsModifications: calendar.allowsContentModifications
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    /// События в интервале. `calendarIDs == nil` — все календари.
    func events(from start: Date, to end: Date, calendarIDs: Set<String>? = nil) -> [EventItem] {
        guard access.canRead, end > start else { return [] }
        var selected: [EKCalendar]? = nil
        if let calendarIDs {
            selected = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
            if selected?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        return store.events(matching: predicate)
            .map { event in
                EventItem(
                    id: event.eventIdentifier ?? event.calendarItemIdentifier,
                    title: event.title ?? "Без названия",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    calendarID: event.calendar?.calendarIdentifier ?? "",
                    calendarTitle: event.calendar?.title ?? "",
                    color: Color(nsColor: event.calendar?.color ?? .systemBlue)
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// События одного дня.
    func events(on day: Date, calendarIDs: Set<String>? = nil) -> [EventItem] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events(from: start, to: end, calendarIDs: calendarIDs)
    }

    // MARK: Добавление встречи

    /// Добавляет встречу из приглашения в календарь по умолчанию.
    /// При необходимости сначала запрашивает доступ. Повторное добавление той же встречи
    /// (то же название и время начала) не создаёт дубль и считается успехом.
    @discardableResult
    func addEvent(from invite: Invite, notes: String? = nil) async -> Bool {
        refreshAccess()
        if !access.canWrite {
            _ = await requestAccess()
            refreshAccess()
        }
        guard access.canWrite else {
            lastError = access == .notDetermined
                ? "Нет доступа к Календарю."
                : "Нет доступа к Календарю. Разрешите его в Системных настройках → Конфиденциальность → Календари."
            return false
        }

        if access.canRead {
            let predicate = store.predicateForEvents(withStart: invite.start, end: invite.end, calendars: nil)
            let duplicate = store.events(matching: predicate).contains {
                $0.title == invite.title && $0.startDate == invite.start
            }
            if duplicate {
                lastError = nil
                return true
            }
        }

        guard let calendar = store.defaultCalendarForNewEvents else {
            lastError = "Не выбран календарь по умолчанию. Укажите его в настройках Календаря."
            return false
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = invite.title
        event.startDate = invite.start
        event.endDate = max(invite.end, invite.start.addingTimeInterval(15 * 60))
        if !invite.location.isEmpty { event.location = invite.location }
        if let notes, !notes.isEmpty { event.notes = notes }

        do {
            try store.save(event, span: .thisEvent, commit: true)
            lastError = nil
            return true
        } catch {
            lastError = "Не удалось добавить встречу: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Календарь macOS

    /// Открывает Календарь. У macOS нет публичного способа «перейти к дате», поэтому
    /// открываем первое событие этого дня (если есть доступ), иначе просто приложение.
    func openInCalendar(date: Date, eventID: String? = nil) {
        let target = eventID ?? events(on: date).first(where: { !$0.isAllDay })?.id ?? events(on: date).first?.id
        if let target,
           let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.open(url) {
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
