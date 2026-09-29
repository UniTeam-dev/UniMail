import Foundation

// Проверка сети тем же кодом, что в приложении (StreamTransport + IMAPClient + SMTPClient), без паролей:
// соединение, TLS, приветствие, CAPABILITY/EHLO и вход с заведомо неверным паролем (ждём отказ, а не зависание).

struct Target { var host: String; var port: Int; var tls: Bool; var imap: Bool }

let targets = [
    Target(host: "imap.yandex.ru", port: 993, tls: true, imap: true),
    Target(host: "imap.gmail.com", port: 993, tls: true, imap: true),
    Target(host: "imap.yandex.ru", port: 143, tls: false, imap: true),
    Target(host: "smtp.yandex.ru", port: 465, tls: true, imap: false),
    Target(host: "smtp.gmail.com", port: 465, tls: true, imap: false),
    Target(host: "smtp.gmail.com", port: 587, tls: false, imap: false),
]

for target in targets {
    let start = Date()
    let place = "\(target.imap ? "IMAP" : "SMTP") \(target.host):\(target.port) \(target.tls ? "TLS" : "STARTTLS")"
    func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(start)) }
    do {
        let transport = try await StreamTransport.factory(target.host, target.port, target.tls, 15)
        if target.imap {
            let client = IMAPClient(transport: transport)
            try await client.connect()
            if !target.tls { try await client.startTLS() }
            let caps = try await client.refreshCapabilities()
            print("OK   \(place) [\(elapsed())] \(caps.sorted().joined(separator: " "))")
            do {
                try await client.login(username: "unimail.netcheck@\(target.host.contains("gmail") ? "gmail.com" : "yandex.ru")", password: "wrong-password")
                print("     вход с неверным паролем неожиданно прошёл")
            } catch {
                print("     вход с неверным паролем → \(error) [\(elapsed())]")
            }
            await client.logout()
        } else {
            let smtp = SMTPClient(transport: transport)
            try await smtp.connect()
            var caps = try await smtp.ehlo()
            if !target.tls {
                try await smtp.startTLS()
                caps = try await smtp.ehlo()
            }
            print("OK   \(place) [\(elapsed())] \(caps.sorted().joined(separator: " "))")
            await smtp.quit()
        }
    } catch {
        print("FAIL \(place) [\(elapsed())] \(error) — \(error.localizedDescription)")
    }
}
