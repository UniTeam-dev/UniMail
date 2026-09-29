import Foundation
#if canImport(CoreFoundation) && canImport(Darwin)
import CoreFoundation
#endif

/// Декодирование байтов в строку по имени кодировки из MIME (`charset=`).
///
/// Кириллические и западноевропейские однобайтовые кодировки разбираются собственными таблицами —
/// так результат одинаков на macOS и Linux (в swift-corelibs-foundation нет windows-1251 и KOI8).
/// Для остальных имён на macOS используется `CFStringConvertIANACharSetNameToEncoding`.
/// Функция никогда не падает: на неизвестной кодировке или битых данных — UTF-8, если байты валидны,
/// иначе windows-1252 (надмножество latin1).
enum TextEncodings {
    static func decode(_ data: Data, charset: String?) -> String {
        decode(bytes: [UInt8](data), charset: charset)
    }

    static func decode(bytes: [UInt8], charset: String?) -> String {
        if bytes.isEmpty { return "" }
        let name = normalize(charset)
        switch name {
        case "utf-8", "utf8", "unicode-1-1-utf-8", "x-unicode20utf8":
            return String(decoding: stripUTF8BOM(bytes), as: UTF8.self)
        case "us-ascii", "ascii", "ansi_x3.4-1968", "iso646-us", "646", "cp367", "":
            // Письма с «us-ascii», в которых на деле 8-битный текст, — почти всегда UTF-8.
            if let s = strictUTF8(bytes) { return s }
            return decodeSingleByte(bytes, table: SingleByteTables.windows1252)
        case "windows-1251", "cp1251", "x-cp1251", "win-1251", "cp-1251", "ms-cyrl", "windows1251":
            return decodeSingleByte(bytes, table: SingleByteTables.windows1251)
        case "koi8-r", "koi8r", "koi8", "cskoi8r":
            return decodeSingleByte(bytes, table: SingleByteTables.koi8r)
        case "koi8-u", "koi8u", "koi8-ru":
            return decodeSingleByte(bytes, table: SingleByteTables.koi8u)
        case "iso-8859-5", "iso8859-5", "iso_8859-5", "cyrillic", "csisolatincyrillic":
            return decodeSingleByte(bytes, table: SingleByteTables.iso88595)
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "cp819", "ibm819",
             "windows-1252", "cp1252", "x-cp1252", "iso-8859-15", "iso8859-15", "latin-9", "latin9":
            // Как в WHATWG: latin1 трактуем как windows-1252 (кавычки «умные», € и т.п.).
            var table = SingleByteTables.windows1252
            if ["iso-8859-15", "iso8859-15", "latin-9", "latin9"].contains(name) {
                // ISO-8859-15: отличия от latin1 в 8 позициях.
                table = SingleByteTables.latin1
                for (b, u) in [(0xA4, 0x20AC), (0xA6, 0x160), (0xA8, 0x161), (0xB4, 0x17D), (0xB8, 0x17E), (0xBC, 0x152), (0xBD, 0x153), (0xBE, 0x178)] {
                    table[b - 0x80] = UInt16(u)
                }
            }
            return decodeSingleByte(bytes, table: table)
        case "utf-16", "utf16", "ucs-2", "unicode":
            if let s = String(data: Data(bytes), encoding: .utf16) { return s }
        case "utf-16le", "utf16le":
            if let s = String(data: Data(bytes), encoding: .utf16LittleEndian) { return s }
        case "utf-16be", "utf16be":
            if let s = String(data: Data(bytes), encoding: .utf16BigEndian) { return s }
        default:
            break
        }
        if let s = systemDecode(bytes, charset: name) { return s }
        if let s = strictUTF8(bytes) { return s }
        return decodeSingleByte(bytes, table: SingleByteTables.windows1252)
    }

