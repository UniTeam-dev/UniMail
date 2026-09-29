import AppKit
import SwiftUI

// Редактор текста письма: NSTextView (TextKit 1) в NSScrollView.
// Хранилище текста — NSTextStorage с «каноническими» атрибутами:
//  • шрифт — системный 11.5 / 13.5 / 17 pt, жирный/курсив;
//  • списки — NSParagraphStyle.textLists + маркер текстом в начале абзаца («\t•\t», «\t1.\t»), как в TextKit 1;
//  • цитата — атрибут .umQuoteLevel и отступ абзаца, полоска слева рисуется в ComposeTextView;
//  • подпись — атрибут .umSignature (вторичный цвет), чтобы заменять её при смене ящика.
// После каждой правки `RichTextController.normalize()` приводит атрибуты к канону (вставленный извне
// текст теряет чужие шрифты и цвета) и перенумеровывает списки, затем модель уходит в plain text и HTML.

extension NSAttributedString.Key {
    /// Уровень цитаты абзаца (Int, 1…).
    static let umQuoteLevel = NSAttributedString.Key("UniMailQuoteLevel")
    /// Текст подписи (Bool).
    static let umSignature = NSAttributedString.Key("UniMailSignature")
    /// Шрифт до подстановки (NSTextStorage.fixAttributes для эмодзи и т. п.).
    static let umOriginalFont = NSAttributedString.Key("NSOriginalFont")
}

// MARK: - Мост модель ↔ NSAttributedString

@MainActor
enum RichTextBridge {
    static let quoteIndent: CGFloat = 14
    static let listIndent: CGFloat = 24
    static let lineSpacing: CGFloat = 5
    static let bulletMarker = "\t•\t"

    static let bulletList = NSTextList(markerFormat: .disc, options: 0)
    static let orderedList = NSTextList(markerFormat: .decimal, options: 0)

    private static var paragraphStyleCache: [String: NSParagraphStyle] = [:]
    private static var fontCache: [String: (font: NSFont, oblique: Bool)] = [:]

    static func marker(_ list: RichListKind, number: Int) -> String {
        list == .bullet ? bulletMarker : "\t\(max(1, number)).\t"
    }

    // MARK: Атрибуты

    static func paragraphStyle(level: Int, list: RichListKind?) -> NSParagraphStyle {
        let key = "\(level)|\(list?.rawValue ?? "-")"
        if let cached = paragraphStyleCache[key] { return cached }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.defaultTabInterval = 28
        let base = CGFloat(level) * quoteIndent
        style.firstLineHeadIndent = base
        style.headIndent = base
        if let list {
            style.headIndent = base + listIndent
            let markerTab = list == .ordered
                ? NSTextTab(textAlignment: .right, location: base + 19, options: [:])
                : NSTextTab(textAlignment: .natural, location: base + 6, options: [:])
            style.tabStops = [markerTab, NSTextTab(textAlignment: .natural, location: base + listIndent, options: [:])]
            style.textLists = [list == .ordered ? orderedList : bulletList]
        }
        let result: NSParagraphStyle = (style.copy() as? NSParagraphStyle) ?? style
        paragraphStyleCache[key] = result
        return result
    }

    /// Шрифт начертания; если у системного шрифта нет курсива — наклон через .obliqueness.
    static func font(for style: RichStyle) -> (font: NSFont, oblique: Bool) {
        let key = "\(style.bold)|\(style.italic)|\(style.size.rawValue)"
        if let cached = fontCache[key] { return cached }
        let size = CGFloat(style.size.points)
        let regular = NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        var result: (font: NSFont, oblique: Bool) = (regular, false)
        if style.italic {
            let descriptor = regular.fontDescriptor.withSymbolicTraits(regular.fontDescriptor.symbolicTraits.union(.italic))
            if let italic = NSFont(descriptor: descriptor, size: size), isItalic(italic) {
                result = (italic, false)
            } else {
                let converted = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
                result = isItalic(converted) ? (converted, false) : (regular, true)
            }
        }
        fontCache[key] = result
        return result
    }

