import Foundation

/// Подготовка HTML письма к показу: вырезаем скрипты, обработчики событий и трекинг-пиксели,
/// считаем удалённые изображения. Сетевые запросы дополнительно режет WKContentRuleList.
///
/// Этап 1: заменить регулярные выражения на SwiftSoup (полноценный DOM-санитайзер по allowlist).
enum HTMLSanitizer {
    struct Prepared {
        var html: String
        var trackers: Int
        var blockedImages: Int
    }

    static func prepare(_ raw: String, allowRemote: Bool) -> Prepared {
        var html = raw
        html = replace(#"(?is)<script\b.*?</script>"#, in: html, with: "")
        html = replace(#"(?is)<iframe\b.*?</iframe>"#, in: html, with: "")
        html = replace(#"(?i)\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, in: html, with: "")
        html = replace(#"(?i)javascript:"#, in: html, with: "")

        // Трекинг-пиксели: картинки 1×1 или 0×0 вырезаются всегда, даже если картинки разрешены.
        let trackerPattern = #"(?is)<img\b[^>]*\b(width|height)\s*=\s*["']?[01](px)?["']?[^>]*>"#
        let trackers = count(trackerPattern, in: html)
        html = replace(trackerPattern, in: html, with: "")

        let remote = allowRemote ? 0 : count(#"(?is)<img\b[^>]*\bsrc\s*=\s*["']?https?://"#, in: html)

        let page = """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; \(allowRemote ? "" : "img-src data: cid:;")">
        <style>
          html, body { margin: 0; padding: 0; background: #fff; }
          body { font: 14px/1.5 -apple-system, "Helvetica Neue", sans-serif; color: #1d1d1f; padding: 16px; word-wrap: break-word; overflow-wrap: anywhere; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100% !important; }
          a { color: #0a66ff; }
          blockquote { border-left: 3px solid #d0d0d6; margin: 0; padding-left: 12px; color: #6e6e73; }
        </style>
        </head><body>\(html)</body></html>
        """
        return Prepared(html: page, trackers: trackers, blockedImages: remote)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
