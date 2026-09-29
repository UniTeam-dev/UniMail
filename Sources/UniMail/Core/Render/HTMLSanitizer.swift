import Foundation

/// Подготовка HTML письма к показу: вырезаем скрипты, обработчики событий и трекинг-пиксели,
/// заменяем заблокированные удалённые картинки заглушкой «Изображение скрыто».
/// Сетевые запросы дополнительно режет WKContentRuleList.
///
/// Этап 1: заменить регулярные выражения на SwiftSoup (полноценный DOM-санитайзер по allowlist).
enum HTMLSanitizer {
    struct Prepared {
        var html: String
        var trackers: Int
        var blockedImages: Int
    }

    static func prepare(_ raw: String, allowRemote: Bool, stripTrackers: Bool = true) -> Prepared {
        var html = raw
        html = replace(#"(?is)<script\b.*?</script>"#, in: html, with: "")
        html = replace(#"(?is)<iframe\b.*?</iframe>"#, in: html, with: "")
        html = replace(#"(?i)\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, in: html, with: "")
        html = replace(#"(?i)javascript:"#, in: html, with: "")

        // Трекинг-пиксели: картинки 1×1 или 0×0 вырезаются всегда, даже если картинки разрешены.
        let trackerPattern = #"(?is)<img\b[^>]*\b(width|height)\s*=\s*["']?[01](px)?["']?[^>]*>"#
        let trackers = count(trackerPattern, in: html)
        if stripTrackers || !allowRemote {
            html = replace(trackerPattern, in: html, with: "")
        }

        var blocked = 0
        if !allowRemote {
            (html, blocked) = placeholderRemoteImages(html)
        }

        let page = """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; \(allowRemote ? "" : "img-src data: cid:;")">
        <style>
          html, body { margin: 0; padding: 0; background: #FFFFFF; }
          body { font: 14px/1.5 -apple-system, "Helvetica Neue", sans-serif; color: #1A1A1A; word-wrap: break-word; overflow-wrap: anywhere; }
          img { max-width: 100%; height: auto; }
          table { max-width: 100% !important; }
          a { color: #3D6AF2; }
          blockquote { border-left: 3px solid #D0D0D6; margin: 0; padding-left: 12px; color: #6E6E73; }
          .um-hidden-image { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px;
            border-radius: 6px; background: #F2F2F4; color: #8A8A92; font: 12px -apple-system, sans-serif; }
        </style>
        </head><body>\(html)</body></html>
        """
        return Prepared(html: page, trackers: trackers, blockedImages: blocked)
    }

    /// Каждая удалённая картинка → серая заглушка той же высоты (если она указана) с подписью.
    private static func placeholderRemoteImages(_ html: String) -> (String, Int) {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*\bsrc\s*=\s*["']?https?://[^>]*>"#),
              let heightRegex = try? NSRegularExpression(pattern: #"(?i)height\s*[:=]\s*["']?(\d+)"#) else {
            return (html, 0)
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (html, 0) }

        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let tag = ns.substring(with: match.range)
            var height = 140
            if let h = heightRegex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
               let value = Int((tag as NSString).substring(with: h.range(at: 1))) {
                height = value
            }
            if height < 40 {
                result += "" // мелкие логотипы просто скрываем
            } else {
                result += "<div class=\"um-hidden-image\" style=\"height:\(height)px\"><span style=\"font-size:22px\">⌧</span>Изображение скрыто</div>"
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return (result, matches.count)
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