    static func isBold(_ font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(.boldFontMask) || font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    static func isItalic(_ font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(.italicFontMask) || font.fontDescriptor.symbolicTraits.contains(.italic)
    }

    /// Канонические атрибуты отрезка. `linkValue` — исходное значение .link (URL/String), чтобы не менять его без нужды.
    static func attributes(style: RichStyle, level: Int, list: RichListKind?, signature: Bool,
                           linkValue: Any? = nil) -> [NSAttributedString.Key: Any] {
        let resolved = font(for: style)
        var result: [NSAttributedString.Key: Any] = [
            .font: resolved.font,
            .paragraphStyle: paragraphStyle(level: level, list: list),
            .foregroundColor: (signature || level > 0) ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        if resolved.oblique { result[.obliqueness] = 0.18 }
        if style.underline { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = style.link {
            if let linkValue {
                result[.link] = linkValue
            } else if let url = URL(string: link) {
                result[.link] = url
            } else {
                result[.link] = link
            }
        }
        if level > 0 { result[.umQuoteLevel] = level }
        if signature { result[.umSignature] = true }
        return result
    }

    static func style(from attributes: [NSAttributedString.Key: Any]) -> RichStyle {
        var style = RichStyle()
        if let font = (attributes[.umOriginalFont] as? NSFont) ?? (attributes[.font] as? NSFont) {
            style.bold = isBold(font)
            style.italic = isItalic(font)
            style.size = RichTextSize.bucket(points: Double(font.pointSize))
        }
        if let obliqueness = attributes[.obliqueness] as? NSNumber, obliqueness.doubleValue > 0.05 {
            style.italic = true
        }
        style.underline = ((attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        style.strikethrough = ((attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
        if let url = attributes[.link] as? URL {
            style.link = url.absoluteString
        } else if let string = attributes[.link] as? String, !string.isEmpty {
            style.link = string
        }
        return style
    }

    static func quoteLevel(_ attributes: [NSAttributedString.Key: Any]) -> Int {
        min(max((attributes[.umQuoteLevel] as? Int) ?? 0, 0), 8)
    }

    static func listKind(_ attributes: [NSAttributedString.Key: Any]) -> RichListKind? {
        guard let list = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textLists.last else { return nil }
        return list.markerFormat == .decimal ? .ordered : .bullet
    }

    static func isSignature(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        attributes[.umSignature] != nil
    }

    /// Канонические атрибуты для существующего отрезка текста.
    static func canonical(for attributes: [NSAttributedString.Key: Any], level: Int,
                          list: RichListKind?) -> [NSAttributedString.Key: Any] {
        self.attributes(style: style(from: attributes), level: level, list: list,
                        signature: isSignature(attributes), linkValue: attributes[.link])
    }

    /// Совпадают ли атрибуты с каноническими (подставленный системой шрифт не считается отличием).
    static func matches(_ attributes: [NSAttributedString.Key: Any], _ canonical: [NSAttributedString.Key: Any]) -> Bool {
        var current = attributes
        if let original = current[.umOriginalFont] {
            current[.font] = original
            current.removeValue(forKey: .umOriginalFont)
        }
        guard current.count == canonical.count else { return false }
        for (key, value) in canonical {
            // Значения из NSTextStorage приходят как NSNumber/NSURL/NSColor — сравниваем через isEqual.
            guard let existing = current[key] as? NSObject, let expected = value as? NSObject,
                  existing.isEqual(expected) else { return false }
        }
        return true
    }

    // MARK: Абзацы

    struct ParagraphInfo {
        /// Абзац вместе с символом конца абзаца.
        var range: NSRange
        /// Конец текста абзаца (без перевода строки).
        var contentsEnd: Int
        var level: Int
        var list: RichListKind?
        /// Длина маркера пункта списка (0 — маркера нет).
        var markerLength: Int

        var contentStart: Int { range.location + markerLength }
        var contentRange: NSRange { NSRange(location: contentStart, length: max(0, contentsEnd - contentStart)) }
        var isEmpty: Bool { contentsEnd <= contentStart }
        /// Список действует, только если на месте маркер.
        var effectiveList: RichListKind? { markerLength > 0 ? list : nil }
    }

    /// Длина маркера «\t…\t» в начале абзаца (в UTF-16) или 0.
    static func markerLength(in string: NSString, start: Int, contentsEnd: Int) -> Int {
        guard start < contentsEnd, string.character(at: start) == 9 else { return 0 }
        var index = start + 1
        while index < contentsEnd, index - start <= 7 {
            let c = string.character(at: index)
            if c == 9 { return index - start + 1 }
            index += 1
        }
        return 0
    }

    private static func info(in storage: NSAttributedString, string: NSString,
                             start: Int, end: Int, contentsEnd: Int) -> ParagraphInfo {
        var level = 0
        var list: RichListKind? = nil
        var marker = 0
        if start < string.length {
            let attributes = storage.attributes(at: start, effectiveRange: nil)
            level = quoteLevel(attributes)
            list = listKind(attributes)
            if list != nil { marker = markerLength(in: string, start: start, contentsEnd: contentsEnd) }
        }
        return ParagraphInfo(range: NSRange(location: start, length: end - start), contentsEnd: contentsEnd,
                             level: level, list: list, markerLength: marker)
    }

    /// Все абзацы; после завершающего перевода строки — пустой абзац (как components(separatedBy: "\n")).
    static func paragraphs(in storage: NSAttributedString) -> [ParagraphInfo] {
        let string = storage.string as NSString
        let length = string.length
        var result: [ParagraphInfo] = []
        var location = 0
        while true {
            var start = 0, end = 0, contentsEnd = 0
            string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            result.append(info(in: storage, string: string, start: start, end: end, contentsEnd: contentsEnd))
            if end >= length {
                if length > 0, contentsEnd < end {
                    result.append(ParagraphInfo(range: NSRange(location: length, length: 0), contentsEnd: length,
                                                level: 0, list: nil, markerLength: 0))
                }
                break
            }
            location = end
        }
        return result
    }

    static func paragraph(in storage: NSAttributedString, at location: Int) -> ParagraphInfo {
        let string = storage.string as NSString
        let clamped = min(max(0, location), string.length)
        var start = 0, end = 0, contentsEnd = 0
        string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: clamped, length: 0))
        return info(in: storage, string: string, start: start, end: end, contentsEnd: contentsEnd)
    }

    static func model(of info: ParagraphInfo, in storage: NSAttributedString) -> RichParagraph {
        var paragraph = RichParagraph(runs: [], list: info.effectiveList, quoteLevel: info.level)
        let content = info.contentRange
        guard content.length > 0 else { return paragraph }
        let string = storage.string as NSString
        storage.enumerateAttributes(in: content, options: []) { attributes, range, _ in
            paragraph.runs.append(RichRun(text: string.substring(with: range), style: style(from: attributes),
                                          isSignature: isSignature(attributes)))
        }
        return paragraph
    }

    static func model(from storage: NSAttributedString) -> [RichParagraph] {
        paragraphs(in: storage).map { model(of: $0, in: storage) }
    }

    static func attributedString(from paragraphs: [RichParagraph]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let numbers = RichText.listNumbers(paragraphs)
        for (index, paragraph) in paragraphs.enumerated() {
            let level = max(0, paragraph.quoteLevel)
            if let list = paragraph.list {
                let base = attributes(style: RichStyle(), level: level, list: list, signature: false)
                result.append(NSAttributedString(string: marker(list, number: numbers[index]), attributes: base))
            }
            for run in paragraph.runs where !run.text.isEmpty {
                result.append(NSAttributedString(
                    string: run.text,
                    attributes: attributes(style: run.style, level: level, list: paragraph.list, signature: run.isSignature)
                ))
            }
            if index < paragraphs.count - 1 {
                // Перевод строки внутри блока подписи — тоже подпись, чтобы блок был сплошным.
                let signature = (paragraph.runs.last?.isSignature ?? false)
                    && (paragraphs[index + 1].runs.first?.isSignature ?? false)
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: attributes(style: RichStyle(), level: level, list: paragraph.list, signature: signature)
                ))
            }
        }
        return result
    }

    /// Сдвиг выделения после замены `edited` на текст длиной `replacementLength`.
    static func adjust(_ selection: NSRange, edited: NSRange, replacementLength: Int) -> NSRange {
        let delta = replacementLength - edited.length
        if selection.location >= NSMaxRange(edited) {
            return NSRange(location: selection.location + delta, length: selection.length)
        }
        if NSMaxRange(selection) <= edited.location {
            return selection
        }
        return NSRange(location: edited.location + replacementLength, length: 0)
    }
}

// MARK: - NSTextView письма

final class ComposeTextView: NSTextView {
    weak var controller: RichTextController?
    var onFileDrop: (([URL]) -> Void)?
    /// Стать первым респондером, как только вид окажется в окне.
    var wantsInitialFocus = false
    /// NSTextView, собранный вручную, не владеет хранилищем — держим его сами.
    var ownedStorage: NSTextStorage?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsInitialFocus, window != nil else { return }
        wantsInitialFocus = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    // MARK: ⌘B / ⌘I / ⌘U (в приложении нет меню «Формат»)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let controller,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let latin = !characters.isEmpty && characters.unicodeScalars.allSatisfy { $0.isASCII }
            let key: String
            if latin {
                key = characters
            } else {
                // Нелатинская раскладка: физические клавиши B, I, U.
                switch event.keyCode {
                case 11: key = "b"
                case 34: key = "i"
                case 32: key = "u"
                default: key = ""
                }
            }
            switch key {
            case "b": controller.toggleBold(); return true
            case "i": controller.toggleItalic(); return true
            case "u": controller.toggleUnderline(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Файлы, брошенные на текст, становятся вложениями

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        if !types.contains(.fileURL) { types.append(.fileURL) }
        return types
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        guard onFileDrop != nil else { return [] }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { $0 as? URL }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedFiles(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty, let onFileDrop else { return super.performDragOperation(sender) }
        onFileDrop(files)
        return true
    }

    // MARK: Полоска цитаты

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawQuoteBars(in: dirtyRect)
    }

    private func drawQuoteBars(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        let glyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.length > 0, NSMaxRange(characters) <= storage.length else { return }
        NSColor.tertiaryLabelColor.setFill()
        storage.enumerateAttribute(.umQuoteLevel, in: characters, options: []) { value, range, _ in
            guard let level = value as? Int, level > 0 else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                for index in 0..<min(level, 8) {
                    let x = origin.x + padding + CGFloat(index) * RichTextBridge.quoteIndent + 1
                    let bar = NSRect(x: x, y: origin.y + rect.minY, width: 2, height: rect.height)
                    NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
                }
            }
        }
    }
}

// MARK: - Контроллер: команды форматирования и состояние панели

@MainActor
@Observable
final class RichTextController {
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false
    var list: RichListKind? = nil
    var isQuote = false
    var size: RichTextSize = .normal
    var hasLink = false

    @ObservationIgnored weak var textView: ComposeTextView?
    @ObservationIgnored private(set) var isNormalizing = false
    @ObservationIgnored private var savedLinkRange: NSRange?

    // MARK: Общие операции

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    private func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    /// Замена текста с регистрацией в Undo (didChangeText → нормализация и публикация).
    @discardableResult
    private func replace(_ range: NSRange, with replacement: NSAttributedString) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let target = clamped(range, length: storage.length)
        guard textView.shouldChangeText(in: target, replacementString: replacement.string) else { return false }
        storage.replaceCharacters(in: target, with: replacement)
        textView.didChangeText()
        return true
    }

    /// Текст абзацев без маркеров списков, пересекающийся с range.
    private func contentRanges(in range: NSRange, storage: NSTextStorage) -> [NSRange] {
        RichTextBridge.paragraphs(in: storage).compactMap { info in
            let intersection = NSIntersectionRange(info.contentRange, range)
            return intersection.length > 0 ? intersection : nil
        }
    }

    /// Меняет начертание отрезков внутри range (с Undo).
    private func mutateRuns(in range: NSRange, _ transform: (inout RichStyle) -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        let ranges = contentRanges(in: clamped(range, length: storage.length), storage: storage)
        guard let first = ranges.first, let last = ranges.last else { return }
        let union = NSUnionRange(first, last)
        guard textView.shouldChangeText(in: union, replacementString: nil) else { return }
        storage.beginEditing()
        for part in ranges {
            storage.enumerateAttributes(in: part, options: []) { attributes, subrange, _ in
                let before = RichTextBridge.style(from: attributes)
                var style = before
                transform(&style)
                let updated = RichTextBridge.attributes(
                    style: style,
                    level: RichTextBridge.quoteLevel(attributes),
                    list: RichTextBridge.listKind(attributes),
                    signature: RichTextBridge.isSignature(attributes),
                    linkValue: style.link == before.link ? attributes[.link] : nil
                )
                storage.setAttributes(updated, range: subrange)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func setTypingStyle(_ style: RichStyle) {
        guard let textView, let storage = textView.textStorage else { return }
        let typing = textView.typingAttributes
        let info = RichTextBridge.paragraph(in: storage, at: textView.selectedRange().location)
        let atEnd = info.range.location >= storage.length
        textView.typingAttributes = RichTextBridge.attributes(
            style: style,
            level: atEnd ? RichTextBridge.quoteLevel(typing) : info.level,
            list: atEnd ? RichTextBridge.listKind(typing) : info.effectiveList,
            signature: RichTextBridge.isSignature(typing)
        )
    }

    /// Строчное изменение: для выделения — в тексте, без выделения — в атрибутах набора.
    private func applyInline(_ transform: (inout RichStyle) -> Void) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        if selection.length == 0 {
            var style = RichTextBridge.style(from: textView.typingAttributes)
            transform(&style)
            setTypingStyle(style)
        } else {
            mutateRuns(in: selection, transform)
        }
        refreshState()
    }

    private func toggle(_ keyPath: WritableKeyPath<RichStyle, Bool>) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        var allOn = true
        if selection.length == 0 {
            allOn = RichTextBridge.style(from: textView.typingAttributes)[keyPath: keyPath]
        } else {
            let ranges = contentRanges(in: clamped(selection, length: storage.length), storage: storage)
            if ranges.isEmpty { allOn = false }
            for part in ranges where allOn {
                storage.enumerateAttributes(in: part, options: []) { attributes, _, stop in
                    if !RichTextBridge.style(from: attributes)[keyPath: keyPath] {
                        allOn = false
                        stop.pointee = true
                    }
                }
            }
        }
        let newValue = !allOn
        applyInline { $0[keyPath: keyPath] = newValue }
        focus()
    }

    // MARK: Строчные стили

    func toggleBold() { toggle(\.bold) }
    func toggleItalic() { toggle(\.italic) }
    func toggleUnderline() { toggle(\.underline) }
    func toggleStrikethrough() { toggle(\.strikethrough) }

    func setSize(_ size: RichTextSize) {
        applyInline { $0.size = size }
        focus()
    }

    /// Убирает строчное форматирование (жирный, курсив, ссылки, размер); списки и цитаты остаются.
    func clearFormatting() {
        applyInline { $0 = RichStyle() }
        focus()
    }

    // MARK: Абзацы: списки и цитаты

    func toggleList(_ kind: RichListKind) {
        rewriteSelectedParagraphs { paragraphs in
            let allSame = paragraphs.allSatisfy { $0.list == kind }
            for index in paragraphs.indices { paragraphs[index].list = allSame ? nil : kind }
        }
        focus()
    }

    func toggleQuote() {
        rewriteSelectedParagraphs { paragraphs in
            let allQuoted = paragraphs.allSatisfy { $0.quoteLevel > 0 }
            for index in paragraphs.indices {
                paragraphs[index].quoteLevel = allQuoted
                    ? max(0, paragraphs[index].quoteLevel - 1)
                    : max(paragraphs[index].quoteLevel, 1)
            }
        }
        focus()
    }

    private func rewriteSelectedParagraphs(_ change: (inout [RichParagraph]) -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = clamped(textView.selectedRange(), length: storage.length)
        let all = RichTextBridge.paragraphs(in: storage)
        let touched = all.filter { info in
            if selection.length == 0 {
                return selection.location >= info.range.location
                    && (selection.location < NSMaxRange(info.range)
                        || (selection.location == NSMaxRange(info.range) && info.contentsEnd == NSMaxRange(info.range)))
            }
            return NSIntersectionRange(info.range, selection).length > 0
        }
        rewrite(touched, change: change)
    }

    /// Перестраивает подряд идущие абзацы по изменённой модели (с Undo) и восстанавливает курсор.
    private func rewrite(_ infos: [RichTextBridge.ParagraphInfo], change: (inout [RichParagraph]) -> Void) {
        guard let textView, let storage = textView.textStorage,
              let first = infos.first, let last = infos.last else { return }
        var models = infos.map { RichTextBridge.model(of: $0, in: storage) }
        change(&models)
        let replacement = RichTextBridge.attributedString(from: models)
        let range = NSRange(location: first.range.location, length: max(0, last.contentsEnd - first.range.location))
        let selection = textView.selectedRange()
        let typing = textView.typingAttributes

        let newSelection: NSRange
        if infos.count == 1 {
            let offset = max(0, selection.location - first.contentStart)
            let marker = models[0].list.map { RichTextBridge.marker($0, number: 1).utf16.count } ?? 0
            let location = min(first.range.location + marker + offset, first.range.location + replacement.length)
            let length = min(selection.length, first.range.location + replacement.length - location)
            newSelection = NSRange(location: location, length: max(0, length))
        } else {
            newSelection = NSRange(location: first.range.location, length: replacement.length)
        }

        guard replace(range, with: replacement) else { return }
        textView.setSelectedRange(clamped(newSelection, length: storage.length))
        if newSelection.length == 0, infos.count == 1 {
            textView.typingAttributes = RichTextBridge.attributes(
                style: RichTextBridge.style(from: typing),
                level: max(0, models[0].quoteLevel),
                list: models[0].list,
                signature: RichTextBridge.isSignature(typing)
            )
        }
        refreshState()
    }

    // MARK: Клавиши: Return и Backspace в списках и цитатах

    func handle(command selector: Selector) -> Bool {
        guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            return handleNewline(textView, storage)
        }
        if selector == #selector(NSResponder.deleteBackward(_:)) {
            return handleDeleteBackward(textView, storage)
        }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            // Вложенные списки не поддерживаются: встроенная обработка Tab в NSTextView переписала бы маркер.
            let info = RichTextBridge.paragraph(in: storage, at: textView.selectedRange().location)
            return info.effectiveList != nil
        }
        return false
    }

