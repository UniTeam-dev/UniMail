import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Экспорт треда: PDF (с разбивкой на страницы A4), печать и сохранение .eml.
///
/// PDF и печать строятся из одного «печатного» HTML треда, который рендерит невидимый WKWebView
/// без JavaScript. Удалённые картинки загружаются, только если в настройках выбрано «Загружать всегда».
@MainActor
final class ExportService {
    static let shared = ExportService()

    enum ExportError: LocalizedError {
        case emptyThread
        case renderFailed(String)
        case pdfFailed
        case printFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyThread: "В треде нет писем для экспорта."
            case .renderFailed(let text): "Не удалось подготовить письмо: \(text)"
            case .pdfFailed: "Не удалось создать PDF."
            case .printFailed: "Не удалось напечатать письмо."
            case .writeFailed(let text): "Не удалось сохранить файл: \(text)"
            }
        }
    }

    private init() {}

    // MARK: Простые вызовы для меню (ошибки показываются в NSAlert)

    /// «Экспортировать в PDF…» из меню «Ещё».
    func exportThreadToPDF(threadID: String, store: MailStore) {
        let messages = store.thread(threadID)
        Task {
            do { _ = try await exportPDF(messages, store: store) } catch { Self.presentError(error) }
        }
    }

    /// «Напечатать…» (⌘P).
    func printThread(threadID: String, store: MailStore) {
        let messages = store.thread(threadID)
        Task {
            do { try await printMessages(messages, store: store) } catch { Self.presentError(error) }
        }
    }

    /// «Сохранить как .eml…» для последнего письма треда (или конкретного письма).
    func saveThreadMessageAsEML(threadID: String, messageID: String? = nil, store: MailStore) {
        let messages = store.thread(threadID)
        guard let message = messageID.flatMap({ id in messages.first { $0.id == id } }) ?? messages.last else {
            Self.presentError(ExportError.emptyThread)
            return
        }
        // Настоящий ящик — исходник с сервера байт в байт; иначе собираем из модели.
        let fallback = EMLBuilder.build(message)
        let messageID = message.id
        Task { @MainActor in
            do {
                _ = try await saveEML(suggestedName: message.subject) {
                    await store.rawSource(of: messageID) ?? fallback
                }
            } catch {
                Self.presentError(error)
            }
        }
    }

    static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Не получилось"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "ОК")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    // MARK: PDF

    /// Спрашивает, куда сохранить, и пишет PDF. Возвращает `nil`, если пользователь отменил.
    @discardableResult
    func exportPDF(_ messages: [Message], store: MailStore? = nil) async throws -> URL? {
        guard let first = messages.first else { throw ExportError.emptyThread }

        let panel = NSSavePanel()
        panel.title = "Экспорт в PDF"
        panel.prompt = "Сохранить"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: messages.last?.subject ?? first.subject, ext: "pdf")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let page = OffscreenPage()
        // Страница должна жить, пока идёт асинхронная печать.
        defer { withExtendedLifetime(page) {} }
        let html = threadHTML(messages, accountName: { id in store?.account(id)?.displayName })
        try await page.load(html, allowRemote: Self.allowRemoteImages)

        // 1) Настоящая разбивка на страницы через печать в файл.
        let info = Self.printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        let operation = page.webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = first.subject
        operation.view?.frame = page.webView.bounds
        try? FileManager.default.removeItem(at: url)
        let host = NSApp.keyWindow ?? NSApp.mainWindow ?? page.window
        let printed = await Self.run(operation, on: host, timeout: .seconds(90))
        if printed, FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        // 2) Запасной путь: одна длинная страница через createPDF.
        do {
            let data = try await page.createPDF()
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ExportError.pdfFailed
        }
    }

    // MARK: Печать

    func printMessages(_ messages: [Message], store: MailStore? = nil) async throws {
        guard let first = messages.first else { throw ExportError.emptyThread }
        let page = OffscreenPage()
        defer { withExtendedLifetime(page) {} }
        let html = threadHTML(messages, accountName: { id in store?.account(id)?.displayName })
        try await page.load(html, allowRemote: Self.allowRemoteImages)

        let operation = page.webView.printOperation(with: Self.printInfo())
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = first.subject
        operation.view?.frame = page.webView.bounds

        if NSApp.keyWindow == nil && NSApp.mainWindow == nil {
            WindowRouter.shared.showMain()
        }
        let host = NSApp.keyWindow ?? NSApp.mainWindow ?? WindowRouter.shared.mainWindow ?? page.window
        // Отмена в диалоге печати — не ошибка.
        _ = await Self.run(operation, on: host)
    }

    // MARK: .eml

    /// Сохраняет готовые байты письма (RFC 5322) через NSSavePanel.
    @discardableResult
    func saveEML(data: Data, suggestedName: String) throws -> URL? {
        guard let url = askEMLDestination(suggestedName) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Сначала спрашивает путь, затем строит байты (например, скачивает исходник с IMAP-сервера).
    @discardableResult
    func saveEML(suggestedName: String, builder: () async throws -> Data) async throws -> URL? {
        guard let url = askEMLDestination(suggestedName) else { return nil }
        let data = try await builder()
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// Письмо без исходника: собираем .eml из полей модели (`EMLBuilder`).
    @discardableResult
    func saveEML(_ message: Message) throws -> URL? {
        try saveEML(data: EMLBuilder.build(message), suggestedName: message.subject)
    }

    private func askEMLDestination(_ suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Сохранить письмо"
        panel.prompt = "Сохранить"
        panel.allowedContentTypes = [UTType(filenameExtension: "eml") ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.fileName(for: suggestedName, ext: "eml")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: Помощники

    private static var allowRemoteImages: Bool {
        UserDefaults.standard.integer(forKey: "remoteImages") == 2
    }

    private static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89) // A4
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    static func fileName(for subject: String, ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        var name = subject.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Письмо" }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return "\(name).\(ext)"
    }

    /// Запускает печать в модальном режиме (WKWebView печатает только так) и ждёт завершения.
    /// `timeout` — для печати в файл без диалогов: если AppKit не ответил, считаем, что не вышло.
    private static func run(_ operation: NSPrintOperation, on window: NSWindow, timeout: Duration? = nil) async -> Bool {
        var runner: PrintRunner?
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let current = PrintRunner(continuation)
            runner = current
            if let timeout {
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    current.finish(false)
                }
            }
            operation.runModal(
                for: window,
                delegate: current,
                didRun: #selector(PrintRunner.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
        withExtendedLifetime(runner) {}
        return success
    }

    // MARK: Печатный HTML

    /// Чистый HTML треда для печати: тема, по каждому письму — отправитель, получатели, дата, текст, вложения.
    func threadHTML(_ messages: [Message], accountName: (UUID) -> String?) -> String {
        let subject = messages.last?.subject ?? messages.first?.subject ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .long
        formatter.timeStyle = .short

        var seen = Set<UUID>()
        let boxes = messages.map(\.accountID).filter { seen.insert($0).inserted }.compactMap(accountName)
        var meta = "\(messages.count) \(plural(messages.count, "письмо", "письма", "писем"))"
        if !boxes.isEmpty { meta += " · " + boxes.joined(separator: ", ") }

        var articles = ""
        for message in messages {
            var rows = "<div class=\"row\"><span class=\"k\">От</span><span>\(Self.addressHTML(message.from))</span></div>"
            if !message.to.isEmpty {
                rows += "<div class=\"row\"><span class=\"k\">Кому</span><span>\(message.to.map(Self.addressHTML).joined(separator: ", "))</span></div>"
            }
            if !message.cc.isEmpty {
                rows += "<div class=\"row\"><span class=\"k\">Копия</span><span>\(message.cc.map(Self.addressHTML).joined(separator: ", "))</span></div>"
            }
            rows += "<div class=\"row\"><span class=\"k\">Дата</span><span>\(Self.escape(formatter.string(from: message.date)))</span></div>"

            let body: String
            if let html = message.htmlBody, !html.isEmpty {
                body = "<div class=\"html\">\(Self.printableFragment(html))</div>"
            } else {
                body = "<div class=\"plain\">\(Self.escape(message.body))</div>"
            }

            var attachments = ""
            if !message.attachments.isEmpty {
                let list = message.attachments
                    .map { "<li>\(Self.escape($0.filename)) <span class=\"size\">\(Self.escape($0.sizeText))</span></li>" }
                    .joined()
                attachments = "<div class=\"att\"><div class=\"k\">Вложения</div><ul>\(list)</ul></div>"
            }

            articles += "<article><header>\(rows)</header>\(body)\(attachments)</article>"
        }

        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; \(Self.allowRemoteImages ? "" : "img-src data: cid:;")">
        <title>\(Self.escape(subject))</title>
        <style>
          html, body { margin: 0; padding: 0; background: #FFFFFF; }
          body { font: 11pt/1.5 -apple-system, "Helvetica Neue", sans-serif; color: #1C1C1F; word-wrap: break-word; overflow-wrap: anywhere; }
          h1 { font-size: 18pt; line-height: 1.25; margin: 0 0 4pt; letter-spacing: -0.2pt; }
          .meta { color: #8E8E98; font-size: 9.5pt; margin-bottom: 14pt; }
          article { border-top: 0.5pt solid #D0D0D6; padding: 12pt 0 14pt; }
          article:first-of-type { border-top-color: #1C1C1F; }
          header { margin-bottom: 10pt; font-size: 9.5pt; }
          .row { display: flex; gap: 8pt; margin: 1pt 0; }
          .k { color: #8E8E98; min-width: 42pt; }
          .plain { white-space: pre-wrap; }
          .html img { max-width: 100%; height: auto; }
          .html table { max-width: 100% !important; }
          a { color: #3D6AF2; text-decoration: none; }
          blockquote { border-left: 2pt solid #D0D0D6; margin: 0; padding-left: 10pt; color: #6E6E73; }
          .att { margin-top: 10pt; font-size: 9.5pt; }
          .att ul { margin: 2pt 0 0; padding-left: 16pt; }
          .size { color: #8E8E98; }
          .footer { color: #8E8E98; font-size: 8pt; margin-top: 8pt; }
        </style>
        </head><body>
        <h1>\(Self.escape(subject.isEmpty ? "(без темы)" : subject))</h1>
        <div class="meta">\(Self.escape(meta))</div>
        \(articles)
        <div class="footer">Экспортировано из UniMail</div>
        </body></html>
        """
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(ch)
            }
        }
        return result
    }

    private static func addressHTML(_ address: Address) -> String {
        if let name = address.name, !name.isEmpty {
            return "<b>\(escape(name))</b> &lt;\(escape(address.email))&gt;"
        }
        return escape(address.email)
    }

    /// Фрагмент HTML письма без скриптов, стилей документа, head/body и трекинг-пикселей.
    static func printableFragment(_ html: String) -> String {
        var text = html
        let patterns: [(String, String)] = [
            (#"(?is)<script\b.*?</script>"#, ""),
            (#"(?is)<style\b.*?</style>"#, ""),
            (#"(?is)<head\b.*?</head>"#, ""),
            (#"(?is)<title\b.*?</title>"#, ""),
            (#"(?is)<iframe\b.*?</iframe>"#, ""),
            (#"(?is)<(object|embed|form)\b.*?</\1>"#, ""),
            (#"(?i)</?(html|body|meta|link|base)\b[^>]*>"#, ""),
            (#"(?i)<!doctype[^>]*>"#, ""),
            (#"(?i)\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, ""),
            (#"(?i)javascript:"#, ""),
            (#"(?is)<img\b[^>]*\b(width|height)\s*=\s*["']?[01](px)?["']?[^>]*>"#, ""),
        ]
        for (pattern, template) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
            )
        }
        return text
    }
}

// MARK: - Невидимая страница

/// WKWebView в невидимом окне за пределами экрана: так WebKit надёжно раскладывает и печатает страницу.
@MainActor
private final class OffscreenPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    private var continuation: CheckedContinuation<Void, Error>?

    override init() {
        let frame = NSRect(x: 0, y: 0, width: 523, height: 770)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: frame, configuration: config)
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: frame.width, height: frame.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func load(_ html: String, allowRemote: Bool) async throws {
        if !allowRemote, let rules = await RemoteContentRules.shared() {
            webView.configuration.userContentController.add(rules)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func createPDF() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: ExportService.ExportError.renderFailed(error.localizedDescription))
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let scheme = action.request.url?.scheme ?? "about"
        return scheme == "about" || scheme == "data" ? .allow : .cancel
    }
}

/// Приёмник колбэка `runModal(for:delegate:didRun:contextInfo:)`. Продолжение возобновляется ровно один раз.
@MainActor
private final class PrintRunner: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?
    /// AppKit не удерживает делегата печати: держим сами, пока не придёт колбэк (даже после тайм-аута).
    private static var alive: Set<PrintRunner> = []

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
        super.init()
        Self.alive.insert(self)
    }

    func finish(_ success: Bool) {
        continuation?.resume(returning: success)
        continuation = nil
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finish(success)
        Self.alive.remove(self)
    }
}

// MARK: - .eml

/// Сборка письма в формате RFC 5322 / MIME из модели `Message` (когда исходника с сервера нет).
enum EMLBuilder {
    static func build(_ message: Message) -> Data {
        let crlf = "\r\n"
        var headers: [String] = []
        headers.append("From: \(encodeAddress(message.from))")
        if !message.to.isEmpty { headers.append("To: \(message.to.map(encodeAddress).joined(separator: ", "))") }
        if !message.cc.isEmpty { headers.append("Cc: \(message.cc.map(encodeAddress).joined(separator: ", "))") }
        headers.append("Subject: \(encodeHeader(message.subject))")
        headers.append("Date: \(rfc2822(message.date))")
        let messageID = message.headerMessageID ?? "<\(message.id.filter { $0.isLetter || $0.isNumber || $0 == "-" })@unimail.local>"
        headers.append("Message-ID: \(messageID)")
        if let inReplyTo = message.inReplyToHeader { headers.append("In-Reply-To: \(inReplyTo)") }
        if let references = message.references, !references.isEmpty {
            headers.append("References: \(references.joined(separator: " "))")
        }
        headers.append("MIME-Version: 1.0")

        let textPart = part(contentType: "text/plain; charset=utf-8", data: Data(message.body.utf8))
        let content: (type: String, body: String)
        if let html = message.htmlBody, !html.isEmpty {
            let boundary = "alt-\(UUID().uuidString)"
            let htmlPart = part(contentType: "text/html; charset=utf-8", data: Data(html.utf8))
            let body = "--\(boundary)\(crlf)\(textPart)\(crlf)--\(boundary)\(crlf)\(htmlPart)\(crlf)--\(boundary)--\(crlf)"
            content = ("multipart/alternative; boundary=\"\(boundary)\"", body)
        } else {
            content = ("text/plain; charset=utf-8", "")
        }

        let files = message.attachments.compactMap { attachment -> (Attachment, Data)? in
            guard let path = attachment.localPath,
                  let data = FileManager.default.contents(atPath: path) else { return nil }
            return (attachment, data)
        }

        var result = headers.joined(separator: crlf) + crlf
        if files.isEmpty {
            if content.body.isEmpty {
                result += textPart
            } else {
                result += "Content-Type: \(content.type)\(crlf)\(crlf)\(content.body)"
            }
        } else {
            let boundary = "mixed-\(UUID().uuidString)"
            result += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\(crlf)\(crlf)"
            result += "--\(boundary)\(crlf)"
            result += content.body.isEmpty ? textPart : "Content-Type: \(content.type)\(crlf)\(crlf)\(content.body)"
            result += crlf
            for (attachment, data) in files {
                let name = attachment.filename
                let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
                result += "--\(boundary)\(crlf)"
                result += "Content-Type: \(attachment.mimeType); name=\"\(encodeHeader(name))\"\(crlf)"
                result += "Content-Disposition: attachment; filename*=UTF-8''\(encodedName)\(crlf)"
                result += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
                result += base64Lines(data) + crlf
            }
            result += "--\(boundary)--\(crlf)"
        }
        return Data(result.utf8)
    }

    /// MIME-часть: заголовки + пустая строка + base64 по 76 символов.
    private static func part(contentType: String, data: Data) -> String {
        "Content-Type: \(contentType)\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64Lines(data))\r\n"
    }

    private static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    private static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    private static func encodeAddress(_ address: Address) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        if name.unicodeScalars.allSatisfy(\.isASCII) {
            let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(quoted)\" <\(address.email)>"
        }
        return "\(encodeHeader(name)) <\(address.email)>"
    }

    /// RFC 2047: не-ASCII текст → `=?UTF-8?B?…?=`, куски не длиннее 75 символов.
    static func encodeHeader(_ text: String) -> String {
        guard !text.unicodeScalars.allSatisfy({ $0.isASCII && $0 != "\r" && $0 != "\n" }) else { return text }
        var words: [String] = []
        var chunk = ""
        for ch in text {
            if chunk.utf8.count + String(ch).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words
            .map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }
            .joined(separator: "\r\n ")
    }
}
