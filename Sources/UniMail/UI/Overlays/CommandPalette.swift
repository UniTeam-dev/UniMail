import SwiftUI

/// ⌘K — переход куда угодно и любое действие с клавиатуры.
@MainActor
struct CommandPalette: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var highlighted = 0
    @State private var appeared = false
    @FocusState private var fieldFocused: Bool

    private struct Item: Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var symbol: String
        var tint: Color = .secondary
        var shortcut: String?
        var run: () -> Void
    }

    private var items: [Item] {
        var result: [Item] = []

        result.append(Item(id: "compose", title: "Новое письмо", symbol: "square.and.pencil", shortcut: "⌘N") {
            store.compose()
        })
        result.append(Item(id: "unified", title: "Все ящики", subtitle: "Единые входящие", symbol: "tray.2", shortcut: "⌘0") {
            store.switchTo(index: 0)
        })
        for (index, account) in store.accounts.enumerated() {
            result.append(Item(id: "acc-\(account.id)", title: account.displayName, subtitle: account.email,
                               symbol: "person.crop.circle", tint: account.tint.color,
                               shortcut: index < 9 ? "⌘\(index + 1)" : nil) {
                store.switchTo(index: index + 1)
            })
        }
        for role in MailboxRole.allCases {
            result.append(Item(id: "role-\(role.rawValue)", title: "Перейти: \(role.title)", symbol: role.symbol) {
                store.select(scope: store.scope.with(role: role))
            })
        }
        result.append(Item(id: "refresh", title: "Проверить почту", symbol: "arrow.clockwise", shortcut: "⇧⌘N") {
            Task { await store.refreshAll() }
        })
        if let selected = store.selectedThreadID {
            result.append(Item(id: "archive", title: "Архивировать открытое", symbol: "archivebox", shortcut: "E") {
                store.archive(threadIDs: [selected])
            })
            result.append(Item(id: "snooze", title: "Отложить до утра", symbol: "clock", shortcut: "H") {
                store.snooze(threadIDs: [selected], until: TimePreset.tomorrowMorning.date)
            })
            result.append(Item(id: "reply", title: "Ответить", symbol: "arrowshape.turn.up.left", shortcut: "⌘R") {
                store.replyToSelected()
            })
        }
        result.append(Item(id: "settings", title: "Настройки", symbol: "gearshape", shortcut: "⌘,") {
            openSettings()
        })

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return result }

        var filtered = result.filter {
            $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
        // Письма, подходящие под запрос.
        let hits = store.threads(in: .unified(.inbox)).filter {
            $0.latest.subject.lowercased().contains(q) || $0.latest.from.display.lowercased().contains(q)
        }
        for thread in hits.prefix(6) {
            let account = store.account(thread.latest.accountID)
            filtered.append(Item(id: "msg-\(thread.id)", title: thread.latest.subject,
                                 subtitle: thread.latest.from.display, symbol: "envelope",
                                 tint: account?.tint.color ?? .secondary) {
                store.select(scope: .unified(.inbox))
                store.selectedThreadID = thread.id
                store.openThread(thread.id)
            })
        }
        return filtered
    }

    var body: some View {
        let list = items

        ZStack(alignment: .top) {
            Color.black.opacity(appeared ? 0.18 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "command")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    TextField("Куда перейти или что сделать?", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
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
                }
                .padding(16)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                row(item, highlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture {
                                        highlighted = index
                                        run(list)
                                    }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: highlighted) { _, value in proxy.scrollTo(value) }
                }

                if list.isEmpty {
                    Text("Ничего не нашлось")
                        .foregroundStyle(.secondary)
                        .padding(20)
                }
            }
            .frame(width: 580)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 14)
            .padding(.top, 90)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            fieldFocused = true
            withAnimation(Motion.bouncy) { appeared = true }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(_ item: Item, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(highlighted ? .white : item.tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(highlighted ? Color.white.opacity(0.2) : item.tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(highlighted ? Color.white.opacity(0.8) : .secondary)
                }
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(highlighted ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(highlighted) else { return }
        let item = list[highlighted]
        close()
        item.run()
    }

    private func close() {
        withAnimation(Motion.snappy) {
            appeared = false
            store.isPalettePresented = false
        }
    }
}