    private func handleNewline(_ textView: NSTextView, _ storage: NSTextStorage) -> Bool {
        let selection = clamped(textView.selectedRange(), length: storage.length)
        let info = RichTextBridge.paragraph(in: storage, at: selection.location)
        guard info.range.location < storage.length else { return false }

        if let list = info.effectiveList, selection.location >= info.contentStart {
            if info.isEmpty && selection.length == 0 {
                // Return в пустом пункте завершает список.
                rewrite([info]) { $0[0].list = nil }
                return true
            }
            let typing = textView.typingAttributes
            let base = RichTextBridge.attributes(style: RichStyle(), level: info.level, list: list, signature: false)
            let insertion = NSMutableAttributedString(string: "\n", attributes: base)
            insertion.append(NSAttributedString(string: RichTextBridge.marker(list, number: 1), attributes: base))
            guard replace(selection, with: insertion) else { return true }
            textView.setSelectedRange(NSRange(location: min(selection.location + insertion.length, storage.length), length: 0))
            textView.typingAttributes = RichTextBridge.attributes(
                style: RichTextBridge.style(from: typing), level: info.level, list: list, signature: false
            )
            refreshState()
            return true
        }

        if info.level > 0, info.isEmpty, selection.length == 0 {
            // Пустая строка в конце цитаты: Return выходит из цитаты.
            let next = NSMaxRange(info.range) < storage.length
                ? RichTextBridge.paragraph(in: storage, at: NSMaxRange(info.range))
                : nil
            if next == nil || (next?.level ?? 0) < info.level {
                rewrite([info]) { $0[0].quoteLevel -= 1 }
                return true
            }
        }
        return false
    }