    /// Нормализованное имя кодировки: без кавычек, пробелов, языкового суффикса RFC 2231 (`utf-8*ru`).
    static func normalize(_ charset: String?) -> String {
        guard var s = charset?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return "" }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let star = s.firstIndex(of: "*") { s = String(s[..<star]) }
        return s
    }

    /// Строгий UTF-8: nil, если байты не валидны.
    static func strictUTF8(_ bytes: [UInt8]) -> String? {
        String(bytes: stripUTF8BOM(bytes), encoding: .utf8)
    }

    static func isValidUTF8(_ bytes: [UInt8]) -> Bool { strictUTF8(bytes) != nil }

    private static func stripUTF8BOM(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return bytes[3...] }
        return bytes[...]
    }

    static func decodeSingleByte(_ bytes: [UInt8], table: [UInt16]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for b in bytes {
            let code: UInt32 = b < 0x80 ? UInt32(b) : UInt32(table[Int(b) - 0x80])
            scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
        }
        return String(scalars)
    }

    /// Прочие кодировки (gb2312, shift_jis, iso-2022-jp, big5, cp866…) — через CoreFoundation на macOS.
    private static func systemDecode(_ bytes: [UInt8], charset: String) -> String? {
        guard !charset.isEmpty else { return nil }
        #if canImport(CoreFoundation) && canImport(Darwin)
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        let ns = CFStringConvertEncodingToNSStringEncoding(cf)
        return String(data: Data(bytes), encoding: String.Encoding(rawValue: ns))
        #else
        let map: [String: String.Encoding] = [
            "shift_jis": .shiftJIS, "sjis": .shiftJIS, "iso-2022-jp": .iso2022JP, "euc-jp": .japaneseEUC,
            "iso-8859-2": .isoLatin2, "windows-1250": .windowsCP1250, "cp1250": .windowsCP1250,
            "windows-1253": .windowsCP1253, "windows-1254": .windowsCP1254, "macintosh": .macOSRoman,
        ]
        guard let enc = map[charset] else { return nil }
        return String(data: Data(bytes), encoding: enc)
        #endif
    }
}

/// Верхние половины (0x80…0xFF) однобайтовых кодировок.
enum SingleByteTables {
    static let latin1: [UInt16] = (0x80...0xFF).map { UInt16($0) }

    static let windows1252: [UInt16] = {
        var t = latin1
        let c1: [UInt16] = [0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
                            0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178]
        for (i, u) in c1.enumerated() { t[i] = u }
        return t
    }()

    static let windows1251: [UInt16] = {
        var t: [UInt16] = [
            0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
            0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
            0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
            0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
        ]
        t += (0x0410...0x044F).map { UInt16($0) }
        return t
    }()

    static let koi8r: [UInt16] = [
        0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C, 0x2580, 0x2584, 0x2588, 0x258C, 0x2590,
        0x2591, 0x2592, 0x2593, 0x2320, 0x25A0, 0x2219, 0x221A, 0x2248, 0x2264, 0x2265, 0x00A0, 0x2321, 0x00B0, 0x00B2, 0x00B7, 0x00F7,
        0x2550, 0x2551, 0x2552, 0x0451, 0x2553, 0x2554, 0x2555, 0x2556, 0x2557, 0x2558, 0x2559, 0x255A, 0x255B, 0x255C, 0x255D, 0x255E,
        0x255F, 0x2560, 0x2561, 0x0401, 0x2562, 0x2563, 0x2564, 0x2565, 0x2566, 0x2567, 0x2568, 0x2569, 0x256A, 0x256B, 0x256C, 0x00A9,
        0x044E, 0x0430, 0x0431, 0x0446, 0x0434, 0x0435, 0x0444, 0x0433, 0x0445, 0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E,
        0x043F, 0x044F, 0x0440, 0x0441, 0x0442, 0x0443, 0x0436, 0x0432, 0x044C, 0x044B, 0x0437, 0x0448, 0x044D, 0x0449, 0x0447, 0x044A,
        0x042E, 0x0410, 0x0411, 0x0426, 0x0414, 0x0415, 0x0424, 0x0413, 0x0425, 0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E,
        0x041F, 0x042F, 0x0420, 0x0421, 0x0422, 0x0423, 0x0416, 0x0412, 0x042C, 0x042B, 0x0417, 0x0428, 0x042D, 0x0429, 0x0427, 0x042A,
    ]

    static let koi8u: [UInt16] = {
        var t = koi8r
        for (b, u) in [(0xA4, 0x0454), (0xA6, 0x0456), (0xA7, 0x0457), (0xAD, 0x0491),
                       (0xB4, 0x0404), (0xB6, 0x0406), (0xB7, 0x0407), (0xBD, 0x0490)] {
            t[b - 0x80] = UInt16(u)
        }
        return t
    }()

    static let iso88595: [UInt16] = (0x80...0xFF).map { b -> UInt16 in
        switch b {
        case 0x80...0xA0, 0xAD: return UInt16(b)
        case 0xF0: return 0x2116
        case 0xFD: return 0x00A7
        default: return UInt16(b + 0x360)
        }
    }
}

/// Кодеки Content-Transfer-Encoding.
enum MIMECodec {
    // MARK: Base64

