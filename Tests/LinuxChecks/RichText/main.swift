// Проверка RichTextModel.swift на Linux:
//   swiftc Sources/UniMail/UI/Compose/RichTextModel.swift Tests/LinuxChecks/RichText/main.swift -o /tmp/richtext && /tmp/richtext
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL [\(line)]: \(message)")
    }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", line: Int = #line) {
    if a != b {
        failures += 1
        print("FAIL [\(line)]: \(message)\n  got:      \(a)\n  expected: \(b)")
    }
}

func p(_ text: String, _ style: RichStyle = RichStyle(), list: RichListKind? = nil, quote: Int = 0) -> RichParagraph {
    RichParagraph(runs: text.isEmpty ? [] : [RichRun(text: text, style: style)], list: list, quoteLevel: quote)
}
var bold: RichStyle { var s = RichStyle(); s.bold = true; return s }

// MARK: Экранирование
expectEqual(RichText.escapeText("a < b & c > \"d\""), "a &lt; b &amp; c &gt; &quot;d&quot;", "escape text")
expectEqual(RichText.escapeText("  two  spaces"), " &nbsp;two &nbsp;spaces", "space runs")
expectEqual(RichText.escapeText("a\u{2028}b"), "a<br>b", "line separator")
expectEqual(RichText.escapeAttribute("x\"y'z&<>"), "x&quot;y&#39;z&amp;&lt;&gt;", "escape attribute")
expectEqual(RichText.decodeEntities("&lt;b&gt; &amp;amp; &#39;&#x41;&nbsp;&unknown; &"), "<b> &amp; 'A &unknown; &", "decode entities")

// MARK: Ссылки
expectEqual(RichText.sanitizeLink("example.com/path"), "https://example.com/path")
expectEqual(RichText.sanitizeLink(" https://a.ru?x=1&y=2 "), "https://a.ru?x=1&y=2")
expectEqual(RichText.sanitizeLink("anna@example.com"), "mailto:anna@example.com")
expectEqual(RichText.sanitizeLink("mailto:anna@example.com"), "mailto:anna@example.com")
expectEqual(RichText.sanitizeLink("localhost:8080/x"), "https://localhost:8080/x")
expectEqual(RichText.sanitizeLink("javascript:alert(1)"), nil)
expectEqual(RichText.sanitizeLink("JavaScript:alert(1)"), nil)
expectEqual(RichText.sanitizeLink("data:text/html,x"), nil)
expectEqual(RichText.sanitizeLink("with space.com"), nil)
expectEqual(RichText.sanitizeLink(""), nil)

// MARK: Plain text
let reply = "Спасибо!\n\n--\nАнна\n\n28 сентября 2026 г., Иван <i@x.ru> пишет:\n> Привет\n> \n> > старое\n> • пункт\n> 1. первый\n> 2. второй"
let replyModel = RichText.parsePlain(reply)
expectEqual(replyModel.count, 12, "reply paragraph count")
expectEqual(replyModel[6].quoteLevel, 1)
expectEqual(replyModel[7].quoteLevel, 1)
check(replyModel[7].isBlank, "empty quoted line")
expectEqual(replyModel[8].quoteLevel, 2)
expectEqual(replyModel[8].text, "старое")
expectEqual(replyModel[9].list, .bullet)
expectEqual(replyModel[10].list, .ordered)
expectEqual(RichText.plainText(replyModel), reply, "plain round trip")
expectEqual(RichText.listNumbers(replyModel)[10...11].map { $0 }, [1, 2])
expectEqual(RichText.parsePlainLine("2026. год").list, nil, "4 digits is not a list")
expectEqual(RichText.parsePlainLine("12.3 км").list, nil)
expectEqual(RichText.parsePlainLine("3. x").list, .ordered)
expectEqual(RichText.plainText([p("a\u{2028}b", quote: 1)]), "> a\n> b", "line separator in quote")
expectEqual(RichText.plainText([p("x\u{FFFC}y")]), "xy", "attachment char dropped")

// MARK: HTML
expectEqual(RichText.html([p("Привет"), p(""), p("--"), p("Анна")]), nil, "no formatting → nil")
expectEqual(RichText.html([]), nil)

let doc1: [RichParagraph] = [
    p(""), p(""),
    RichParagraph(runs: [RichRun(text: "Hello "), RichRun(text: "bold", style: bold), RichRun(text: " & <x>")]),
    p("line two"),
    p(""),
    p(""),
    p("after gap"),
    p("one", list: .bullet), p("two", list: .bullet),
    p("first", list: .ordered), p("", list: .ordered),
    p(""),
    p("attr:"),
    p("quoted", quote: 1), p("", quote: 1), p("deeper", quote: 2), p("back", quote: 1),
    p(""),
]
let html1 = RichText.html(doc1) ?? ""
let q = RichText.blockquoteOpen
let expected1 = "<p>Hello <b>bold</b> &amp; &lt;x&gt;<br>line two</p><p><br></p><p>after gap</p>"
    + "<ul><li>one</li><li>two</li></ul><ol><li>first</li><li><br></li></ol>"
    + "<p><br></p><p>attr:</p>"
    + q + "<p>quoted</p><p><br></p>" + q + "<p>deeper</p></blockquote><p>back</p></blockquote>"