    private func handleDeleteBackward(_ textView: NSTextView, _ storage: NSTextStorage) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location <= storage.length else { return false }
        let info = RichTextBridge.paragraph(in: storage, at: selection.location)
        guard info.range.location < storage.length else { return false }

        if info.effectiveList != nil, selection.location == info.contentStart {
            // Backspace сразу после маркера убирает пункт списка.
            rewrite([info]) { $0[0].list = nil }
            return true
        }
        if info.level > 0, info.effectiveList == nil, selection.location == info.range.location {
            // В начале первой строки цитаты Backspace уменьшает уровень цитаты.
            let previousLevel = info.range.location > 0
                ? RichTextBridge.paragraph(in: storage, at: info.range.location - 1).level
                : 0
            if previousLevel < info.level {
                rewrite([info]) { $0[0].quoteLevel -= 1 }
                return true
            }
        }
        return false
    }

    // MARK: Нормализация после каждой правки

    /// Перенумеровывает списки и приводит атрибуты к канону. Вызывается из textDidChange.
    func normalize() {
        guard let textView, let storage = textView.textStorage, !isNormalizing, !textView.hasMarkedText() else { return }
        isNormalizing = true
        defer { isNormalizing = false }

        // 1. Маркеры списков.
        let string = storage.string as NSString
        var edits: [(range: NSRange, marker: String, level: Int, list: RichListKind)] = []
        var counter = 0
        var previousLevel: Int? = nil
        var infos = RichTextBridge.paragraphs(in: storage)
        for info in infos {
            guard let list = info.effectiveList else {
                counter = 0
                previousLevel = nil
                continue
            }
            let expected: String
            if list == .ordered {
                counter = previousLevel == info.level ? counter + 1 : 1
                previousLevel = info.level
                expected = RichTextBridge.marker(.ordered, number: counter)
            } else {
                counter = 0
                previousLevel = nil
                expected = RichTextBridge.bulletMarker
            }
            let markerRange = NSRange(location: info.range.location, length: info.markerLength)
            if string.substring(with: markerRange) != expected {
                edits.append((markerRange, expected, info.level, list))
            }
        }
        if !edits.isEmpty {
            var selection = textView.selectedRange()
            let typing = textView.typingAttributes
            for edit in edits.reversed() {
                let attributed = NSAttributedString(
                    string: edit.marker,
                    attributes: RichTextBridge.attributes(style: RichStyle(), level: edit.level, list: edit.list, signature: false)
                )
                guard textView.shouldChangeText(in: edit.range, replacementString: edit.marker) else { continue }
                storage.replaceCharacters(in: edit.range, with: attributed)
                textView.didChangeText()
                selection = RichTextBridge.adjust(selection, edited: edit.range, replacementLength: attributed.length)
            }
            textView.setSelectedRange(clamped(selection, length: storage.length))
            if selection.length == 0 { textView.typingAttributes = typing }
            infos = RichTextBridge.paragraphs(in: storage)
        }

        // 2. Канонические атрибуты (без Undo: это не правка пользователя).
        storage.beginEditing()
        for info in infos where info.range.length > 0 {
            let list = info.effectiveList
            if info.markerLength > 0 {
                let markerRange = NSRange(location: info.range.location, length: info.markerLength)
                let canonical = RichTextBridge.attributes(style: RichStyle(), level: info.level, list: list, signature: false)
                storage.enumerateAttributes(in: markerRange, options: []) { attributes, range, _ in
                    if !RichTextBridge.matches(attributes, canonical) { storage.setAttributes(canonical, range: range) }
                }
            }
            let rest = NSRange(location: info.contentStart, length: NSMaxRange(info.range) - info.contentStart)
            guard rest.length > 0 else { continue }
            storage.enumerateAttributes(in: rest, options: []) { attributes, range, _ in
                let canonical = RichTextBridge.canonical(for: attributes, level: info.level, list: list)
                if !RichTextBridge.matches(attributes, canonical) { storage.setAttributes(canonical, range: range) }
            }
        }
        storage.endEditing()
    }

    // MARK: Состояние панели

    func selectionDidChange() {
        guard let textView, let storage = textView.textStorage, !isNormalizing else { return }
        let selection = textView.selectedRange()
        // Текст, набранный сразу после подписи, подписью не становится.
        if selection.length == 0, RichTextBridge.isSignature(textView.typingAttributes) {
            let inside = selection.location < storage.length
                && storage.attribute(.umSignature, at: selection.location, effectiveRange: nil) != nil
            if !inside {
                let typing = textView.typingAttributes
                textView.typingAttributes = RichTextBridge.attributes(
                    style: RichTextBridge.style(from: typing),
                    level: RichTextBridge.quoteLevel(typing),
                    list: RichTextBridge.listKind(typing),
                    signature: false
                )
            }
        }
        refreshState()
    }

    /// Курсор не заходит внутрь маркера пункта списка: шаг влево с начала текста пункта уводит
    /// в конец предыдущей строки, любое другое попадание на маркер — к началу текста пункта.
    func adjustedSelection(from old: NSRange, to new: NSRange) -> NSRange {
        guard new.length == 0, !isNormalizing, let storage = textView?.textStorage,
              new.location <= storage.length else { return new }
        let info = RichTextBridge.paragraph(in: storage, at: new.location)
        guard info.effectiveList != nil, new.location >= info.range.location, new.location < info.contentStart else {
            return new
        }
        let steppedLeft = old.length == 0 && old.location == info.contentStart && new.location < old.location
        if steppedLeft, info.range.location > 0 {
            return NSRange(location: info.range.location - 1, length: 0)
        }
        return NSRange(location: info.contentStart, length: 0)
    }

    func refreshState() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = clamped(textView.selectedRange(), length: storage.length)
        let attributes: [NSAttributedString.Key: Any]
        if selection.length > 0 {
            let contents = contentRanges(in: selection, storage: storage)
            let probe = contents.first?.location ?? selection.location
            attributes = probe < storage.length ? storage.attributes(at: probe, effectiveRange: nil) : textView.typingAttributes
        } else {
            attributes = textView.typingAttributes
        }
        let style = RichTextBridge.style(from: attributes)
        let info = RichTextBridge.paragraph(in: storage, at: selection.location)
        let atEnd = info.range.location >= storage.length
        let paragraphList = atEnd ? RichTextBridge.listKind(textView.typingAttributes) : info.effectiveList
        let paragraphLevel = atEnd ? RichTextBridge.quoteLevel(textView.typingAttributes) : info.level

        if isBold != style.bold { isBold = style.bold }
        if isItalic != style.italic { isItalic = style.italic }
        if isUnderline != style.underline { isUnderline = style.underline }
        if isStrikethrough != style.strikethrough { isStrikethrough = style.strikethrough }
        if size != style.size { size = style.size }
        if hasLink != (style.link != nil) { hasLink = style.link != nil }
        if list != paragraphList { list = paragraphList }
        if isQuote != (paragraphLevel > 0) { isQuote = paragraphLevel > 0 }
    }

    // MARK: Ссылки

    /// Запоминает диапазон (выделение или ссылку под курсором) и возвращает текущий адрес ссылки.
    func beginLinkEditing() -> String {
        guard let textView, let storage = textView.textStorage else { return "" }
        let selection = clamped(textView.selectedRange(), length: storage.length)
        savedLinkRange = selection
        let probe = selection.length > 0 ? selection.location : selection.location - 1
        guard probe >= 0, probe < storage.length else { return "" }
        var effective = NSRange(location: 0, length: 0)
        let value = storage.attribute(.link, at: probe, longestEffectiveRange: &effective,
                                      in: NSRange(location: 0, length: storage.length))
        if selection.length == 0, value != nil { savedLinkRange = effective }
        if let url = value as? URL { return url.absoluteString }
        return value as? String ?? ""
    }

    func applyLink(_ raw: String) {
        guard let textView, let storage = textView.textStorage, let href = RichText.sanitizeLink(raw) else { return }
        let range = clamped(savedLinkRange ?? textView.selectedRange(), length: storage.length)
        savedLinkRange = nil
        if range.length == 0 {
            // Без выделения вставляем сам адрес ссылкой.
            let typing = textView.typingAttributes
            var style = RichTextBridge.style(from: typing)
            style.link = href
            let info = RichTextBridge.paragraph(in: storage, at: range.location)
            let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = NSAttributedString(string: display.isEmpty ? href : display, attributes: RichTextBridge.attributes(
                style: style, level: info.level, list: info.effectiveList, signature: false
            ))
            guard replace(range, with: text) else { return }
            textView.setSelectedRange(NSRange(location: min(range.location + text.length, storage.length), length: 0))
            style.link = nil
            setTypingStyle(style)
        } else {
            textView.setSelectedRange(range)
            mutateRuns(in: range) { $0.link = href }
        }
        focus()
        refreshState()
    }

    func removeLink() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = clamped(savedLinkRange ?? textView.selectedRange(), length: storage.length)
        savedLinkRange = nil
        if range.length > 0 {
            mutateRuns(in: range) { $0.link = nil }
        } else {
            var style = RichTextBridge.style(from: textView.typingAttributes)
            style.link = nil
            setTypingStyle(style)
        }
        focus()
        refreshState()
    }

    // MARK: Шаблоны и подпись

    /// Вставляет текст шаблона в позицию курсора (строки «• », «1. » становятся списками).
    func insertTemplate(_ body: String) {
        guard let textView, let storage = textView.textStorage, !body.isEmpty else { return }
        let selection = clamped(textView.selectedRange(), length: storage.length)
        let info = RichTextBridge.paragraph(in: storage, at: selection.location)
        let level = info.range.location < storage.length ? info.level : 0
        let paragraphs = RichText.parsePlain(body).map { paragraph -> RichParagraph in
            var copy = paragraph
            copy.quoteLevel += level
            return copy
        }
        let text = RichTextBridge.attributedString(from: paragraphs)
        guard replace(selection, with: text) else { return }
        textView.setSelectedRange(NSRange(location: min(selection.location + text.length, storage.length), length: 0))
        focus()
        refreshState()
    }

    /// Заменяет блок подписи (помеченный или найденный по тексту `previous`) на новую подпись.
    /// Если подписи не было — вставляет её перед цитатой или в конец письма.
    func replaceSignature(with signature: String, previous: String?) {
        guard let textView, let storage = textView.textStorage else { return }
        let newText = signature.replacingOccurrences(of: "\r\n", with: "\n")
        var found: NSRange? = nil
        storage.enumerateAttribute(.umSignature, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard value != nil else { return }
            found = found.map { NSUnionRange($0, range) } ?? range
        }
        let string = storage.string as NSString
        if found == nil, let previous, !previous.isEmpty {
            let range = string.range(of: "--\n" + previous.replacingOccurrences(of: "\r\n", with: "\n"))
            if range.location != NSNotFound { found = range }
        }
        let plainAttributes = RichTextBridge.attributes(style: RichStyle(), level: 0, list: nil, signature: false)
        let block = NSAttributedString(
            string: "--\n" + newText,
            attributes: RichTextBridge.attributes(style: RichStyle(), level: 0, list: nil, signature: true)
        )
        var selection = textView.selectedRange()

        if let range = found {
            if newText.isEmpty {
                // Удаляем подпись вместе с пустыми строками перед ней.
                var start = range.location
                var newlines = 0
                while start > 0, newlines < 2, string.character(at: start - 1) == 10 {
                    start -= 1
                    newlines += 1
                }
                let removal = NSRange(location: start, length: NSMaxRange(range) - start)
                if replace(removal, with: NSAttributedString()) {
                    selection = RichTextBridge.adjust(selection, edited: removal, replacementLength: 0)
                }
            } else if replace(range, with: block) {
                selection = RichTextBridge.adjust(selection, edited: range, replacementLength: block.length)
            }
        } else if !newText.isEmpty {
            let infos = RichTextBridge.paragraphs(in: storage)
            let insertion = NSMutableAttributedString()
            let location: Int
            if let quoteIndex = infos.firstIndex(where: { $0.level > 0 }) {
                // Перед строкой «…пишет:» над цитатой.
                var target = quoteIndex
                if quoteIndex > 0, !infos[quoteIndex - 1].isEmpty, infos[quoteIndex - 1].level == 0 { target = quoteIndex - 1 }
                location = infos[target].range.location
                insertion.append(block)
                insertion.append(NSAttributedString(string: "\n\n", attributes: plainAttributes))
            } else {
                var trailing = 0
                var index = string.length
                while index > 0, trailing < 2, string.character(at: index - 1) == 10 {
                    index -= 1
                    trailing += 1
                }
                location = string.length
                insertion.append(NSAttributedString(string: String(repeating: "\n", count: 2 - trailing), attributes: plainAttributes))
                insertion.append(block)
            }
            if replace(NSRange(location: location, length: 0), with: insertion), selection.location > location {
                // Курсор, стоявший ровно в точке вставки, остаётся на месте (над подписью).
                selection.location += insertion.length
            }
        }
        textView.setSelectedRange(clamped(selection, length: storage.length))
        refreshState()
    }
}

