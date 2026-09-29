import Foundation

// Промежуточная модель форматированного текста письма и её сериализация в plain text и HTML.
// Файл намеренно зависит только от Foundation — он компилируется и проверяется на Linux
// (Tests/LinuxChecks/RichText). Мост к NSAttributedString — в RichTextEditor.swift.

/// Размер текста в редакторе: мелкий / обычный / крупный.
enum RichTextSize: String, CaseIterable, Sendable {
    case small, normal, large

    /// Кегль в редакторе (обычный — 13.5 pt, как в макете).
    var points: Double {
        switch self {
        case .small: return 11.5
        case .normal: return 13.5
        case .large: return 17
        }
    }

    /// Значение CSS font-size; для обычного размера span не нужен.
    var cssValue: String? {
        switch self {
        case .small: return "small"
        case .normal: return nil
        case .large: return "large"
        }
    }

    /// Ближайший размер по кеглю шрифта.
    static func bucket(points: Double) -> RichTextSize {
        if points < 12.5 { return .small }
        if points > 15.25 { return .large }
        return .normal
    }
}

enum RichListKind: String, Sendable {
    case bullet, ordered

    var tag: String { self == .bullet ? "ul" : "ol" }
}

/// Начертание отрезка текста.
struct RichStyle: Hashable, Sendable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var link: String? = nil
    var size: RichTextSize = .normal

    var isPlain: Bool { self == RichStyle() }
}

/// Отрезок текста с одним начертанием. `isSignature` — служебная метка редактора (блок подписи),
/// в HTML и plain text не выводится.
struct RichRun: Hashable, Sendable {
    var text: String
    var style: RichStyle = RichStyle()
    var isSignature = false
}

/// Абзац: отрезки, признак пункта списка и уровень цитаты (0 — не цитата).
struct RichParagraph: Hashable, Sendable {
    var runs: [RichRun] = []
    var list: RichListKind? = nil
    var quoteLevel: Int = 0

    var text: String { runs.map(\.text).joined() }

    /// Пустой абзац (служебные символы вложений не считаются текстом).
    var isBlank: Bool {
        !text.unicodeScalars.contains { $0 != "\u{FFFC}" }
    }

    /// Пустая строка верхнего уровня — такие обрезаются по краям документа в HTML.
    var isBlankTopLevel: Bool { list == nil && quoteLevel == 0 && isBlank }
}

enum RichText {
    // MARK: Нумерация списков

    /// Номера пунктов нумерованных списков (0 — не нумерованный пункт).
    /// Список — подряд идущие нумерованные абзацы одного уровня цитаты.
    static func listNumbers(_ paragraphs: [RichParagraph]) -> [Int] {
        var result = [Int](repeating: 0, count: paragraphs.count)
        var counter = 0
        var previousLevel: Int? = nil
        for (index, paragraph) in paragraphs.enumerated() {
            if paragraph.list == .ordered {
                counter = previousLevel == paragraph.quoteLevel ? counter + 1 : 1
                previousLevel = paragraph.quoteLevel
                result[index] = counter
            } else {
                counter = 0
                previousLevel = nil
            }
        }
        return result
    }

    // MARK: Plain text

