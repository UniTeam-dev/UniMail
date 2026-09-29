import Foundation

/// Преобразование атрибутов FETCH в модели модуля.
enum IMAPFetchParsing {
    /// Секция заголовков, запрашиваемая для сводок.
    static let headerFields = ["REFERENCES", "LIST-UNSUBSCRIBE", "LIST-UNSUBSCRIBE-POST", "CONTENT-TYPE"]

    // MARK: ENVELOPE

    /// `(date subject from sender reply-to to cc bcc in-reply-to message-id)`
    static func envelope(_ value: IMAPValue?) -> IMAPEnvelope {
        guard let items = value?.list else { return IMAPEnvelope() }
        func item(_ i: Int) -> IMAPValue? { i < items.count ? items[i] : nil }
        var env = IMAPEnvelope()
        if let d = headerString(item(0)) { env.date = IMAPDate.parseRFC5322(d) }
        env.subject = headerString(item(1)).map(IMAPHeaderDecoding.decode)
        env.from = addresses(item(2))
        let sender = addresses(item(3))
        if env.from.isEmpty { env.from = sender }
        env.replyTo = addresses(item(4))
        env.to = addresses(item(5))
        env.cc = addresses(item(6))
        env.inReplyTo = headerString(item(8)).map(cleanMessageID).flatMap { $0.isEmpty ? nil : $0 }
        env.messageID = headerString(item(9)).map(cleanMessageID).flatMap { $0.isEmpty ? nil : $0 }
        return env
    }

    /// Строка заголовка из значения: сырые 8-битные байты — UTF-8, а если невалидно — windows-1251.
    static func headerString(_ value: IMAPValue?) -> String? {
        guard let value, let data = value.data else { return nil }
        let s = IMAPHeaderDecoding.decodeText(data, charset: nil)
        return s.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
    }

    /// Message-ID без лишних пробелов; первый `<...>`, если их несколько.
    static func cleanMessageID(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let open = t.firstIndex(of: "<"), let close = t[open...].firstIndex(of: ">") {
            return String(t[open...close])
        }
        return t
    }

    /// Список адресов `((name adl mailbox host) …)`; группы (host = NIL) пропускаются.
    static func addresses(_ value: IMAPValue?) -> [Address] {
        guard let list = value?.list else { return [] }
        var out: [Address] = []
        for entry in list {
            guard let a = entry.list, a.count >= 4 else { continue }
            let mailbox = headerString(a[2])
            let host = headerString(a[3])
            guard let mailbox, let host else { continue }            // начало/конец группы
            let email = host.isEmpty ? mailbox : "\(mailbox)@\(host)"
            var name = headerString(a[0]).map(IMAPHeaderDecoding.decode)?.trimmingCharacters(in: .whitespaces)
            if let n = name, n.count >= 2, n.hasPrefix("\""), n.hasSuffix("\"") { name = String(n.dropFirst().dropLast()) }
            if name?.isEmpty == true || name == email { name = nil }
            out.append(Address(name: name, email: email))
        }
        return out
    }

    // MARK: FLAGS / метки

    static func flags(_ value: IMAPValue?) -> Set<String> {
        Set(value?.list?.compactMap(\.text) ?? [])
    }

    static func modSeq(_ value: IMAPValue?) -> UInt64? {
        if let l = value?.list { return l.first?.number }
        return value?.number
    }

    /// X-GM-LABELS: атомы (`\Inbox`, `\Important`) и строки, имена в modified UTF-7.
    static func gmailLabels(_ value: IMAPValue?) -> [String] {
        guard let l = value?.list else { return [] }
        return l.compactMap { v in
            guard let d = v.data else { return nil }
            return IMAPUTF7.decode(IMAPHeaderDecoding.decodeText(d, charset: "utf-8"))
        }
    }

    // MARK: Сводка

    /// Сводка из атрибутов FETCH (без превью). nil — нет UID.
    static func summary(_ attrs: IMAPFetchAttributes) -> IMAPMessageSummary? {
        guard let uid = attrs.uid else { return nil }
        var headers: [String: String] = [:]
        if let h = attrs.value(prefix: "BODY[HEADER.FIELDS")?.data ?? attrs.value(prefix: "BODY[HEADER")?.data {
            let all = IMAPHeaderDecoding.parseHeaderBlock(h)
            for k in headerFields.map({ $0.lowercased() }) { if let v = all[k] { headers[k] = v } }
        }
        let structure = attrs["BODYSTRUCTURE"].flatMap(IMAPBodyPart.parse)
        var hasAttachments = structure?.hasAttachments ?? false
        if structure == nil, let ct = headers["content-type"]?.lowercased(), ct.hasPrefix("multipart/mixed") {
            hasAttachments = true
        }
        return IMAPMessageSummary(
            uid: uid,
            flags: flags(attrs["FLAGS"]),
            internalDate: attrs["INTERNALDATE"]?.text.flatMap(IMAPDate.parseInternalDate),
            size: attrs["RFC822.SIZE"]?.number.map { Int(clamping: $0) },
            modSeq: modSeq(attrs["MODSEQ"]),
            envelope: envelope(attrs["ENVELOPE"]),
            gmailThreadID: attrs["X-GM-THRID"]?.number,
            gmailLabels: gmailLabels(attrs["X-GM-LABELS"]),
            headers: headers,
            hasAttachments: hasAttachments,
            preview: nil
        )
    }
}
