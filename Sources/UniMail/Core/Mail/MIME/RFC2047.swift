import Foundation

/// Encoded-words в заголовках (RFC 2047): `=?charset?B|Q?text?=`.
enum RFC2047 {
    /// Декодирует все encoded-words в строке. Пробелы между соседними encoded-words удаляются;
    /// байты соседних слов с одной кодировкой склеиваются до декодирования — это чинит
    /// UTF-8-символы, разрезанные между словами (частая ошибка отправителей).
    static func decode(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let bytes = Array(s.utf8)
        let n = bytes.count
        var result = ""
        var literalStart = 0
        var pendingCharset: String?
        var pendingBytes: [UInt8] = []
        /// Текст между предыдущим encoded-word и текущей позицией (если только пробелы — выкидывается).
        var i = 0

        func flushPending() {
            if let cs = pendingCharset {
                result += TextEncodings.decode(bytes: pendingBytes, charset: cs)
                pendingCharset = nil
                pendingBytes = []
            }
        }

        while i < n {
            guard bytes[i] == UInt8(ascii: "="), i + 1 < n, bytes[i + 1] == UInt8(ascii: "?"),
                  let word = parseWord(bytes, at: i) else {
                i += 1
                continue
            }
            let between = bytes[literalStart..<i]
            let onlySpace = between.allSatisfy { $0 == 32 || $0 == 9 || $0 == 13 || $0 == 10 }
            if pendingCharset != nil && onlySpace {
                // Соседние encoded-words: пробел между ними не значим.
                if TextEncodings.normalize(word.charset) == TextEncodings.normalize(pendingCharset) {
                    pendingBytes += word.bytes
                } else {
                    flushPending()
                    pendingCharset = word.charset
                    pendingBytes = word.bytes
                }
            } else {
                flushPending()
                result += String(decoding: between, as: UTF8.self)
                pendingCharset = word.charset
                pendingBytes = word.bytes
            }
            i = word.end
            literalStart = i
        }
        flushPending()
        if literalStart < n { result += String(decoding: bytes[literalStart..<n], as: UTF8.self) }
        return result
    }

    private struct Word { var charset: String; var bytes: [UInt8]; var end: Int }

    /// Разбор одного `=?cs?E?text?=`, начиная с позиции `start` (указывает на «=»).
    private static func parseWord(_ b: [UInt8], at start: Int) -> Word? {
        let n = b.count
        var i = start + 2
        let csStart = i
        while i < n, b[i] != UInt8(ascii: "?") {
            if b[i] <= 32 || i - csStart > 40 { return nil }
            i += 1
        }
        guard i + 2 < n, i > csStart else { return nil }
        let charset = String(decoding: b[csStart..<i], as: UTF8.self)
        let enc = b[i + 1] | 0x20 // в нижний регистр
        guard enc == UInt8(ascii: "b") || enc == UInt8(ascii: "q"), b[i + 2] == UInt8(ascii: "?") else { return nil }
        let textStart = i + 3
        var j = textStart
        // Конец слова — «?=». В Q-тексте «?» не бывает, в B — тоже.
        while j + 1 < n {
            if b[j] == UInt8(ascii: "?") && b[j + 1] == UInt8(ascii: "=") { break }
            if b[j] == 13 || b[j] == 10 { return nil }
            j += 1
        }
        guard j + 1 < n else { return nil }
        let text = b[textStart..<j]
        let bytes = enc == UInt8(ascii: "b")
            ? MIMECodec.decodeBase64(text)
            : MIMECodec.decodeQuotedPrintable(text, header: true)
        return Word(charset: charset, bytes: bytes, end: j + 2)
    }

    /// Кодирует строку в B-encoded-words UTF-8, если в ней есть не-ASCII (или похожее на encoded-word).
    /// Слова ≤ 68 символов (≤ 75 по RFC), разделены пробелом — по нему заголовок можно переносить.
    /// Символы UTF-8 не разрезаются между словами.
    static func encode(_ s: String) -> String {
        if !needsEncoding(s) { return s }
        let maxBytes = 42 // 42 байта → 56 символов base64 → слово из 68 символов
        var words: [String] = []
        var chunk: [UInt8] = []
        for ch in s.unicodeScalars {
            let enc = Array(String(ch).utf8)
            if chunk.count + enc.count > maxBytes, !chunk.isEmpty {
                words.append("=?UTF-8?B?" + Data(chunk).base64EncodedString() + "?=")
                chunk = []
            }
            chunk += enc
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?" + Data(chunk).base64EncodedString() + "?=") }
        return words.joined(separator: " ")
    }

    static func needsEncoding(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value > 126 || ($0.value < 32 && $0 != "\t") } || s.contains("=?")
    }
}
