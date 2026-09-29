import Foundation

/// Ответ на приглашение (мой статус во встрече).
enum EventResponse: String, Codable, Hashable, Sendable {
    case none, accepted, tentative, declined, organizer

    var title: String {
        switch self {
        case .none: "Ждёт ответа"
        case .accepted: "Принято"
        case .tentative: "Под вопросом"
        case .declined: "Отклонено"
        case .organizer: "Вы организатор"
        }
    }

    var symbol: String {
        switch self {
        case .none: "questionmark.circle"
        case .accepted: "checkmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .organizer: "person.crop.circle.badge.checkmark"
        }
    }

    init(partStat: String?) {
        switch partStat?.uppercased() {
        case "ACCEPTED": self = .accepted
        case "TENTATIVE": self = .tentative
        case "DECLINED": self = .declined
        default: self = .none
        }
    }
}

/// Участник встречи.
struct EventAttendee: Codable, Hashable, Sendable {
    var name: String?
    var email: String
    var response: EventResponse = .none
    var optional = false

    var display: String { (name?.isEmpty == false ? name : nil) ?? email }
}

/// Встреча календаря — из Exchange, из системного Календаря или из письма-приглашения.
struct CalendarEvent: Identifiable, Codable, Hashable, Sendable {
    enum Source: String, Codable, Hashable, Sendable {
        /// Календарь Exchange (EWS) — id события на сервере.
        case exchange
        /// Календарь macOS (EventKit).
        case system
        /// Приглашение из письма, в календаре его ещё нет.
        case mail
    }

    /// Уникален в интерфейсе: `"<accountID>|<id на сервере>"`, `"ek-<id>"`, `"invite-<messageID>"`.
    var id: String
    var source: Source
    /// Ящик (Exchange и приглашения из писем).
    var accountID: UUID?
    /// Id на сервере / в EventKit / id письма.
    var remoteID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var location: String = ""
    var notes: String = ""
    var organizer: EventAttendee?
    var attendees: [EventAttendee] = []
    var myResponse: EventResponse = .organizer
    /// Встреча с участниками (не личное событие).
    var isMeeting = false
    var isCancelled = false
    var isRecurring = false
    /// Название календаря («Календарь», «ilya», «Работа (Google)»).
    var calendarTitle: String = ""
    /// Цвет календаря для системных событий (0xRRGGBB).
    var colorHex: UInt32?
    /// Можно изменить и удалить.
    var canEdit = true
    /// Письмо с приглашением, если есть (кнопка «Открыть письмо»).
    var messageID: String?
    /// Подробности (участники, описание) ещё не загружены.
    var detailsPending = false
    /// Календарь macOS из учётной записи Exchange: ответить можно через сервер ящика.
    var calendarIsExchange = false
    /// Встреча из Календаря macOS, которую можно найти на сервере Exchange ящика.
    var serverLinked = false

    var needsResponse: Bool { canRespond && myResponse == .none }
    var canRespond: Bool { isMeeting && myResponse != .organizer && !isCancelled && (source != .system || serverLinked) }

    /// Тема для сравнения: без регистра и лишних пробелов.
    static func normalizedTitle(_ title: String) -> String {
        title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Ссылка на видеовстречу (Teams, Zoom, Meet, Телемост…) из места или описания.
    var meetingURL: URL? { Self.meetingURL(in: location + "\n" + notes) }

    static func meetingURL(in text: String) -> URL? {
        let hosts = ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "telemost.yandex",
                     "webex.com", "skype.com", "meet.jit.si", "ktalk.ru", "sferum.ru", "vk.com/call", "salutejazz.ru",
                     "jazz.sber.ru", "dion.vc", "trueconf", "xlnk.ms", "express.ms", "mts-link.ru", "my.mts-link.ru",
                     "webinar.ru", "bbb", "whereby.com", "gotomeeting.com"]
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'\)\]]+"#, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            var string = String(text[r])
            while let last = string.last, ".,;:!?»".contains(last) { string.removeLast() }
            guard hosts.contains(where: { string.lowercased().contains($0) }), let url = URL(string: string) else { continue }
            return url
        }
        return nil
    }

    /// Пересекается с интервалом.
    func overlaps(_ start: Date, _ end: Date) -> Bool { self.start < end && self.end > start }
}

/// Новая или изменённая встреча (редактор).
struct EventDraft: Hashable, Sendable {
    /// Нет — новая встреча.
    var remoteID: String?
    var title: String = ""
    var start: Date
    var end: Date
    var isAllDay = false
    var location: String = ""
    var notes: String = ""
    /// Адреса приглашённых.
    var attendees: [Address] = []
    /// Напоминание, минут до начала (nil — без напоминания).
    var reminderMinutes: Int? = 15
    /// Список участников меняли (иначе при сохранении его не трогаем — участники Exchange не теряются).
    var attendeesChanged = true

    init(start: Date, duration: TimeInterval = 3600) {
        self.start = start
        self.end = start.addingTimeInterval(duration)
    }

    init(event: CalendarEvent) {
        remoteID = event.remoteID
        title = event.title
        start = event.start
        end = event.end
        isAllDay = event.isAllDay
        location = event.location
        notes = event.notes
        attendees = event.attendees.map { Address(name: $0.name, email: $0.email) }
        attendeesChanged = false
        if event.isAllDay {
            // Конец «весь день» — следующая полночь (EventKit отдаёт 23:59:59 последнего дня).
            let calendar = Calendar.current
            let lastDay = calendar.startOfDay(for: max(event.start, event.end.addingTimeInterval(-1)))
            end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? event.end
        }
    }
}
