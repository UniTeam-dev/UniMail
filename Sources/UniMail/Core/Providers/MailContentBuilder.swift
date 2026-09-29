import Foundation

/// Разбор MIME в содержимое для экрана чтения — общий для IMAP и Exchange (EWS отдаёт MIME целиком).
enum MailContentBuilder {
    /// Разбор MIME → содержимое для экрана чтения. Вложения сохраняются в кэш, встроенные картинки
    /// подставляются в HTML как data:-URI (WKWebView с CSP не ходит за cid: и file:).
    static func content(from parsed: ParsedMessage, accountID: UUID, messageID: String, cacheDirectory: URL) -> MessageContent {
        let folder = cacheDirectory
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent(folderName(for: messageID), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var html = parsed.htmlBody
        var attachments: [Attachment] = []
        for part in parsed.attachments {
            if part.isInline, let cid = part.contentID, var current = html, part.data.count < 3_000_000,
               part.mimeType.lowercased().hasPrefix("image/") {
                let uri = "data:\(part.mimeType);base64,\(part.data.base64EncodedString())"
                current = current.replacingOccurrences(of: "cid:\(cid)", with: uri)
                html = current
                continue
            }
            let name = part.filename.isEmpty ? "вложение-\(part.partID)" : part.filename
            let url = folder.appendingPathComponent(safeFileName(name))
            try? part.data.write(to: url, options: .atomic)
            attachments.append(Attachment(
                filename: name, size: part.data.count, mimeType: part.mimeType,
                partID: part.partID, contentID: part.contentID, localPath: url.path
            ))
        }

        var invite: Invite?
        if let ics = parsed.calendar, let event = ICSParser.parse(ics).first,
           (event.method ?? "REQUEST").uppercased() != "CANCEL" {
            invite = Invite(title: event.summary, start: event.start, end: event.end,
                            location: event.location ?? "", organizer: event.organizer, ics: ics)
        }

        let text = parsed.textBody ?? html.map { MailFTS.plainText(fromHTML: $0) }
        return MessageContent(
            text: text, html: html, attachments: attachments, invite: invite,
            listUnsubscribe: parsed.listUnsubscribe, listUnsubscribePost: parsed.listUnsubscribePost,
            references: parsed.references, inReplyTo: parsed.inReplyTo, messageID: parsed.messageID
        )
    }

    static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
        return String(cleaned.prefix(120))
    }


    /// Папка письма в кэше. Id писем Exchange длинные и начинаются одинаково — добавляем хэш, чтобы не совпадали.
    static func folderName(for messageID: String) -> String {
        guard messageID.count > 80 else { return safeFileName(messageID) }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in messageID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(safeFileName(messageID).prefix(40)) + "-" + String(hash, radix: 16)
    }
}
