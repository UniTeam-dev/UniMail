import Foundation

/// Автоматическая раскладка входящих по категориям «Люди / Уведомления / Рассылки».
///
/// Детерминированная эвристика без сети и без ML. Шаги проверяются строго по порядку,
/// побеждает первый сработавший:
///
/// 1. **Ручные поправки** (`CategoryOverride`): сначала точный адрес (`a@b.ru`),
///    затем домен целиком (`@mail.b.ru`), затем родительские домены (`@b.ru`), но не короче двух меток.
/// 2. **Коды и безопасность** → уведомления: `Message.oneTimeCode`, фразы в теме
///    («код подтверждения», «verification code», «сброс пароля», OTP/2FA…) или «код/code» + 5–8 цифр в теме.
/// 3. **`Auto-Submitted`** с любым значением, кроме `no` (RFC 3834) → уведомления.
/// 4. **Известные сервисы** (GitHub, GitLab, Atlassian/Jira, Госуслуги, ФНС, банки, билеты…) → уведомления.
///    Стоит раньше рассылок, потому что GitHub/Jira ставят `List-Id` и `List-Unsubscribe`.
/// 5. **Рассылки**: `List-Unsubscribe` (заголовок или `Message.listUnsubscribe`), `List-Id`,
///    `Precedence: bulk | list | junk`, заголовки ESP (`X-Campaign*`, `X-Mailchimp*`, `X-MC-User`),
///    типичные адреса (`news@`, `newsletter@`, `digest@`, `promo@`…) и домены сервисов рассылок.
/// 6. **Роботы** → уведомления: `noreply`, `no-reply`, `donotreply`, `mailer-daemon`, `postmaster`,
///    `notifications@`, `notify@`, `alerts@`, `robot@`, `bot@`, `info@`… (по токенам локальной части),
///    либо «no-reply» в имени отправителя.
/// 7. Иначе — **люди**.
///
/// Заголовки сравниваются без учёта регистра имён; значения — без учёта регистра.
enum Categorizer {
    static func category(for message: Message, headers: [String: String], overrides: [CategoryOverride]) -> InboxCategory {
        let email = normalize(message.from.email)
        let domain = self.domain(of: email) ?? ""
        let local = localPart(of: email)

        // 1. Ручные поправки.
        if let manual = overrideCategory(for: email, overrides: overrides) { return manual }

        let h = normalizedHeaders(headers)

        // 2. Коды подтверждения и письма безопасности.
        if message.oneTimeCode != nil || isSecuritySubject(message.subject) { return .notifications }

        // 3. Auto-Submitted: auto-generated / auto-replied / auto-notified.
        if let auto = h["auto-submitted"], !auto.isEmpty, auto != "no" { return .notifications }

        // 4. Известные сервисы.
        if isKnownService(domain: domain) { return .notifications }

        // 5. Рассылки.
        if isNewsletter(headers: h, message: message, local: local, domain: domain) { return .newsletters }

        // 6. Автоматические отправители.
        if isAutomatedSender(local: local, name: message.from.name) { return .notifications }

        return .people
    }

    // MARK: - Поправки

    /// Категория из ручных поправок: точный адрес, затем домен и его родители (не короче двух меток).
    static func overrideCategory(for email: String, overrides: [CategoryOverride]) -> InboxCategory? {
        guard !overrides.isEmpty else { return nil }
        var table: [String: InboxCategory] = [:]
        // Последняя запись с тем же ключом побеждает.
        for o in overrides { table[normalize(o.key)] = o.category }
        let email = normalize(email)
        if let exact = table[email] { return exact }
        guard let domain = domain(of: email) else { return nil }
        if let hit = table["@" + domain] { return hit }
        var labels = domain.split(separator: ".").map(String.init)
        while labels.count > 2 {
            labels.removeFirst()
            if let hit = table["@" + labels.joined(separator: ".")] { return hit }
        }
        return nil
    }

    // MARK: - Разбор адреса

