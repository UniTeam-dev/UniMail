import Foundation

/// Modified UTF-7 для имён папок IMAP (RFC 3501 §5.1.3).
/// Печатный ASCII идёт как есть, «&» → «&-», остальное — UTF-16BE в base64 с «,» вместо «/» между «&» и «-».
enum IMAPUTF7 {
    static func encode(_ string: String) -> String {
        var out = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(pending.count * 2)
            for unit in pending {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(unit & 0xFF))
            }
            var b64 = Data(bytes).base64EncodedString()
            while b64.hasSuffix("=") { b64.removeLast() }
            out += "&" + b64.replacingOccurrences(of: "/", with: ",") + "-"
            pending.removeAll()
        }

        for scalar in string.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: String(scalar).utf16)
            }
        }
        flush()
        return out
    }

    /// Декодирование. Некорректные последовательности оставляются как есть
    /// (некоторые серверы присылают «&» без кодирования).
    static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        let chars = Array(string.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "&" else {
                out.append(c)
                i += 1
                continue
            }
            var j = i + 1
            while j < chars.count, chars[j] != "-" { j += 1 }
            guard j < chars.count else {
                out.append(contentsOf: chars[i...])
                break
            }
            if j == i + 1 {
                out.append("&")
                i = j + 1
                continue
            }
            var b64 = String(String.UnicodeScalarView(chars[(i + 1)..<j])).replacingOccurrences(of: ",", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            if let data = Data(base64Encoded: b64), data.count % 2 == 0, !data.isEmpty {
                var units: [UInt16] = []
                var k = data.startIndex
                while k < data.endIndex {
                    units.append(UInt16(data[k]) << 8 | UInt16(data[data.index(after: k)]))
                    k = data.index(k, offsetBy: 2)
                }
                if let decoded = decodeUTF16Strict(units) {
                    out.append(contentsOf: decoded.unicodeScalars)
                    i = j + 1
                    continue
                }
            }
            // Не base64 — оставляем исходный текст.
            out.append(contentsOf: chars[i...j])
            i = j + 1
        }
        return String(out)
    }

    private static func decodeUTF16Strict(_ units: [UInt16]) -> String? {
        var result = String.UnicodeScalarView()
        var iterator = units.makeIterator()
        var codec = UTF16()
        loop: while true {
            switch codec.decode(&iterator) {
            case .scalarValue(let s): result.append(s)
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        return String(result)
    }
}
