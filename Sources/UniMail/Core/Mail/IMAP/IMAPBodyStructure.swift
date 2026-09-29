import Foundation

/// Часть письма из BODYSTRUCTURE (RFC 3501 §7.4.2) — ровно то, что нужно для списка писем.
struct IMAPBodyPart: Sendable, Equatable {
    /// Тип и подтип в нижнем регистре.
    var type: String
    var subtype: String
    /// Параметры Content-Type (ключи в нижнем регистре).
    var parameters: [String: String] = [:]
    var contentID: String?
    var encoding: String?
    var size: Int?
    /// `attachment` / `inline` (нижний регистр).
    var disposition: String?
    var dispositionParameters: [String: String] = [:]
    /// Номер части для BODY[…]: "1", "1.2"…
    var partNumber: String
    var children: [IMAPBodyPart] = []

    var mimeType: String { "\(type)/\(subtype)" }
    var isMultipart: Bool { type == "multipart" }
    var charset: String? { parameters["charset"] }
    var filename: String? {
        dispositionParameters["filename"] ?? parameters["name"] ?? dispositionParameters["filename*"]
    }

    /// Все листовые части (без захода внутрь message/rfc822).
    var leaves: [IMAPBodyPart] {
        isMultipart ? children.flatMap(\.leaves) : [self]
    }

    // MARK: Разбор

    static func parse(_ value: IMAPValue) -> IMAPBodyPart? {
        parse(value, partNumber: nil)
    }

    /// `partNumber == nil` — корень сообщения.
    private static func parse(_ value: IMAPValue, partNumber: String?) -> IMAPBodyPart? {
        guard let items = value.list, !items.isEmpty else { return nil }

        if items[0].list != nil {
            // multipart: (body)(body)… "subtype" [params disposition language location]
            var children: [IMAPBodyPart] = []
            var i = 0
            while i < items.count, items[i].list != nil {
                let childNumber = partNumber.map { "\($0).\(children.count + 1)" } ?? "\(children.count + 1)"
                if let child = parse(items[i], partNumber: childNumber) { children.append(child) }
                i += 1
            }
            let subtype = (i < items.count ? items[i].text : nil)?.lowercased() ?? "mixed"
            var part = IMAPBodyPart(type: "multipart", subtype: subtype, partNumber: partNumber ?? "")
            part.children = children
            if i + 1 < items.count { part.parameters = parameters(items[i + 1]) }
            if i + 2 < items.count { applyDisposition(items[i + 2], to: &part) }
            return part
        }

        // Одночастное тело.
        let type = items[0].text?.lowercased() ?? "text"
        let subtype = (items.count > 1 ? items[1].text : nil)?.lowercased() ?? "plain"
        var part = IMAPBodyPart(type: type, subtype: subtype, partNumber: partNumber ?? "1")
        if items.count > 2 { part.parameters = parameters(items[2]) }
        if items.count > 3 { part.contentID = items[3].text }
        if items.count > 5 { part.encoding = items[5].text?.lowercased() }
        if items.count > 6 { part.size = items[6].number.map { Int(clamping: $0) } }

        // Индекс расширений зависит от типа: text — после lines, message/rfc822 — после envelope/body/lines.
        let extensionStart: Int
        if type == "text" { extensionStart = 8 }
        else if type == "message" && (subtype == "rfc822" || subtype == "global") { extensionStart = 10 }
        else { extensionStart = 7 }
        let dispositionIndex = extensionStart + 1
        if dispositionIndex < items.count, isDispositionShape(items[dispositionIndex]) {
            applyDisposition(items[dispositionIndex], to: &part)
        } else {
            // Нестандартный сервер: ищем первый элемент вида ("attachment" (...)).
            for item in items.dropFirst(7) where isDispositionShape(item) {
                applyDisposition(item, to: &part)
                break
            }
        }
        return part
    }

    /// `("attachment" ("filename" "a.pdf"))` или `("inline" NIL)`.
    private static func isDispositionShape(_ v: IMAPValue) -> Bool {
        guard let l = v.list, l.count == 2, l[0].text != nil else { return false }
        return l[1].list != nil || l[1].isNil
    }

    private static func applyDisposition(_ v: IMAPValue, to part: inout IMAPBodyPart) {
        guard let l = v.list, let name = l.first?.text?.lowercased() else { return }
        part.disposition = name
        if l.count > 1 { part.dispositionParameters = parameters(l[1]) }
    }

    private static func parameters(_ v: IMAPValue) -> [String: String] {
        guard let l = v.list else { return [:] }
        var out: [String: String] = [:]
        var i = 0
        while i + 1 < l.count {
            if let k = l[i].text?.lowercased() {
                let raw = l[i + 1].data.map { IMAPHeaderDecoding.decodeText($0, charset: nil) } ?? ""
                out[k] = IMAPHeaderDecoding.decode(raw)
            }
            i += 2
        }
        return out
    }

    // MARK: Выводы для списка писем

    /// Есть ли настоящие вложения.
    var hasAttachments: Bool {
        if !isMultipart { return isAttachmentLeaf(parentSubtype: nil, isRoot: true) }
        return containsAttachment(parentSubtype: nil)
    }

    private func containsAttachment(parentSubtype: String?) -> Bool {
        if isMultipart {
            // multipart/mixed, где помимо первой (текстовой) части есть что-то ещё не текстовое/не альтернативное.
            if subtype == "mixed" {
                for child in children.dropFirst() where !(child.isMultipart && child.subtype == "alternative") {
                    if child.type != "text" || child.disposition == "attachment" || child.filename != nil { return true }
                }
            }
            return children.contains { $0.containsAttachment(parentSubtype: subtype) }
        }
        return isAttachmentLeaf(parentSubtype: parentSubtype, isRoot: false)
    }

    private func isAttachmentLeaf(parentSubtype: String?, isRoot: Bool) -> Bool {
        if disposition == "attachment" { return true }
        if type == "message" && (subtype == "rfc822" || subtype == "global") { return true }
        if type == "application" {
            let ignored = ["pgp-signature", "pkcs7-signature", "x-pkcs7-signature", "pgp-keys", "ics"]
            return !ignored.contains(subtype)
        }
        if type == "text" { return disposition != "inline" && filename != nil && !["plain", "html"].contains(subtype) }
        if isRoot { return type != "text" }
        // Картинки внутри multipart/related и inline с Content-ID — встроенные в HTML, не вложения.
        if parentSubtype == "related" { return false }
        if disposition == "inline" && contentID != nil { return false }
        return filename != nil || ["image", "audio", "video"].contains(type)
    }

    /// Часть для превью: text/plain (не вложение), иначе text/html.
    var previewPart: IMAPBodyPart? {
        let candidates = leaves.filter { $0.type == "text" && $0.disposition != "attachment" && ($0.filename == nil || $0.disposition == "inline") }
        return candidates.first { $0.subtype == "plain" } ?? candidates.first { $0.subtype == "html" }
    }
}