    /// Адрес в нижнем регистре, без пробелов и угловых скобок.
    static func normalize(_ address: String) -> String {
        address.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n<>\"'"))
            .lowercased()
    }

    /// Домен адреса (`b.ru` для `a@b.ru`), или nil, если «@» нет.
    static func domain(of email: String) -> String? {
        let e = normalize(email)
        guard let at = e.lastIndex(of: "@") else { return nil }
        let d = String(e[e.index(after: at)...]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return d.isEmpty ? nil : d
    }

    static func localPart(of email: String) -> String {
        let e = normalize(email)
        guard let at = e.lastIndex(of: "@") else { return e }
        return String(e[..<at])
    }

    /// Бесплатные почтовые домены: для них правило «два адреса → весь домен» не применяется,
    /// иначе две поправки для знакомых на gmail.com отправили бы в рассылки весь Gmail.
    static let publicMailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yandex.ru", "yandex.com", "yandex.by", "yandex.kz", "ya.ru",
        "mail.ru", "bk.ru", "inbox.ru", "list.ru", "internet.ru", "rambler.ru", "lenta.ru", "ro.ru",
        "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.de", "gmx.net",
        "fastmail.com", "zoho.com", "tutanota.com", "tuta.io", "qip.ru", "ukr.net",
    ]

    static func isPublicMailDomain(_ domain: String) -> Bool {
        publicMailDomains.contains(normalize(domain))
    }

    // MARK: - Сигналы

    private static func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            result[key.trimmingCharacters(in: .whitespaces).lowercased()] =
                value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return result
    }

    private static let securityPhrases: [String] = [
        "код подтверждения", "код для входа", "код входа", "одноразовый код", "одноразовый пароль",
        "проверочный код", "код доступа", "сброс пароля", "восстановление пароля", "смена пароля",
        "подтвердите адрес", "подтверждение адреса", "подтверждение почты", "новый вход", "вход в аккаунт",
        "verification code", "security code", "login code", "sign-in code", "sign in code",
        "one-time code", "one-time password", "confirmation code", "access code", "authentication code",
        "reset your password", "password reset", "confirm your email", "verify your email",
        "new sign-in", "new login", "security alert",
    ]

    private static let otpToken = try! NSRegularExpression(pattern: #"\b(otp|2fa|mfa)\b"#, options: [.caseInsensitive])
    private static let codeDigits = try! NSRegularExpression(pattern: #"(?<!\d)(\d{5,8}|\d{3}[ -]\d{3})(?!\d)"#)

    static func isSecuritySubject(_ subject: String) -> Bool {
        let s = subject.lowercased()
        if securityPhrases.contains(where: { s.contains($0) }) { return true }
        let range = NSRange(s.startIndex..., in: s)
        if otpToken.firstMatch(in: s, range: range) != nil { return true }
        if (s.contains("код") || s.contains("code")), codeDigits.firstMatch(in: s, range: range) != nil { return true }
        return false
    }

    /// Сервисы, которые шлют в основном уведомления (совпадение домена или его суффикса).
    static let knownServiceDomains: [String] = [
        // Разработка
        "github.com", "gitlab.com", "atlassian.net", "atlassian.com", "jira.com", "bitbucket.org",
        "trello.com", "sentry.io", "circleci.com", "travis-ci.com", "vercel.com", "netlify.com",
        // Аккаунты
        "accounts.google.com", "appleid.apple.com", "id.apple.com", "accountprotection.microsoft.com",
        "passport.yandex.ru", "id.yandex.ru", "id.vk.com",
        // Госсервисы
        "gosuslugi.ru", "nalog.ru", "nalog.gov.ru", "mos.ru", "sfr.gov.ru", "pfr.gov.ru",
        // Банки
        "sberbank.ru", "sberbank.com", "sber.ru", "tinkoff.ru", "tbank.ru", "alfabank.ru", "vtb.ru",
        "raiffeisen.ru", "gazprombank.ru", "open.ru", "psbank.ru", "rshb.ru", "sovcombank.ru",
        // Билеты и поездки
        "rzd.ru", "aeroflot.ru", "s7.ru", "pobeda.aero", "utair.ru", "tutu.ru", "kassir.ru", "ticketland.ru",
    ]

    /// Метки домена, выдающие self-hosted трекеры и CI: jira.company.ru, gitlab.corp.
    private static let serviceLabels: Set<String> = ["jira", "gitlab", "jenkins", "youtrack", "sentry", "confluence", "teamcity"]

    static func isKnownService(domain: String) -> Bool {
        guard !domain.isEmpty else { return false }
        if knownServiceDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) { return true }
        return domain.split(separator: ".").contains { serviceLabels.contains(String($0)) }
    }

    private static let newsletterTokens: Set<String> = [
        "news", "newsletter", "newsletters", "digest", "marketing", "promo", "promotions", "offers",
        "deals", "sale", "mailing", "rassylka", "subscription", "subscriptions", "campaign", "weekly",
    ]

    private static let newsletterDomains: [String] = [
        "mailchimp.com", "mcsv.net", "mcdlv.net", "list-manage.com", "sendpulse.com", "unisender.com",
        "sendsay.ru", "mindbox.ru", "esputnik.com", "substack.com", "beehiiv.com", "mailerlite.com",
        "getresponse.com", "dashamail.ru",
    ]

    private static let newsletterSubdomains: Set<String> = ["news", "newsletter", "newsletters", "promo", "marketing", "digest"]

    private static func isNewsletter(headers h: [String: String], message: Message, local: String, domain: String) -> Bool {
        if h["list-unsubscribe"] != nil || h["list-id"] != nil { return true }
        if let unsubscribe = message.listUnsubscribe, !unsubscribe.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if let precedence = h["precedence"], ["bulk", "list", "junk"].contains(precedence) { return true }
        if h.keys.contains(where: { $0.hasPrefix("x-campaign") || $0.hasPrefix("x-mailchimp") || $0 == "x-mc-user" }) { return true }
        let tokens = tokenize(local)
        if tokens.contains(where: newsletterTokens.contains) || newsletterTokens.contains(local) { return true }
        if newsletterDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) { return true }
        if let first = domain.split(separator: ".").first, domain.split(separator: ".").count > 2,
           newsletterSubdomains.contains(String(first)) { return true }
        return false
    }

    /// Подстроки, которые выдают робота где угодно в локальной части: github-noreply, noreply-dmarc.
    private static let automatedSubstrings: [String] = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply", "mailer-daemon", "postmaster",
    ]

    /// Токены локальной части (разделители . - _ +).
    private static let automatedTokens: Set<String> = [
        "notifications", "notification", "notify", "notifier", "alerts", "alert", "robot", "bot", "info",
        "auto", "automailer", "mailer", "daemon", "system", "bounce", "bounces", "reminder", "reminders",
        "noreply", "robots",
    ]

    static func isAutomatedSender(local: String, name: String?) -> Bool {
        if automatedSubstrings.contains(where: { local.contains($0) }) { return true }
        if tokenize(local).contains(where: automatedTokens.contains) { return true }
        if let name = name?.lowercased(), ["no-reply", "noreply", "do not reply", "не отвечайте"].contains(where: { name.contains($0) }) {
            return true
        }
        return false
    }

    private static func tokenize(_ local: String) -> [String] {
        local.split(whereSeparator: { ".-_+".contains($0) }).map(String.init)
    }
}
