import Foundation

enum AppMode: String, Hashable, Sendable {
    case mail, schedule
}

/// Вид «Расписания».
enum ScheduleRange: String, CaseIterable, Hashable, Sendable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "День"
        case .week: "Неделя"
        case .month: "Месяц"
        }
    }
}

/// Слои ленты расписания (переключатели «На ленте»).
enum ScheduleLayer: String, CaseIterable, Hashable, Sendable {
    case meetingsFromMail, sends, snoozeReturns

    var title: String {
        switch self {
        case .meetingsFromMail: "Встречи из писем"
        case .sends: "Отправка писем"
        case .snoozeReturns: "Возврат отложенных"
        }
    }

    var symbol: String {
        switch self {
        case .meetingsFromMail: "envelope"
        case .sends: "paperplane.circle"
        case .snoozeReturns: "clock.arrow.circlepath"
        }
    }
}

/// Встреча на ленте дня.
struct ScheduleEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var start: Date
    var end: Date
    /// Ящик, к которому относится встреча; nil — событие системного календаря.
    var accountID: UUID?
    /// Цвет календаря (hex) для событий из системного Календаря.
    var colorHex: UInt32? = nil
    /// Встреча из письма (приглашение ещё без ответа) — рисуется пунктиром.
    var fromMail = false
}

/// Метка на ленте: письмо уйдёт по расписанию или вернётся из «Отложенных».
struct ScheduleMarker: Identifiable, Hashable {
    enum Kind { case send, snoozeReturn }
    var id: String
    var kind: Kind
    var date: Date
    var text: String
    var accountID: UUID
    var threadID: String
}

/// Пункт недельной повестки справа.
struct AgendaItem: Identifiable, Hashable {
    enum Kind { case event, fromMail, task, send, snoozeReturn }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var date: Date
    var timeText: String
    var accountID: UUID
    var tag: String?

    var symbol: String {
        switch kind {
        case .event: "calendar"
        case .fromMail: "envelope.fill"
        case .task: "checkmark.circle.fill"
        case .send: "paperplane.circle.fill"
        case .snoozeReturn: "clock.fill"
        }
    }

    var dashed: Bool { kind == .fromMail || kind == .task }
}

/// День недельной повестки.
struct AgendaDay: Identifiable {
    var day: Date
    var items: [AgendaItem]
    var id: Date { day }
}