    /// Plain text для `draft.body`: маркеры «• », «1. », цитаты «> ».
    static func plainText(_ paragraphs: [RichParagraph]) -> String {
        let numbers = listNumbers(paragraphs)
        var lines: [String] = []
        lines.reserveCapacity(paragraphs.count)
        for (index, paragraph) in paragraphs.enumerated() {
            let quotePrefix = String(repeating: "> ", count: max(0, paragraph.quoteLevel))
            var line = quotePrefix
            switch paragraph.list {
            case .bullet: line += "• "
            case .ordered: line += "\(numbers[index]). "
            case nil: break
            }
            line += plainInline(paragraph.text, continuationPrefix: quotePrefix)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Разрыв строки внутри абзаца (U+2028) становится переводом строки с тем же префиксом цитаты;
    /// символы вложений (U+FFFC) выбрасываются.
    static func plainInline(_ text: String, continuationPrefix: String = "") -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\u{FFFC}":
                continue
            case "\u{2028}", "\u{2029}":
                out += "\n" + continuationPrefix
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Разбор plain text: «> » — цитата (можно несколько), «• » и «N. » — пункты списков.
    static func parsePlain(_ text: String) -> [RichParagraph] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map(parsePlainLine)
    }

    static func parsePlainLine(_ line: String) -> RichParagraph {
        var rest = Substring(line)
        var level = 0
        while rest.first == ">" {
            rest = rest.dropFirst()
            level += 1
            if rest.first == " " { rest = rest.dropFirst() }
        }
        var list: RichListKind? = nil
        if rest.hasPrefix("• ") {
            list = .bullet
            rest = rest.dropFirst(2)
        } else if let length = orderedPrefixLength(rest) {
            list = .ordered
            rest = rest.dropFirst(length)
        }
        let runs = rest.isEmpty ? [] : [RichRun(text: String(rest))]
        return RichParagraph(runs: runs, list: list, quoteLevel: level)
    }

    /// Длина префикса «12. » (1–3 цифры, точка, пробел) или nil.
    static func orderedPrefixLength(_ s: Substring) -> Int? {
        var digits = 0
        var index = s.startIndex
        while index < s.endIndex, let ascii = s[index].asciiValue, ascii >= 48, ascii <= 57 {
            digits += 1
            index = s.index(after: index)
            if digits > 3 { return nil }
        }
        guard digits > 0, index < s.endIndex, s[index] == "." else { return nil }
        index = s.index(after: index)
        guard index < s.endIndex, s[index] == " " else { return nil }
        return digits + 2
    }

    // MARK: HTML

    /// Есть ли в документе форматирование (иначе HTML-часть не нужна).
    static func hasFormatting(_ paragraphs: [RichParagraph]) -> Bool {
        paragraphs.contains { paragraph in
            paragraph.list != nil || paragraph.quoteLevel > 0
                || paragraph.runs.contains { !$0.style.isPlain && !$0.text.isEmpty }
        }
    }

    /// HTML для `draft.htmlBody` или nil, если форматирования нет совсем.
    static func html(_ paragraphs: [RichParagraph]) -> String? {
        hasFormatting(paragraphs) ? htmlFragment(paragraphs) : nil
    }

    static let blockquoteOpen = #"<blockquote style="margin:0 0 0 0.8ex;border-left:2px solid #ccc;padding-left:1ex">"#
    static let emptyParagraph = "<p><br></p>"

    /// Фрагмент HTML (без <html>/<body>).
    /// Подряд идущие строки — один <p> с <br>; пустая строка разделяет абзацы, каждая лишняя — <p><br></p>.
    /// Пустые строки на границе цитаты/списка сохраняются как <p><br></p>, по краям документа — отбрасываются.
    static func htmlFragment(_ input: [RichParagraph]) -> String {
        var paragraphs = input[...]
        while let first = paragraphs.first, first.isBlankTopLevel { paragraphs = paragraphs.dropFirst() }
        while let last = paragraphs.last, last.isBlankTopLevel { paragraphs = paragraphs.dropLast() }

        var out = ""
        var depth = 0
        var openList: RichListKind? = nil
        var lines: [String] = []
        var empties = 0
        var segmentHasGroup = false

        func flushGroup() {
            guard !lines.isEmpty else { return }
            out += "<p>" + lines.joined(separator: "<br>") + "</p>"
            lines = []
            segmentHasGroup = true
        }
        func endSegment() {
            flushGroup()
            out += String(repeating: emptyParagraph, count: empties)
            empties = 0
            segmentHasGroup = false
        }
        func closeList() {
            if let kind = openList {
                out += "</\(kind.tag)>"
                openList = nil
            }
        }

        for paragraph in paragraphs {
            let level = max(0, paragraph.quoteLevel)
            if level != depth {
                endSegment()
                closeList()
                while depth < level { out += blockquoteOpen; depth += 1 }
                while depth > level { out += "</blockquote>"; depth -= 1 }
            }
            if let kind = paragraph.list {
                endSegment()
                if openList != kind {
                    closeList()
                    out += "<\(kind.tag)>"
                    openList = kind
                }
                let body = inlineHTML(paragraph.runs)
                out += "<li>" + (body.isEmpty ? "<br>" : body) + "</li>"
            } else {
                closeList()
                if paragraph.isBlank {
                    flushGroup()
                    empties += 1
                } else {
                    if empties > 0 {
                        out += String(repeating: emptyParagraph, count: segmentHasGroup ? empties - 1 : empties)
                        empties = 0
                    }
                    lines.append(inlineHTML(paragraph.runs))
                }
            }
        }
        endSegment()
        closeList()
        while depth > 0 { out += "</blockquote>"; depth -= 1 }
        return out
    }

    /// Строчная разметка: <a><b><i><u><s><span style="font-size">текст</span></s></u></i></b></a>.
    static func inlineHTML(_ runs: [RichRun]) -> String {
        var out = ""
        var previousWasSpace = true // начало строки: ведущий пробел — &nbsp;
        for run in mergeRuns(runs) {
            var chunk = escapeText(run.text, previousWasSpace: &previousWasSpace)
            guard !chunk.isEmpty else { continue }
            let style = run.style
            if let css = style.size.cssValue { chunk = #"<span style="font-size:\#(css)">"# + chunk + "</span>" }
            if style.strikethrough { chunk = "<s>" + chunk + "</s>" }
            if style.underline { chunk = "<u>" + chunk + "</u>" }
            if style.italic { chunk = "<i>" + chunk + "</i>" }
            if style.bold { chunk = "<b>" + chunk + "</b>" }
            if let raw = style.link, let href = sanitizeLink(raw) {
                chunk = #"<a href="\#(escapeAttribute(href))">"# + chunk + "</a>"
            }
            out += chunk
        }
        return out
    }

    /// Склеивает соседние отрезки с одинаковым начертанием и выбрасывает пустые.
    static func mergeRuns(_ runs: [RichRun]) -> [RichRun] {
        var result: [RichRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.style == run.style, last.isSignature == run.isSignature {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }

    /// Экранирует текст для HTML. Повторные и ведущие пробелы — &nbsp;, U+2028 — <br>,
    /// табуляция — четыре &nbsp;, U+00A0 — &#160;.
    static func escapeText(_ text: String, previousWasSpace: inout Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"; previousWasSpace = false
            case "<": out += "&lt;"; previousWasSpace = false
            case ">": out += "&gt;"; previousWasSpace = false
            case "\"": out += "&quot;"; previousWasSpace = false
            case " ":
                out += previousWasSpace ? "&nbsp;" : " "
                previousWasSpace = true
            case "\t":
                out += "&nbsp;&nbsp;&nbsp;&nbsp;"
                previousWasSpace = true
            case "\u{00A0}":
                out += "&#160;"
                previousWasSpace = false
            case "\u{2028}", "\u{2029}", "\n", "\r":
                out += "<br>"
                previousWasSpace = true
            case "\u{FFFC}":
                continue
            default:
                out.unicodeScalars.append(scalar)
                previousWasSpace = false
            }
        }
        return out
    }

    static func escapeText(_ text: String) -> String {
        var previous = false
        return escapeText(text, previousWasSpace: &previous)
    }

    static func escapeAttribute(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel", "ftp"]

    /// Приводит введённую ссылку к безопасному виду: без схемы — https:// (или mailto: для адреса),
    /// javascript:, data: и прочие схемы отклоняются.
    static func sanitizeLink(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "\"" || $0 == "<" || $0 == ">" })
        else { return nil }

        if let colon = value.firstIndex(of: ":") {
            let scheme = String(value[..<colon]).lowercased()
            let afterColon = value[value.index(after: colon)...]
            let isHostPort = afterColon.first.map { $0.isASCII && $0.isNumber } ?? false
            let schemeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+-.")
            let looksLikeScheme = !scheme.isEmpty
                && scheme.unicodeScalars.allSatisfy { schemeChars.contains($0) }
                && (scheme.first.map { $0.isLetter } ?? false)
                && !scheme.contains(".")
            if looksLikeScheme && !isHostPort {
                return allowedSchemes.contains(scheme) ? value : nil
            }
        }
        if value.contains("@") && !value.contains("/") { return "mailto:" + value }
        return "https://" + value
    }

    // MARK: Разбор своего HTML (для восстановления черновика с форматированием)

    private enum Effect {
        case bold, italic, underline, strike, link(String?), size(RichTextSize), none
    }

    private enum SegmentItem {
        /// <p>: между соседними абзацами подразумевается пустая строка.
        case group([[RichRun]])
        /// <p><br></p>: лишняя пустая строка.
        case empty
        /// <div> (чужой HTML): строки без подразумеваемых пустых строк.
        case lines([[RichRun]])
    }

    /// Разбирает HTML, который построил `htmlFragment` (и терпимо — простой чужой HTML).
    static func parseHTML(_ html: String) -> [RichParagraph] {
        var parser = HTMLModelParser()
        parser.run(Array(html.unicodeScalars))
        return parser.paragraphs
    }

    private struct HTMLModelParser {
        var paragraphs: [RichParagraph] = []
        var depth = 0
        var listStack: [RichListKind] = []
        var styleStack: [(name: String, effect: Effect)] = []

        var segment: [SegmentItem] = []
        var inParagraph = false
        var paragraphIsDiv = false
        var lines: [[RichRun]] = []
        var line: [RichRun] = []
        var inListItem = false
        var itemRuns: [RichRun] = []

        var currentStyle: RichStyle {
            var style = RichStyle()
            for entry in styleStack {
                switch entry.effect {
                case .bold: style.bold = true
                case .italic: style.italic = true
                case .underline: style.underline = true
                case .strike: style.strikethrough = true
                case .link(let href): style.link = href
                case .size(let size): style.size = size
                case .none: break
                }
            }
            return style
        }

        mutating func run(_ s: [Unicode.Scalar]) {
            var i = 0
            var text = ""
            func isNameChar(_ c: Unicode.Scalar) -> Bool {
                (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
            }
            while i < s.count {
                let c = s[i]
                guard c == "<" else { text.unicodeScalars.append(c); i += 1; continue }
                // Комментарии и <!DOCTYPE>.
                if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                    flushText(&text)
                    var j = i + 4
                    while j + 2 < s.count, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
                    i = min(s.count, j + 3)
                    continue
                }
                var j = i + 1
                let closing = j < s.count && s[j] == "/"
                if closing { j += 1 }
                let nameStart = j
                while j < s.count, isNameChar(s[j]) { j += 1 }
                guard j > nameStart || (i + 1 < s.count && s[i + 1] == "!") else {
                    // Одиночный «<» — это текст.
                    text.unicodeScalars.append(c)
                    i += 1
                    continue
                }
                var name = ""
                for k in nameStart..<j { name.unicodeScalars.append(s[k]) }
                name = name.lowercased()
                // Атрибуты до «>» с учётом кавычек.
                var attributes = ""
                var quote: Unicode.Scalar? = nil
                while j < s.count {
                    let d = s[j]
                    if let q = quote {
                        if d == q { quote = nil }
                    } else if d == "\"" || d == "'" {
                        quote = d
                    } else if d == ">" {
                        break
                    }
                    attributes.unicodeScalars.append(d)
                    j += 1
                }
                i = min(s.count, j + 1)
                flushText(&text)
                if name == "style" || name == "script" || name == "head" || name == "title", !closing {
                    // Пропускаем содержимое до закрывающего тега.
                    let end = Array("</\(name)".unicodeScalars)
                    var k = i
                    while k + end.count <= s.count {
                        var match = true
                        for m in 0..<end.count where lower(s[k + m]) != end[m] { match = false; break }
                        if match { break }
                        k += 1
                    }
                    var e = k
                    while e < s.count, s[e] != ">" { e += 1 }
                    i = min(s.count, e + 1)
                    continue
                }
                if closing { closeTag(name) } else { openTag(name, attributes: attributes) }
            }
            flushText(&text)
            endBlock()
            endSegment()
        }

        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
            (c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32) ?? c : c
        }

        // MARK: Текст

        mutating func flushText(_ raw: inout String) {
            guard !raw.isEmpty else { return }
            defer { raw = "" }
            // Схлопываем пробельные символы исходника, затем раскрываем сущности.
            var collapsed = ""
            var lastWasSpace = false
            for scalar in raw.unicodeScalars {
                if scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
                    if !lastWasSpace { collapsed += " " }
                    lastWasSpace = true
                } else {
                    collapsed.unicodeScalars.append(scalar)
                    lastWasSpace = false
                }
            }
            if !inParagraph && !inListItem {
                if collapsed.trimmingCharacters(in: .whitespaces).isEmpty { return }
                inParagraph = true
                paragraphIsDiv = true
                lines = []
                line = []
            }
            if (inListItem ? itemRuns.isEmpty : line.isEmpty) {
                while collapsed.hasPrefix(" ") { collapsed.removeFirst() }
            }
            let decoded = RichText.decodeEntities(collapsed)
            guard !decoded.isEmpty else { return }
            let run = RichRun(text: decoded, style: currentStyle)
            if inListItem { itemRuns.append(run) } else { line.append(run) }
        }