// MARK: - SwiftUI-обёртка

@MainActor
struct RichTextEditor: NSViewRepresentable {
    /// Plain text письма (`draft.body`).
    @Binding var plainText: String
    /// HTML письма (`draft.htmlBody`), nil — без форматирования.
    @Binding var html: String?
    let controller: RichTextController
    /// Подпись текущего ящика — чтобы пометить её блок при загрузке.
    var signature: String
    var initialFocus: Bool
    var onFileDrop: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 5
        layoutManager.addTextContainer(container)

        let textView = ComposeTextView(frame: .zero, textContainer: container)
        textView.ownedStorage = storage
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 7, height: 18)

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.allowsDocumentBackgroundColorChange = false
        textView.linkTextAttributes = [
            .foregroundColor: UM.accentNS,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.typingAttributes = RichTextBridge.attributes(style: RichStyle(), level: 0, list: nil, signature: false)
        textView.controller = controller
        textView.onFileDrop = onFileDrop
        textView.wantsInitialFocus = initialFocus
        textView.delegate = context.coordinator
        controller.textView = textView

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.load(plain: plainText, html: html, signature: signature, into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposeTextView else { return }
        textView.onFileDrop = onFileDrop
        textView.controller = controller
        if controller.textView !== textView { controller.textView = textView }
        // Текст поменяли снаружи (не из редактора) — перезагружаем.
        if plainText != coordinator.lastPlain, plainText != coordinator.lastLoadedInput, !textView.hasMarkedText() {
            coordinator.load(plain: plainText, html: html, signature: signature, into: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        /// Plain text, который редактор опубликовал последним.
        var lastPlain: String?
        /// Входной текст последней загрузки (чтобы не перезагружаться в цикле).
        var lastLoadedInput: String?
        private var isLoading = false

        init(parent: RichTextEditor) { self.parent = parent }

        func load(plain: String, html: String?, signature: String, into textView: ComposeTextView) {
            guard let storage = textView.textStorage else { return }
            isLoading = true
            lastLoadedInput = plain
            let model = RichText.markSignature(signature, in: RichText.load(plain: plain, html: html))
            storage.setAttributedString(RichTextBridge.attributedString(from: model))
            if let undoManager = textView.undoManager {
                undoManager.removeAllActions(withTarget: storage)
                undoManager.removeAllActions(withTarget: textView)
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            let first = RichTextBridge.paragraph(in: storage, at: 0)
            textView.typingAttributes = RichTextBridge.attributes(
                style: RichStyle(), level: first.level, list: first.effectiveList, signature: false
            )
            isLoading = false
            // Загрузка идёт во время обновления SwiftUI — привязки меняем асинхронно.
            publish(from: textView, deferred: true)
        }

        func publish(from textView: NSTextView, deferred: Bool) {
            guard let storage = textView.textStorage else { return }
            let model = RichTextBridge.model(from: storage)
            let plain = RichText.plainText(model)
            let html = RichText.html(model)
            lastPlain = plain
            if deferred {
                DispatchQueue.main.async { [weak self] in
                    self?.applyBindings(plain: plain, html: html)
                }
            } else {
                lastLoadedInput = nil
                applyBindings(plain: plain, html: html)
            }
        }

        private func applyBindings(plain: String, html: String?) {
            if parent.plainText != plain { parent.plainText = plain }
            if parent.html != html { parent.html = html }
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView = notification.object as? ComposeTextView else { return }
            let controller = parent.controller
            guard !controller.isNormalizing, !textView.hasMarkedText() else { return }
            controller.normalize()
            publish(from: textView, deferred: false)
            controller.refreshState()
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
                      toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
            guard !isLoading else { return newSelectedCharRange }
            return parent.controller.adjustedSelection(from: oldSelectedCharRange, to: newSelectedCharRange)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading else { return }
            parent.controller.selectionDidChange()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !isLoading else { return false }
            return parent.controller.handle(command: commandSelector)
        }
    }
}