    private static let b64Decode: [Int8] = {
        var t = [Int8](repeating: -1, count: 256)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() { t[Int(c)] = Int8(i) }
        // URL-safe алфавит тоже принимаем.
        t[Int(UInt8(ascii: "-"))] = 62
        t[Int(UInt8(ascii: "_"))] = 63
        return t
    }()

    /// Терпимый декодер: пропускает переводы строк и мусор, не требует паддинга.
    static func decodeBase64<C: Collection>(_ input: C) -> [UInt8] where C.Element == UInt8 {
        // Быстрый путь — Foundation (корректный base64 с переносами строк).
        if let d = Data(base64Encoded: Data(input), options: .ignoreUnknownCharacters) { return [UInt8](d) }
        // Терпимый путь: без паддинга, с мусором, склеенные блоки.
        var out = [UInt8]()
        out.reserveCapacity(input.count * 3 / 4)
        var acc: UInt32 = 0
        var bits = 0
        b64Decode.withUnsafeBufferPointer { table in
            for c in input {
                if c == UInt8(ascii: "=") {
                    // Паддинг: сбрасываем остаток группы, но продолжаем (склеенные base64-блоки).
                    acc = 0; bits = 0
                    continue
                }
                let v = table[Int(c)]
                if v < 0 { continue }
                acc = (acc << 6) | UInt32(v)
                bits += 6
                if bits >= 8 {
                    bits -= 8
                    out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
                }
            }
        }
        return out
    }

    static func encodeBase64(_ bytes: [UInt8], lineLength: Int = 76) -> String {
        let encoded = Data(bytes).base64EncodedString()
        guard lineLength > 0, encoded.count > lineLength else { return encoded }
        var lines: [Substring] = []
        var idx = encoded.startIndex
        while idx < encoded.endIndex {
            let end = encoded.index(idx, offsetBy: lineLength, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(encoded[idx..<end])
            idx = end
        }
        return lines.joined(separator: "\r\n")
    }

    // MARK: Quoted-printable

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    /// Декодирование QP. `header: true` — Q-кодирование RFC 2047 («_» = пробел).
    static func decodeQuotedPrintable<C: Collection>(_ input: C, header: Bool = false) -> [UInt8] where C.Element == UInt8, C.Index == Int {
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        let end = input.endIndex
        while i < end {
            let c = input[i]
            if c == UInt8(ascii: "=") {
                // Мягкий перенос: "=" + (пробелы) + CRLF / LF.
                var j = i + 1
                while j < end, input[j] == 32 || input[j] == 9 { j += 1 }
                if j < end, input[j] == 13 || input[j] == 10 {
                    if input[j] == 13, j + 1 < end, input[j + 1] == 10 { j += 1 }
                    i = j + 1
                    continue
                }
                if j == end, !header { i = end; continue }   // «=» в самом конце — мягкий перенос
                if i + 2 < end, let h = hexValue(input[i + 1]), let l = hexValue(input[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                out.append(c)
                i += 1
            } else if header && c == UInt8(ascii: "_") {
                out.append(32)
                i += 1
            } else if !header && (c == 32 || c == 9) {
                // Хвостовые пробелы перед концом строки по RFC 2045 удаляются.
                var j = i
                while j < end, input[j] == 32 || input[j] == 9 { j += 1 }
                if j == end || input[j] == 13 || input[j] == 10 {
                    i = j
                } else {
                    out.append(contentsOf: input[i..<j])
                    i = j
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// QP-кодирование текста (строки уже с CRLF). Строки ≤ 76 символов, мягкие переносы «=».
    static func encodeQuotedPrintable(_ bytes: [UInt8]) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + bytes.count / 3)
        var lineLen = 0
        var i = 0
        let n = bytes.count

        func emit(_ token: [UInt8]) {
            if lineLen + token.count > 75 {
                out.append(contentsOf: [61, 13, 10]) // "=\r\n"
                lineLen = 0
            }
            out.append(contentsOf: token)
            lineLen += token.count
        }

        while i < n {
            let b = bytes[i]
            if b == 13, i + 1 < n, bytes[i + 1] == 10 {
                out.append(contentsOf: [13, 10])
                lineLen = 0
                i += 2
                continue
            }
            let atLineEnd = i + 1 == n || (bytes[i + 1] == 13 && i + 2 < n && bytes[i + 2] == 10)
            let literal: Bool
            switch b {
            case 32, 9: literal = !atLineEnd
            case 61: literal = false
            case 33...126: literal = !(b == 46 && lineLen == 0) // точку в начале строки кодируем: безопаснее для SMTP
            default: literal = false
            }
            if literal {
                emit([b])
            } else {
                emit([61, hex[Int(b >> 4)], hex[Int(b & 0x0F)]])
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
