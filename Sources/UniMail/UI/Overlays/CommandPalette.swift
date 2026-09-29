import SwiftUI

/// ⌘K — переход куда угодно и любое действие с клавиатуры (экран 5 макета).
@MainActor
struct CommandPalette: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var highlighted = 0
    @State private var appeared = false
    @FocusState private var fieldFocused: Bool

    private struct Item: Identifiable {
        enum Icon { case symbol(String), account(Account), allBoxes }
        var id: String
        var section: String
        var icon: Icon
        var title: String
        var subtitle: String
        var key: String
        var run: () -> Void
    }

    private var items: [Item] {
        let current = store.selectedThreadID.flatMap { store.thread($0).last }
        let defaultAccount = store.scope.accountID.flatMap { store.account($0) } ?? store.accounts.first
        let snoozedCount = store.messages.values.filter { $0.role == .snoozed }.count

        var result: [Item] = [
            Item(id: "all", section: "Перейти", icon: .allBoxes, title: "Все ящики",
                 subtitle: "Входящие из \(store.accounts.count) \(plural(store.accounts.count, "аккаунта", "аккаунтов", "аккаунтов"))",
                 key: "⌘1") { store.switchToAccount(nil) },
        ]
        for (index, account) in store.accounts.enumerated() {
            result.append(Item(id: "acc-\(account.id)", section: "Перейти", icon: .account(account), title: account.displayName,
                               subtitle: "\(account.email) · \(account.providerTitle)", key: index < 8 ? "⌘\(index + 2)" : "") {
                store.switchToAccount(account.id)
            })
        }
        result.append(Item(id: "snoozed", section: "Перейти", icon: .symbol("clock"), title: "Отложенные",
                            subtitle: "\(snoozedCount) \(plural(snoozedCount, "письмо вернётся", "письма вернутся", "писем вернутся")) позже",
                            key: "⌥⌘2") {
            store.mode = .mail
            store.select(scope: store.scope.with(role: .snoozed))
        })
        result.append(Item(id: "schedule", section: "Перейти", icon: .symbol("calendar"), title: "Расписание",
                            subtitle: "Повестка дня и недели", key: "⇧⌘2") {
            withAnimation(Motion.smooth) { store.mode = .schedule }
        })
        result.append(Item(id: "compose", section: "Действия", icon: .symbol("square.and.pencil"), title: "Новое письмо",
                            subtitle: defaultAccount.map { "От: \($0.displayName) · \($0.email)" } ?? "", key: "⌘N") {
            store.compose()
        })
        result.append(Item(id: "archive", section: "Действия", icon: .symbol("archivebox"), title: "Архивировать тред",
                            subtitle: current.map { "«\($0.subject)»" } ?? "Нет выбранного письма", key: "E") {
            if let id = store.selectedThreadID { store.archive(threadIDs: [id]) }
        })
        result.append(Item(id: "snooze", section: "Действия", icon: .symbol("moon.zzz"), title: "Отложить…",
                            subtitle: "\(TimePreset.tomorrowMorning.title), \(TimePreset.tomorrowMorning.subtitle)", key: "H") {
            store.snoozeMenuRequest += 1
        })
        result.append(Item(id: "reply", section: "Действия", icon: .symbol("arrowshape.turn.up.left"), title: "Ответить",
                            subtitle: current?.from.display ?? "—", key: "R") {
            store.quickReplyRequest += 1
        })
        result.append(Item(id: "refresh", section: "Действия", icon: .symbol("arrow.clockwise"), title: "Проверить почту",
                            subtitle: "Все ящики", key: "⇧⌘N") {
            Task { await store.refreshAll() }
        })
        result.append(Item(id: "theme", section: "Действия", icon: .symbol("moon"), title: "Сменить тему",
                            subtitle: "Светлая · Тёмная · Как в системе", key: "⌥⇧⌘L") {
            AppearanceMode.cycle()
        })
        result.append(Item(id: "settings", section: "Действия", icon: .symbol("gearshape"), title: "Настройки",
                            subtitle: "Аккаунты, внешний вид, поведение", key: "⌘,") {
            openSettings()
        })

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return result }
        var filtered = result.filter { ($0.title + " " + $0.subtitle).lowercased().contains(q) }

        // Письма, подходящие под запрос.
        let hits = store.threads(in: .unified(.inbox)).filter {
            ($0.latest.subject + " " + $0.latest.from.display).lowercased().contains(q)
        }
        for thread in hits.prefix(6) {
            filtered.append(Item(id: "msg-\(thread.id)", section: "Письма", icon: .symbol("envelope"),
                                 title: thread.latest.subject, subtitle: thread.latest.from.display, key: "↩") {
                store.mode = .mail
                store.switchToAccount(nil)
                store.selectedThreadID = thread.id
                store.openThread(thread.id)
            })
        }
        return filtered
    }

    var body: some View {
        let list = items

        ZStack(alignment: .top) {
            UM.scrim
                .opacity(appeared ? 1 : 0)
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundStyle(UM.fg3)
                    TextField("", text: $query, prompt: Text("Куда перейти или что сделать?").foregroundColor(UM.fg3))
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($fieldFocused)
                        .onSubmit { run(list) }
                        .onKeyPress(.downArrow) {
                            highlighted = min(highlighted + 1, max(list.count - 1, 0))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            highlighted = max(highlighted - 1, 0)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            close()
                            return .handled
                        }
                    KeyHint(text: "esc")
                }
                .padding(.horizontal, 18)
                .frame(height: 54)
                .hairline(.bottom, color: UM.sepStrong)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || list[index - 1].section != item.section {
                                    Text(item.section)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(UM.fg3)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 8)
                                        .padding(.bottom, 4)
                                }
                                row(item, on: index == highlighted)
                                    .id(index)
                                    .onTapGesture {
                                        highlighted = index
                                        run(list)
                                    }
                                    .onHover { if $0 { highlighted = index } }
                            }
                            if list.isEmpty {
                                Text("Ничего не нашлось")
                                    .font(.system(size: 13))
                                    .foregroundStyle(UM.fg3)
                                    .frame(maxWidth: .infinity)
                                    .padding(20)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }

                HStack(spacing: 16) {
                    Text("↑↓ выбрать")
                    Text("↩ выполнить")
                    Text("⌘1…9 ящики")
                    Spacer()
                }
                .font(.system(size: 11))
                .foregroundStyle(UM.fg3)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .hairline(.top, color: UM.sepStrong)
            }
            .frame(width: 600)
            .umMenuSurface(radius: 16)
            .padding(.top, 118)
            .scaleEffect(appeared || Motion.reduce ? 1 : 0.94, anchor: .top)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            fieldFocused = true
            withAnimation(Motion.paletteIn) { appeared = true }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(_ item: Item, on: Bool) -> some View {
        HStack(spacing: 12) {
            icon(item.icon, on: on)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .opacity(on ? 0.85 : 0.55)
            }
            Spacer(minLength: 8)
            if !item.key.isEmpty {
                KeyHint(text: item.key, inverted: on)
            }
        }
        .foregroundStyle(on ? Color.white : UM.fg)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? UM.accent : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func icon(_ icon: Item.Icon, on: Bool) -> some View {
        switch icon {
        case .allBoxes:
            AllBoxesTile(size: 28, radius: 8, symbolSize: 14)
        case .account(let account):
            AccountTile(account: account, size: 28, radius: 8, fontSize: 12)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(on ? Color.white : UM.fg2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.white.opacity(0.2) : UM.seg))
        }
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(highlighted) else { return }
        let item = list[highlighted]
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { item.run() }
    }

    private func close() {
        withAnimation(Motion.paletteOut) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduce ? 0.1 : 0.16)) {
            store.isPalettePresented = false
        }
    }
}