        // MARK: Теги

        mutating func openTag(_ name: String, attributes: String) {
            switch name {
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "pre":
                if inListItem { return }
                endBlock()
                inParagraph = true
                paragraphIsDiv = name == "div"
                lines = []
                line = []
            case "br":
                if inListItem {
                    itemRuns.append(RichRun(text: "\u{2028}", style: currentStyle))
                } else {
                    if !inParagraph { inParagraph = true; paragraphIsDiv = true; lines = []; line = [] }
                    lines.append(line)
                    line = []
                }
            case "blockquote":
                endBlock()
                endSegment()
                depth += 1
            case "ul", "ol":
                endBlock()
                endSegment()
                listStack.append(name == "ol" ? .ordered : .bullet)
            case "li":
                endListItem()
                endBlock()
                endSegment()
                inListItem = true
                itemRuns = []
            case "b", "strong":
                styleStack.append((name, .bold))
            case "i", "em":
                styleStack.append((name, .italic))
            case "u", "ins":
                styleStack.append((name, .underline))
            case "s", "strike", "del":
                styleStack.append((name, .strike))
            case "a":
                styleStack.append((name, .link(RichText.attributeValue("href", in: attributes).map(RichText.decodeEntities))))
            case "span", "font":
                let style = RichText.attributeValue("style", in: attributes) ?? ""
                if let size = RichText.cssFontSize(style) {
                    styleStack.append((name, .size(size)))
                } else {
                    styleStack.append((name, .none))
                }
            default:
                break
            }
        }

