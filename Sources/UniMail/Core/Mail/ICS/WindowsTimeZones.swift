import Foundation

/// Windows-имена часовых поясов (Outlook/Exchange пишут их в TZID) → IANA.
/// По данным CLDR windowsZones.xml, территория «001».
enum WindowsTimeZones {
    /// Обратно: IANA → Windows-имя (для Exchange: встречи «весь день» задаются поясом).
    static func windows(for zone: TimeZone = .current) -> String? {
        if zone.identifier == "UTC" || zone.identifier == "GMT" { return "UTC" }
        let preferred = ["Europe/Moscow": "Russian Standard Time", "Europe/Kyiv": "FLE Standard Time"]
        if let name = preferred[zone.identifier] { return name }
        return map.keys.sorted().first { map[$0] == zone.identifier }
    }

    static func iana(for windowsName: String) -> String? {
        let key = windowsName.trimmingCharacters(in: .whitespaces)
        if let v = map[key] { return v }
        return lowercased[key.lowercased()]
    }

    private static let lowercased: [String: String] = {
        var d: [String: String] = [:]
        for (k, v) in map { d[k.lowercased()] = v }
        return d
    }()

    static let map: [String: String] = [
        // Россия и СНГ
        "Russian Standard Time": "Europe/Moscow",
        "Kaliningrad Standard Time": "Europe/Kaliningrad",
        "Volgograd Standard Time": "Europe/Volgograd",
        "Astrakhan Standard Time": "Europe/Astrakhan",
        "Saratov Standard Time": "Europe/Saratov",
        "Russia Time Zone 3": "Europe/Samara",
        "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
        "Omsk Standard Time": "Asia/Omsk",
        "N. Central Asia Standard Time": "Asia/Novosibirsk",
        "Altai Standard Time": "Asia/Barnaul",
        "Tomsk Standard Time": "Asia/Tomsk",
        "North Asia Standard Time": "Asia/Krasnoyarsk",
        "North Asia East Standard Time": "Asia/Irkutsk",
        "Transbaikal Standard Time": "Asia/Chita",
        "Yakutsk Standard Time": "Asia/Yakutsk",
        "Vladivostok Standard Time": "Asia/Vladivostok",
        "Sakhalin Standard Time": "Asia/Sakhalin",
        "Magadan Standard Time": "Asia/Magadan",
        "Russia Time Zone 10": "Asia/Srednekolymsk",
        "Russia Time Zone 11": "Asia/Kamchatka",
        "Belarus Standard Time": "Europe/Minsk",
        "FLE Standard Time": "Europe/Kiev",
        "E. Europe Standard Time": "Europe/Chisinau",
        "Caucasus Standard Time": "Asia/Yerevan",
        "Georgian Standard Time": "Asia/Tbilisi",
        "Azerbaijan Standard Time": "Asia/Baku",
        "West Asia Standard Time": "Asia/Tashkent",
        "Central Asia Standard Time": "Asia/Almaty",
        "Qyzylorda Standard Time": "Asia/Qyzylorda",
        "Ekaterinburg": "Asia/Yekaterinburg",
        // Европа
        "UTC": "UTC",
        "Coordinated Universal Time": "UTC",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw",
        "Romance Standard Time": "Europe/Paris",
        "GTB Standard Time": "Europe/Bucharest",
        "Turkey Standard Time": "Europe/Istanbul",
        "E. Europe": "Europe/Chisinau",
        // Ближний Восток, Африка
        "Israel Standard Time": "Asia/Jerusalem",
        "Egypt Standard Time": "Africa/Cairo",
        "South Africa Standard Time": "Africa/Johannesburg",
        "Arabian Standard Time": "Asia/Dubai",
        "Arab Standard Time": "Asia/Riyadh",
        "Iran Standard Time": "Asia/Tehran",
        // Азия, Океания
        "India Standard Time": "Asia/Kolkata",
        "China Standard Time": "Asia/Shanghai",
        "Singapore Standard Time": "Asia/Singapore",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "SE Asia Standard Time": "Asia/Bangkok",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "New Zealand Standard Time": "Pacific/Auckland",
        // Америка
        "Eastern Standard Time": "America/New_York",
        "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver",
        "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles",
        "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Atlantic Standard Time": "America/Halifax",
        "Canada Central Standard Time": "America/Regina",
        "SA Pacific Standard Time": "America/Bogota",
        "E. South America Standard Time": "America/Sao_Paulo",
        "Argentina Standard Time": "America/Buenos_Aires",
        "Central America Standard Time": "America/Guatemala",
        "Mexico Standard Time": "America/Mexico_City",
        "Central Standard Time (Mexico)": "America/Mexico_City",
    ]
}
