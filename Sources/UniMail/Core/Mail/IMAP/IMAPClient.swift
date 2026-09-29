import Foundation

/// IMAP4rev1-клиент поверх `MailTransport` (RFC 3501 + CONDSTORE/QRESYNC, UIDPLUS, MOVE, IDLE,
/// LITERAL+/-, SPECIAL-USE, SASL-IR, X-GM-EXT-1).
///
/// Команды выполняются строго по одной (внутренняя очередь): параллельные вызовы из разных задач
/// ждут своей очереди. `idle` удерживает соединение до таймаута, прихода изменений или `stopIdle()`.
actor IMAPClient {
    /// Кусок команды: текст или литерал (синхронный `{n}` либо `{n+}` при LITERAL+/LITERAL-).
    enum CommandPart: Sendable {
        case text(String)
        case literal(Data)
    }

    struct CommandResult: Sendable {
        var untagged: [IMAPUntagged]
        var status: IMAPStatusResponse
    }

    /// Размер пачки UID для FETCH сводок.
    static let fetchBatchSize = 100
    /// Размер пачки UID для STORE/COPY/MOVE/EXPUNGE.
    static let storeBatchSize = 500
    /// Длина фрагмента для превью.
    static let previewBytes = 2048
    /// Защита от безумных литералов.
    static let maxLiteralSize = 512 * 1024 * 1024

    private let transport: MailTransport
    private var reader: LineReader
    /// Возможности сервера в верхнем регистре (`IMAP4REV1`, `IDLE`, `AUTH=PLAIN`…).
    private(set) var capabilities: Set<String> = []
    /// Что включено через ENABLE.
    private(set) var enabledExtensions: Set<String> = []
    /// Открытая папка (Unicode-имя) и её режим.
    private(set) var selectedFolder: String?

    private var tagCounter = 0
    private var capabilityGeneration = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loggingOut = false
    private var inSelect = false
    /// Были изменения ящика вне IDLE (NOOP, неожиданный EXISTS) — следующий `idle` вернёт true сразу.
    private var pendingChanges = false
    private var idleTag: String?
    private var idleDoneSent = false

    init(transport: MailTransport) {
        self.transport = transport
        self.reader = LineReader(transport: transport)
    }

    // MARK: - Подключение и вход

    /// Читает приветствие сервера. Если в нём нет `[CAPABILITY …]` — запрашивает CAPABILITY.
    func connect() async throws {
        await lock()
        defer { unlock() }
        let generation = capabilityGeneration
        greetingLoop: while true {
            let response = try await readResponse()
            switch response {
            case .untagged(.status(let s)):
                if s.status == .bye { throw IMAPError.unexpected(s.text.isEmpty ? "BYE" : s.text) }
                if s.status == .bad || s.status == .no { throw IMAPError.unexpected(s.text) }
                if let code = s.code { applyCode(code) }
                break greetingLoop
            case .untagged(let u):
                try handleUntagged(u)   // некоторые серверы шлют CAPABILITY до приветствия
            default:
                throw IMAPError.unexpected("Нет приветствия сервера")
            }
        }
        if capabilityGeneration == generation || capabilities.isEmpty {
            _ = try await refreshCapabilitiesUnlocked()
        }
    }

    func refreshCapabilities() async throws -> Set<String> {
        await lock()
        defer { unlock() }
        return try await refreshCapabilitiesUnlocked()
    }

    private func refreshCapabilitiesUnlocked() async throws -> Set<String> {
        let result = try await execute([.text("CAPABILITY")])
        for case .capability(let caps) in result.untagged { setCapabilities(caps) }
        return capabilities
    }

    /// STARTTLS: команда, переключение транспорта, сброс буфера и повторный CAPABILITY.
    func startTLS() async throws {
        await lock()
        defer { unlock() }
        _ = try await execute([.text("STARTTLS")])
        try await transport.startTLS()
        reader = LineReader(transport: transport)   // всё, что пришло до TLS, выбрасываем
        capabilities = []
        _ = try await refreshCapabilitiesUnlocked()
    }

    /// AUTHENTICATE PLAIN (если есть AUTH=PLAIN; с SASL-IR — одной строкой), иначе LOGIN.
    /// NO от сервера → `IMAPError.authenticationFailed`.
    func login(username: String, password: String) async throws {
        await lock()
        defer { unlock() }
        let generation = capabilityGeneration
        do {
            if capabilities.contains("AUTH=PLAIN") {
                do {
                    try await authenticatePlain(username: username, password: password)
                } catch IMAPError.bad(let text) {
                    // Сломанный AUTHENTICATE — пробуем LOGIN, если он разрешён.
                    guard !capabilities.contains("LOGINDISABLED") else { throw IMAPError.authenticationFailed(text) }
                    try await loginCommand(username: username, password: password)
                }
            } else if capabilities.contains("LOGINDISABLED") {
                throw IMAPError.authenticationFailed("Сервер запрещает вход без шифрования (LOGINDISABLED)")
            } else {
                try await loginCommand(username: username, password: password)
            }
        } catch IMAPError.no(let text) {
            throw IMAPError.authenticationFailed(text)
        }
        if capabilityGeneration == generation {
            _ = try await refreshCapabilitiesUnlocked()
        }
    }

    private func loginCommand(username: String, password: String) async throws {
        _ = try await execute([.text("LOGIN "), Self.astring(username), .text(" "), Self.astring(password)])
    }

    private func authenticatePlain(username: String, password: String) async throws {
        var raw = Data([0])
        raw.append(Data(username.utf8))
        raw.append(0)
        raw.append(Data(password.utf8))
        let token = raw.base64EncodedString()
        if capabilities.contains("SASL-IR") {
            _ = try await execute([.text("AUTHENTICATE PLAIN " + token)], onContinuation: { _ in "*" })
        } else {
            var sent = false
            _ = try await execute([.text("AUTHENTICATE PLAIN")], onContinuation: { _ in
                if sent { return "*" }   // повторный вызов — отменяем обмен
                sent = true
                return token
            })
        }
    }

    /// ENABLE QRESYNC/CONDSTORE, если сервер их объявляет. Без ENABLE CONDSTORE включается через SELECT (CONDSTORE).
    func enableCondStore() async throws {
        await lock()
        defer { unlock() }
        guard capabilities.contains("ENABLE") else { return }
        var extensions: [String] = []
        if capabilities.contains("QRESYNC") { extensions = ["QRESYNC", "CONDSTORE"] }
        else if capabilities.contains("CONDSTORE") { extensions = ["CONDSTORE"] }
        guard !extensions.isEmpty else { return }
        let result = try await execute([.text("ENABLE " + extensions.joined(separator: " "))])
        for case .enabled(let names) in result.untagged { enabledExtensions.formUnion(names) }
        if enabledExtensions.contains("QRESYNC") { enabledExtensions.insert("CONDSTORE") }
    }

    private var condStoreAvailable: Bool {
        capabilities.contains("CONDSTORE") || capabilities.contains("QRESYNC") || enabledExtensions.contains("CONDSTORE")
    }

    // MARK: - Папки

    /// LIST "" "*" (с RETURN (SPECIAL-USE), если сервер умеет). Роли — по SPECIAL-USE и эвристикам имён.
    func listFolders() async throws -> [IMAPFolder] {
        await lock()
        defer { unlock() }
        var result: CommandResult
        if capabilities.contains("SPECIAL-USE") && capabilities.contains("LIST-EXTENDED") {
            do {
                result = try await execute([.text("LIST \"\" \"*\" RETURN (SPECIAL-USE)")])
            } catch IMAPError.bad, IMAPError.no {
                result = try await execute([.text("LIST \"\" \"*\"")])
            }
        } else {
            result = try await execute([.text("LIST \"\" \"*\"")])
        }
        var folders: [IMAPFolder] = []
        var seen = Set<String>()
        for case .list(let entry) in result.untagged {
            var name = entry.name
            if name.uppercased() == "INBOX" { name = "INBOX" }
            guard !name.isEmpty, !seen.contains(name) else { continue }
            let attrs = Set(entry.attributes)
            if attrs.contains(where: { $0.lowercased() == "\\nonexistent" }) { continue }
            seen.insert(name)
            folders.append(IMAPFolder(name: name, delimiter: entry.delimiter, attributes: attrs, role: nil))
        }
        IMAPFolderRoles.assignRoles(&folders)
        return folders
    }

    /// SELECT (или EXAMINE при `readOnly`). При доступном CONDSTORE без ENABLE добавляет `(CONDSTORE)`.
    func select(_ folder: String, readOnly: Bool) async throws -> IMAPSelectInfo {
        await lock()
        defer { unlock() }
        var parts: [CommandPart] = [.text(readOnly ? "EXAMINE " : "SELECT "), Self.mailbox(folder)]
        if capabilities.contains("CONDSTORE") && !enabledExtensions.contains("CONDSTORE") {
            parts.append(.text(" (CONDSTORE)"))
        }
        inSelect = true
        defer { inSelect = false }
        selectedFolder = nil
        let result = try await execute(parts)
        var info = IMAPSelectInfo(uidValidity: 0, uidNext: nil, exists: 0, highestModSeq: nil)
        func apply(_ code: IMAPResponseCode?) {
            guard let code else { return }
            switch code.name {
            case "UIDVALIDITY": info.uidValidity = code.firstNumber.flatMap { UInt32(exactly: $0) } ?? info.uidValidity
            case "UIDNEXT": info.uidNext = code.firstNumber.flatMap { UInt32(exactly: $0) }
            case "HIGHESTMODSEQ": info.highestModSeq = code.firstNumber
            default: break
            }
        }
        for u in result.untagged {
            switch u {
            case .exists(let n): info.exists = n
            case .status(let s): apply(s.code)
            default: break
            }
        }
        apply(result.status.code)
        selectedFolder = folder
        pendingChanges = false
        return info
    }

    // MARK: - Поиск и загрузка

    /// UID SEARCH с сырыми критериями. Строки в кавычках с не-ASCII отправляются литералами с CHARSET UTF-8.
    func uidSearch(_ criteria: String) async throws -> [UInt32] {
        await lock()
        defer { unlock() }
        let (parts, needsCharset) = Self.searchParts(criteria)
        var command: [CommandPart] = [.text("UID SEARCH ")]
        if needsCharset && !criteria.uppercased().hasPrefix("CHARSET") { command.append(.text("CHARSET UTF-8 ")) }
        command += parts
        let result = try await execute(command)
        var uids: [UInt32] = []
        for u in result.untagged {
            switch u {
            case .search(let list), .esearch(let list): uids += list
            default: break
            }
        }
        return Array(Set(uids)).sorted()
    }

    func fetchSummaries(uids: [UInt32]) async throws -> [IMAPMessageSummary] {
        try await fetchSummaries(uids: uids, includePreview: true)
    }

    /// Сводки пачками по 100 UID. Второй проход (если `includePreview`) — начало текстовой части
    /// (`BODY.PEEK[<часть>]<0.2048>`), найденной по BODYSTRUCTURE.
    func fetchSummaries(uids: [UInt32], includePreview: Bool) async throws -> [IMAPMessageSummary] {
        await lock()
        defer { unlock() }
        let ordered = Self.unique(uids)
        guard !ordered.isEmpty else { return [] }

        var items = "UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS ("
            + IMAPFetchParsing.headerFields.joined(separator: " ") + ")]"
        if condStoreAvailable { items += " MODSEQ" }
        if capabilities.contains("X-GM-EXT-1") { items += " X-GM-THRID X-GM-LABELS" }

        var summaries: [UInt32: IMAPMessageSummary] = [:]
        var previewParts: [UInt32: (section: String, part: IMAPBodyPart)] = [:]

        for batch in Self.chunks(ordered, size: Self.fetchBatchSize) {
            let result = try await execute([.text("UID FETCH \(IMAPSequenceSet.compress(batch)) (\(items))")])
            for attrs in Self.mergedFetches(result.untagged) {
                guard let summary = IMAPFetchParsing.summary(attrs) else { continue }
                summaries[summary.uid] = summary
                if includePreview, let root = attrs["BODYSTRUCTURE"].flatMap(IMAPBodyPart.parse), let part = root.previewPart {
                    let section = root.isMultipart ? part.partNumber : "TEXT"
                    previewParts[summary.uid] = (section, part)
                }
            }
        }

        if includePreview && !previewParts.isEmpty {
            var bySection: [String: [UInt32]] = [:]
            for (uid, p) in previewParts { bySection[p.section, default: []].append(uid) }
            for (section, sectionUIDs) in bySection.sorted(by: { $0.key < $1.key }) {
                for batch in Self.chunks(sectionUIDs.sorted(), size: Self.fetchBatchSize) {
                    let result = try await execute([.text("UID FETCH \(IMAPSequenceSet.compress(batch)) (UID BODY.PEEK[\(section)]<0.\(Self.previewBytes)>)")])
                    for attrs in Self.mergedFetches(result.untagged) {
                        guard let uid = attrs.uid, let info = previewParts[uid],
                              let data = attrs.value(prefix: "BODY[\(section)]")?.data else { continue }
                        summaries[uid]?.preview = IMAPHeaderDecoding.previewText(
                            from: data, encoding: info.part.encoding, charset: info.part.charset,
                            isHTML: info.part.subtype == "html")
                    }
                }
            }
        }
        return ordered.compactMap { summaries[$0] }
    }

    /// Флаги всех писем, изменённых после `modSeq` (CONDSTORE, `CHANGEDSINCE`).
    func fetchFlags(changedSince modSeq: UInt64) async throws -> [IMAPFlagUpdate] {
        await lock()
        defer { unlock() }
        guard condStoreAvailable else { throw IMAPError.unexpected("Сервер не поддерживает CONDSTORE") }
        let result = try await execute([.text("UID FETCH 1:* (UID FLAGS MODSEQ) (CHANGEDSINCE \(modSeq))")])
        return Self.flagUpdates(result.untagged)
    }

    /// Флаги указанных писем (полная сверка без CONDSTORE).
    func fetchFlags(uids: [UInt32]) async throws -> [IMAPFlagUpdate] {
        await lock()
        defer { unlock() }
        var out: [IMAPFlagUpdate] = []
        let items = condStoreAvailable ? "UID FLAGS MODSEQ" : "UID FLAGS"
        for batch in Self.chunks(Self.unique(uids), size: Self.storeBatchSize) {
            let result = try await execute([.text("UID FETCH \(IMAPSequenceSet.compress(batch)) (\(items))")])
            out += Self.flagUpdates(result.untagged)
        }
        return out
    }

    /// Письмо целиком (RFC 822), без установки \Seen.
    func fetchMessage(uid: UInt32) async throws -> Data {
        try await fetchSection(uid: uid, section: "")
    }

    /// Часть письма по номеру (`1.2`, `TEXT`, `HEADER`…) — сырые байты без снятия transfer-encoding.
    func fetchPart(uid: UInt32, section: String) async throws -> Data {
        try await fetchSection(uid: uid, section: section)
    }

    private func fetchSection(uid: UInt32, section: String) async throws -> Data {
        await lock()
        defer { unlock() }
        let result = try await execute([.text("UID FETCH \(uid) (UID BODY.PEEK[\(section)])")])
        let key = "BODY[\(section.uppercased())]"
        for attrs in Self.mergedFetches(result.untagged) where attrs.uid == nil || attrs.uid == uid {
            if let data = attrs.value(prefix: key)?.data { return data }
            if attrs.value(prefix: key)?.isNil == true { return Data() }
        }
        throw IMAPError.unexpected("Письмо UID \(uid) не найдено на сервере")
    }

    // MARK: - Изменения

    /// UID STORE ±FLAGS.SILENT.
    func store(uids: [UInt32], flags: [String], add: Bool) async throws {
        await lock()
        defer { unlock() }
        try await storeUnlocked(uids: uids, flags: flags, add: add)
    }

    private func storeUnlocked(uids: [UInt32], flags: [String], add: Bool) async throws {
        let clean = flags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        for batch in Self.chunks(Self.unique(uids), size: Self.storeBatchSize) {
            _ = try await execute([.text("UID STORE \(IMAPSequenceSet.compress(batch)) \(add ? "+" : "-")FLAGS.SILENT (\(clean.joined(separator: " ")))")])
        }
    }

    /// UID MOVE, а без MOVE — UID COPY + \Deleted + UID EXPUNGE (или EXPUNGE без UIDPLUS).
    func move(uids: [UInt32], to folder: String) async throws {
        await lock()
        defer { unlock() }
        let list = Self.unique(uids)
        guard !list.isEmpty else { return }
        if capabilities.contains("MOVE") {
            for batch in Self.chunks(list, size: Self.storeBatchSize) {
                _ = try await execute([.text("UID MOVE \(IMAPSequenceSet.compress(batch)) "), Self.mailbox(folder)])
            }
        } else {
            try await copyUnlocked(uids: list, to: folder)
            try await storeUnlocked(uids: list, flags: ["\\Deleted"], add: true)
            try await expungeDeleted(list)
        }
    }

    func copy(uids: [UInt32], to folder: String) async throws {
        await lock()
        defer { unlock() }
        try await copyUnlocked(uids: uids, to: folder)
    }

    private func copyUnlocked(uids: [UInt32], to folder: String) async throws {
        for batch in Self.chunks(Self.unique(uids), size: Self.storeBatchSize) {
            _ = try await execute([.text("UID COPY \(IMAPSequenceSet.compress(batch)) "), Self.mailbox(folder)])
        }
    }

    /// Помечает \Deleted и удаляет только эти письма (UID EXPUNGE). Без UIDPLUS — обычный EXPUNGE.
    func expunge(uids: [UInt32]) async throws {
        await lock()
        defer { unlock() }
        let list = Self.unique(uids)
        guard !list.isEmpty else { return }
        try await storeUnlocked(uids: list, flags: ["\\Deleted"], add: true)
        try await expungeDeleted(list)
    }

    private func expungeDeleted(_ uids: [UInt32]) async throws {
        if capabilities.contains("UIDPLUS") {
            for batch in Self.chunks(uids, size: Self.storeBatchSize) {
                _ = try await execute([.text("UID EXPUNGE \(IMAPSequenceSet.compress(batch))")])
            }
        } else {
            _ = try await execute([.text("EXPUNGE")])
        }
    }

    /// APPEND с литералом (LITERAL+ — без ожидания «+»). Возвращает UID из `[APPENDUID v uid]`.
    func append(folder: String, message: Data, flags: [String], date: Date?) async throws -> UInt32? {
        await lock()
        defer { unlock() }
        var parts: [CommandPart] = [.text("APPEND "), Self.mailbox(folder)]
        let clean = flags.filter { !$0.isEmpty && $0.lowercased() != "\\recent" }
        if !clean.isEmpty { parts.append(.text(" (\(clean.joined(separator: " ")))")) }
        if let date { parts.append(.text(" \"\(IMAPDate.formatInternalDate(date))\"")) }
        parts.append(.text(" "))
        parts.append(.literal(message))
        let result = try await execute(parts)
        if let code = result.status.code, code.name == "APPENDUID", code.arguments.count >= 2 {
            return code.arguments[1].number.flatMap { UInt32(exactly: $0) }
        }
        return nil
    }

    // MARK: - Ожидание изменений

    /// IDLE до `timeout` секунд или до первого EXISTS/EXPUNGE/FETCH/VANISHED.
    /// Возвращает true, если изменения пришли. Без поддержки IDLE — пауза и NOOP.
    /// Транспорт не должен сам обрывать чтение раньше `timeout`.
    func idle(timeout: TimeInterval) async throws -> Bool {
        await lock()
        defer { unlock() }
        if pendingChanges {
            pendingChanges = false
            return true
        }
        let nanos = UInt64(max(0, min(timeout, 3600)) * 1_000_000_000)
        guard capabilities.contains("IDLE") else {
            try await Task.sleep(nanoseconds: nanos)
            let result = try await execute([.text("NOOP")])
            pendingChanges = false
            return result.untagged.contains(where: Self.isMailboxChange)
        }

        let tag = nextTag()
        try await transport.write(Data("\(tag) IDLE\r\n".utf8))
        var changed = false
        waitContinuation: while true {
            switch try await readResponse() {
            case .continuation:
                break waitContinuation
            case .untagged(let u):
                try handleUntagged(u)
                if Self.isMailboxChange(u) { changed = true }
            case .tagged(let t, let status) where t == tag:
                try checkStatus(status)
                return changed
            case .tagged:
                continue
            }
        }

        idleTag = tag
        idleDoneSent = false
        defer {
            idleTag = nil
            idleDoneSent = false
        }
        if changed { try await sendIdleDone() }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            try? await self?.sendIdleDone()
        }
        defer { timer.cancel() }

        while true {
            switch try await readResponse() {
            case .untagged(let u):
                try handleUntagged(u)
                if Self.isMailboxChange(u) {
                    changed = true
                    try await sendIdleDone()
                }
            case .tagged(let t, let status) where t == tag:
                try checkStatus(status)
                pendingChanges = false
                return changed
            case .tagged, .continuation:
                continue
            }
        }
    }

    /// Прервать текущий IDLE (например, пользователь открыл письмо и нужна команда).
    func stopIdle() async {
        try? await sendIdleDone()
    }

    private func sendIdleDone() async throws {
        guard idleTag != nil, !idleDoneSent else { return }
        idleDoneSent = true
        try await transport.write(Data("DONE\r\n".utf8))
    }

    func noop() async throws {
        await lock()
        defer { unlock() }
        let result = try await execute([.text("NOOP")])
        if result.untagged.contains(where: Self.isMailboxChange) { pendingChanges = true }
    }

    /// LOGOUT без ошибок наружу; закрывает транспорт.
    func logout() async {
        await stopIdle()
        await lock()
        defer { unlock() }
        loggingOut = true
        _ = try? await execute([.text("LOGOUT")])
        transport.close()
        selectedFolder = nil
    }

    // MARK: - Выполнение команд

    private func nextTag() -> String {
        tagCounter += 1
        let n = String(tagCounter)
        return "A" + String(repeating: "0", count: max(0, 4 - n.count)) + n
    }

    private func nonSyncLiteralAllowed(_ size: Int) -> Bool {
        if capabilities.contains("LITERAL+") { return true }
        if capabilities.contains("LITERAL-") { return size <= 4096 }
        return false
    }

    /// Отправляет команду и читает ответы до завершающего с нашим тегом.
    /// `onContinuation` отвечает на «+» (AUTHENTICATE): возвращает строку без CRLF.
    func execute(_ parts: [CommandPart], onContinuation: ((String) -> String)? = nil) async throws -> CommandResult {
        let tag = nextTag()
        var untagged: [IMAPUntagged] = []
        var buffer = Data((tag + " ").utf8)

        for part in parts {
            switch part {
            case .text(let s):
                buffer.append(Data(s.utf8))
            case .literal(let data):
                if nonSyncLiteralAllowed(data.count) {
                    buffer.append(Data("{\(data.count)+}\r\n".utf8))
                    buffer.append(data)
                } else {
                    buffer.append(Data("{\(data.count)}\r\n".utf8))
                    try await transport.write(buffer)
                    buffer = Data()
                    waiting: while true {
                        switch try await readResponse() {
                        case .continuation:
                            break waiting
                        case .untagged(let u):
                            try handleUntagged(u)
                            untagged.append(u)
                        case .tagged(let t, let status) where t == tag:
                            // Сервер отказался принимать литерал.
                            try checkStatus(status)
                            return CommandResult(untagged: untagged, status: status)
                        case .tagged:
                            continue
                        }
                    }
                    buffer.append(data)
                }
            }
        }
        buffer.append(Data("\r\n".utf8))
        try await transport.write(buffer)

        while true {
            switch try await readResponse() {
            case .untagged(let u):
                try handleUntagged(u)
                untagged.append(u)
            case .continuation(let text):
                if let onContinuation {
                    try await transport.write(Data((onContinuation(text) + "\r\n").utf8))
                }
            case .tagged(let t, let status):
                guard t == tag else { continue }
                if let code = status.code { applyCode(code) }
                try checkStatus(status)
                return CommandResult(untagged: untagged, status: status)
            }
        }
    }

    private func checkStatus(_ status: IMAPStatusResponse) throws {
        switch status.status {
        case .ok, .preauth: return
        case .no: throw IMAPError.no(status.text)
        case .bad: throw IMAPError.bad(status.text)
        case .bye: throw IMAPError.unexpected(status.text)
        }
    }

    private func handleUntagged(_ u: IMAPUntagged) throws {
        switch u {
        case .capability(let caps):
            setCapabilities(caps)
        case .status(let s):
            if let code = s.code { applyCode(code) }
            if s.status == .bye && !loggingOut {
                throw IMAPError.unexpected(s.text.isEmpty ? "Сервер закрыл соединение" : s.text)
            }
        case .enabled(let names):
            enabledExtensions.formUnion(names)
        case .exists:
            if !inSelect && idleTag == nil { pendingChanges = true }
        default:
            break
        }
    }

    private func applyCode(_ code: IMAPResponseCode) {
        if code.name == "CAPABILITY" { setCapabilities(code.atoms.map { $0.uppercased() }) }
    }

    private func setCapabilities(_ caps: [String]) {
        capabilities = Set(caps.map { $0.uppercased() })
        capabilityGeneration += 1
    }

    /// Читает один ответ целиком, включая все литералы `{n}` / `~{n}` в конце строк.
    private func readResponse() async throws -> IMAPResponse {
        var text: [UInt8] = []
        var literals: [Data] = []
        while true {
            let line = [UInt8](try await reader.readLine())
            if text.isEmpty && literals.isEmpty && line.allSatisfy({ $0 == 0x20 }) { continue }   // пустые строки
            text.append(contentsOf: line)
            let isContinuation = text.first == UInt8(ascii: "+")
            if !isContinuation, let length = IMAPResponseParser.trailingLiteralLength(line) {
                guard length <= Self.maxLiteralSize else {
                    throw IMAPError.unexpected("Слишком большой литерал: \(length) байт")
                }
                literals.append(length == 0 ? Data() : try await reader.readExactly(length))
                continue
            }
            break
        }
        return IMAPResponseParser.parse(IMAPRawResponse(text: text, literals: literals))
    }

    // MARK: - Очередь команд

    private func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: - Вспомогательное

    static func isMailboxChange(_ u: IMAPUntagged) -> Bool {
        switch u {
        case .exists, .expunge, .fetch, .vanished: return true
        default: return false
        }
    }

    /// Строка-аргумент: в кавычках с экранированием или литерал (не-ASCII, CR/LF, очень длинная).
    static func astring(_ s: String) -> CommandPart {
        let needsLiteral = s.utf8.contains { $0 >= 0x80 || $0 == 0x0D || $0 == 0x0A || $0 == 0 } || s.utf8.count > 1000
        if needsLiteral { return .literal(Data(s.utf8)) }
        return .text(quote(s))
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Имя папки на проводе: INBOX как есть, остальное — modified UTF-7 в кавычках.
    static func mailbox(_ name: String) -> CommandPart {
        if name.uppercased() == "INBOX" { return .text("INBOX") }
        return astring(IMAPUTF7.encode(name))
    }

    /// Разбивает критерии поиска: строки в кавычках с не-ASCII становятся литералами.
    static func searchParts(_ criteria: String) -> ([CommandPart], Bool) {
        var parts: [CommandPart] = []
        var current = ""
        var needsCharset = false
        let chars = Array(criteria)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                var content = ""
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count { j += 1 }
                    content.append(chars[j])
                    j += 1
                }
                if content.utf8.contains(where: { $0 >= 0x80 || $0 == 0x0D || $0 == 0x0A }) {
                    needsCharset = true
                    if !current.isEmpty { parts.append(.text(current)); current = "" }
                    parts.append(.literal(Data(content.utf8)))
                } else {
                    current += quote(content)
                }
                i = j + 1
                continue
            }
            if String(c).utf8.contains(where: { $0 >= 0x80 }) {
                // Не-ASCII вне кавычек — отдельный литерал-атом до пробела.
                needsCharset = true
                var j = i
                var word = ""
                while j < chars.count, chars[j] != " " { word.append(chars[j]); j += 1 }
                if !current.isEmpty { parts.append(.text(current)); current = "" }
                parts.append(.literal(Data(word.utf8)))
                i = j
                continue
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { parts.append(.text(current)) }
        return (parts, needsCharset)
    }

    static func unique(_ uids: [UInt32]) -> [UInt32] {
        var seen = Set<UInt32>()
        return uids.filter { $0 > 0 && seen.insert($0).inserted }
    }

    static func chunks(_ items: [UInt32], size: Int) -> [[UInt32]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// Склеивает несколько FETCH-ответов для одного номера (сервер может прислать их раздельно).
    static func mergedFetches(_ untagged: [IMAPUntagged]) -> [IMAPFetchAttributes] {
        var order: [Int] = []
        var bySeq: [Int: IMAPFetchAttributes] = [:]
        for case .fetch(let seq, let attrs) in untagged {
            if bySeq[seq] == nil { order.append(seq); bySeq[seq] = attrs } else { bySeq[seq]?.merge(attrs) }
        }
        return order.compactMap { bySeq[$0] }
    }

    static func flagUpdates(_ untagged: [IMAPUntagged]) -> [IMAPFlagUpdate] {
        mergedFetches(untagged).compactMap { attrs in
            guard let uid = attrs.uid, let flags = attrs["FLAGS"] else { return nil }
            return IMAPFlagUpdate(uid: uid, flags: IMAPFetchParsing.flags(flags), modSeq: IMAPFetchParsing.modSeq(attrs["MODSEQ"]))
        }
    }
}