expectEqual(html1, expected1, "html structure")

// Разбор своего HTML возвращает ту же модель (без пустых краёв).
let parsed1 = RichText.parseHTML(html1)
expectEqual(parsed1, Array(doc1[2..<(doc1.count - 1)]), "parse(html) inverse")

// Строчные стили и ссылки.
var fancy = RichStyle()
fancy.bold = true; fancy.italic = true; fancy.underline = true; fancy.strikethrough = true
fancy.size = .large; fancy.link = "example.com"
var small = RichStyle(); small.size = .small
let doc2 = [RichParagraph(runs: [RichRun(text: "x", style: fancy), RichRun(text: " tiny", style: small), RichRun(text: "  end")])]
let html2 = RichText.html(doc2) ?? ""
expectEqual(html2, "<p><a href=\"https://example.com\"><b><i><u><s><span style=\"font-size:large\">x</span></s></u></i></b></a><span style=\"font-size:small\"> tiny</span> &nbsp;end</p>", "inline html")
var fancyParsed = fancy; fancyParsed.link = "https://example.com"
expectEqual(RichText.parseHTML(html2), [RichParagraph(runs: [RichRun(text: "x", style: fancyParsed), RichRun(text: " tiny", style: small), RichRun(text: "  end")])], "inline parse")

// Опасная ссылка не попадает в HTML.
var evil = RichStyle(); evil.link = "javascript:alert(1)"
expectEqual(RichText.html([RichParagraph(runs: [RichRun(text: "click", style: evil)])]), "<p>click</p>", "unsafe link dropped")

// Пустые строки на границах сегментов.
let doc3: [RichParagraph] = [p("a", bold), p(""), p("q", quote: 1), p(""), p(""), p("b")]
let html3 = RichText.html(doc3) ?? ""
expectEqual(html3, "<p><b>a</b></p><p><br></p>" + q + "<p>q</p></blockquote><p><br></p><p><br></p><p>b</p>", "segment empties")
expectEqual(RichText.parseHTML(html3), doc3, "segment empties parse")

// Разрыв строки внутри пункта списка.
let doc4 = [p("a\u{2028}b", list: .bullet)]
expectEqual(RichText.html(doc4), "<ul><li>a<br>b</li></ul>")
expectEqual(RichText.parseHTML("<ul><li>a<br>b</li></ul>"), doc4)

// Терпимый разбор чужого HTML.
let foreign = "<!DOCTYPE html><html><head><style>p{color:red}</style></head><body>\n<div>Hi <strong>there</strong></div>\n<div><br></div><div>Next &amp; last</div></body></html>"
let foreignModel = RichText.parseHTML(foreign)
expectEqual(RichText.plainText(foreignModel), "Hi there\n\nNext & last", "foreign html")
expectEqual(RichText.plainText(RichText.parseHTML("Line<br>next<blockquote>q</blockquote>")), "Line\nnext\n> q", "implicit paragraphs")

// MARK: Загрузка черновика
let body = "\n\nHello bold\n\n--\nАнна"
var helloRuns = [RichRun(text: "Hello "), RichRun(text: "bold", style: bold)]
let editorModel = [p(""), p(""), RichParagraph(runs: helloRuns), p(""), p("--"), p("Анна")]
expectEqual(RichText.plainText(editorModel), body)
let storedHTML = RichText.html(editorModel)
let loaded = RichText.load(plain: body, html: storedHTML)
expectEqual(loaded, editorModel, "load from html restores formatting and edge blanks")
// Несогласованный HTML — берём plain.
expectEqual(RichText.load(plain: "Other text", html: storedHTML), RichText.parsePlain("Other text"), "mismatch falls back")
expectEqual(RichText.load(plain: "", html: nil), [RichParagraph()], "empty body")
helloRuns.removeAll()

// MARK: Подпись
let signed = RichText.markSignature("Анна\nСеверлаб", in: RichText.parsePlain("Текст\n\n--\nАнна\nСеверлаб\n\nцитата:\n> --\n> Анна"))
expectEqual(signed.count, 9)
check(signed[2].runs.allSatisfy(\.isSignature) && signed[3].runs.allSatisfy(\.isSignature) && signed[4].runs.allSatisfy(\.isSignature), "signature marked")
check(!signed[0].runs.contains(where: \.isSignature) && !signed[8].runs.contains(where: \.isSignature) && !signed[7].runs.contains(where: \.isSignature), "only signature marked")
expectEqual(RichText.html(Array(signed[0..<6])), nil, "signature flag is not formatting")
expectEqual(RichText.markSignature("", in: signed), signed)

// MARK: CSS
expectEqual(RichText.cssFontSize("color:red; font-size: 11px"), .small)
expectEqual(RichText.cssFontSize("font-size:x-large"), .large)
expectEqual(RichText.cssFontSize("color:red"), nil)
expectEqual(RichText.attributeValue("href", in: " class=x HREF='a b'"), "a b")
expectEqual(RichText.attributeValue("href", in: " data-href=\"no\" href=yes"), "yes")

if failures == 0 {
    print("RichText: all checks passed")
} else {
    print("RichText: \(failures) failure(s)")
    exit(1)
}