        mutating func closeTag(_ name: String) {
            switch name {
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "pre":
                if inListItem { return }
                endBlock()
            case "blockquote":
                endListItem()
                endBlock()
                endSegment()
                depth = max(0, depth - 1)
            case "ul", "ol":
                endListItem()
                if !listStack.isEmpty { listStack.removeLast() }
            case "li":
                endListItem()
            default:
                if let index = styleStack.lastIndex(where: { $0.name == name }) {
                    styleStack.remove(at: index)
                }
            }
        }

        /// Закрывает текущий <p> (или неявный абзац) и кладёт его в сегмент.
        mutating func endBlock() {
            guard inParagraph else { return }
            inParagraph = false
            if !line.isEmpty || lines.isEmpty { lines.append(line) }
            line = []
            let merged = lines.map(RichText.mergeRuns)
            lines = []
            if paragraphIsDiv {
                paragraphIsDiv = false
                segment.append(.lines(merged))
            } else if merged.allSatisfy({ $0.isEmpty }) {
                segment.append(.empty)
            } else {
                segment.append(.group(merged))
            }
        }

        mutating func endListItem() {
            guard inListItem else { return }
            inListItem = false
            var runs = RichText.mergeRuns(itemRuns)
            itemRuns = []
            if runs.count == 1, runs[0].text == "\u{2028}" { runs = [] }
            paragraphs.append(RichParagraph(runs: runs, list: listStack.last ?? .bullet, quoteLevel: depth))
        }

        /// Переводит сегмент (абзацы между границами цитат/списков) в строки модели.
        mutating func endSegment() {
            var hadGroup = false
            var pendingEmpties = 0
            let blank = RichParagraph(runs: [], list: nil, quoteLevel: depth)
            for item in segment {
                switch item {
                case .empty:
                    pendingEmpties += 1
                case .group(let groupLines):
                    let count = hadGroup ? pendingEmpties + 1 : pendingEmpties
                    paragraphs.append(contentsOf: Array(repeating: blank, count: count))
                    pendingEmpties = 0
                    for runs in groupLines {
                        paragraphs.append(RichParagraph(runs: runs, list: nil, quoteLevel: depth))
                    }
                    hadGroup = true
                case .lines(let divLines):
                    paragraphs.append(contentsOf: Array(repeating: blank, count: pendingEmpties))
                    pendingEmpties = 0
                    for runs in divLines {
                        paragraphs.append(RichParagraph(runs: runs, list: nil, quoteLevel: depth))
                    }
                    hadGroup = false
                }
            }
            paragraphs.append(contentsOf: Array(repeating: blank, count: pendingEmpties))
            segment = []
        }
    }

    /// Значение атрибута из строки атрибутов тега: name="…", name='…' или name=…
    static func attributeValue(_ name: String, in attributes: String) -> String? {
        let scalars = Array(attributes.unicodeScalars)
        let target = Array(name.lowercased().unicodeScalars)
        var i = 0
        while i < scalars.count {
            // Ищем имя атрибута на границе слова.
            let boundary = i == 0 || CharacterSet.whitespacesAndNewlines.contains(scalars[i - 1])
            if boundary, i + target.count <= scalars.count {
                var match = true
                for k in 0..<target.count {
                    let c = scalars[i + k]
                    let lowered = (c >= "A" && c <= "Z") ? (Unicode.Scalar(c.value + 32) ?? c) : c
                    if lowered != target[k] { match = false; break }
                }
                if match {
                    var j = i + target.count
                    while j < scalars.count, scalars[j] == " " { j += 1 }
                    if j < scalars.count, scalars[j] == "=" {
                        j += 1
                        while j < scalars.count, scalars[j] == " " { j += 1 }
                        var value = ""
                        if j < scalars.count, scalars[j] == "\"" || scalars[j] == "'" {
                            let quote = scalars[j]
                            j += 1
                            while j < scalars.count, scalars[j] != quote { value.unicodeScalars.append(scalars[j]); j += 1 }
                        } else {
                            while j < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[j]), scalars[j] != "/" {
                                value.unicodeScalars.append(scalars[j]); j += 1
                            }
                        }
                        return value
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// font-size из inline-стиля: small/large и их варианты, px, pt, em, %.
    static func cssFontSize(_ style: String) -> RichTextSize? {
        let lowered = style.lowercased()
        guard let range = lowered.range(of: "font-size") else { return nil }
        var value = lowered[range.upperBound...].drop { $0 == " " || $0 == ":" }
        if let end = value.firstIndex(of: ";") { value = value[..<end] }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "small", "x-small", "xx-small", "smaller": return .small
        case "large", "x-large", "xx-large", "larger": return .large
        case "medium", "normal": return .normal
        default: break
        }
        let number = Double(trimmed.prefix { ($0.isASCII && $0.isNumber) || $0 == "." }) ?? 0
        guard number > 0 else { return nil }
        if trimmed.hasSuffix("px") { return number < 13 ? .small : (number > 16 ? .large : .normal) }
        if trimmed.hasSuffix("pt") { return number < 10 ? .small : (number > 12 ? .large : .normal) }
        if trimmed.hasSuffix("em") || trimmed.hasSuffix("rem") { return number < 0.9 ? .small : (number > 1.15 ? .large : .normal) }
        if trimmed.hasSuffix("%") { return number < 90 ? .small : (number > 115 ? .large : .normal) }
        return nil
    }

    /// Раскрывает HTML-сущности: &amp; &lt; &gt; &quot; &apos; &#39; &nbsp; (→ пробел) и числовые.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = ""
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c == "&" else { out.unicodeScalars.append(c); i += 1; continue }
            var j = i + 1
            var name = ""
            while j < scalars.count, j - i <= 10, scalars[j] != ";" { name.unicodeScalars.append(scalars[j]); j += 1 }
            guard j < scalars.count, scalars[j] == ";" else { out.unicodeScalars.append(c); i += 1; continue }
            var replacement: String? = nil
            switch name {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            case "nbsp": replacement = " "
            default:
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let value = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
                        replacement = String(Character(scalar))
                    }
                } else if name.hasPrefix("#") {
                    if let value = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(value) {
                        replacement = String(Character(scalar))
                    }
                }
            }
            if let replacement {
                out += replacement
                i = j + 1
            } else {
                out.unicodeScalars.append(c)
                i += 1
            }
        }
        return out
    }

    // MARK: Подпись

    /// Помечает блок подписи («--» и строки подписи) — первое совпадение вне цитат и списков.
    static func markSignature(_ signature: String, in paragraphs: [RichParagraph]) -> [RichParagraph] {
        let normalized = signature.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.isEmpty else { return paragraphs }
        let block = ["--"] + normalized.components(separatedBy: "\n")
        guard paragraphs.count >= block.count else { return paragraphs }
        for start in 0...(paragraphs.count - block.count) {
            let matches = (0..<block.count).allSatisfy { k in
                let paragraph = paragraphs[start + k]
                return paragraph.list == nil && paragraph.quoteLevel == 0 && paragraph.text == block[k]
            }
            guard matches else { continue }
            var result = paragraphs
            for k in 0..<block.count {
                for r in result[start + k].runs.indices { result[start + k].runs[r].isSignature = true }
            }
            return result
        }
        return paragraphs
    }

    // MARK: Загрузка черновика

    /// Модель для редактора: из HTML, если он есть и согласован с plain text (иначе — из plain text).
    /// Пустые строки по краям, которые HTML не хранит, восстанавливаются по plain text.
    static func load(plain: String, html: String?) -> [RichParagraph] {
        let plainModel = parsePlain(plain)
        guard let html, !html.isEmpty else { return plainModel }
        var parsed = parseHTML(html)[...]
        while let first = parsed.first, first.isBlankTopLevel { parsed = parsed.dropFirst() }
        while let last = parsed.last, last.isBlankTopLevel { parsed = parsed.dropLast() }
        guard !parsed.isEmpty else { return plainModel }

        let leading = plainModel.prefix { $0.isBlankTopLevel }.count
        let trailing = leading == plainModel.count ? 0 : plainModel.reversed().prefix { $0.isBlankTopLevel }.count
        let blank = RichParagraph()
        let candidate = Array(repeating: blank, count: leading) + Array(parsed) + Array(repeating: blank, count: trailing)
        return plainText(candidate) == plainText(plainModel) ? candidate : plainModel
    }
}
