import SwiftUI

/// Правая колонка: тулбар действий с поиском, открытый тред или пустое состояние, тост «Отменить».
@MainActor
struct ReaderColumn: View {
    @Environment(MailStore.self) private var store
    let narrow: Bool

    @State private var snoozeOpen = false
    @State private var flagPulse = false

    private var threadID: String? {
        guard let id = store.selectedThreadID, !store.thread(id).isEmpty else { return nil }
        return id
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .zIndex(2)

            ZStack {
                if let threadID {
                    ThreadView(threadID: threadID)
                        .id(threadID)
                        .transition(Motion.contentTransition)
                } else {
                    EmptyReader()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.smooth, value: threadID)
            .overlay {
                // Клик мимо меню «Отложить» закрывает его. Ловушка лежит под тулбаром (zIndex 2),
                // чтобы не перекрывать само меню, которое висит в оверлее тулбара.
                if snoozeOpen {
                    Color.black.opacity(0.001)
                        .onTapGesture { withAnimation(Motion.pop) { snoozeOpen = false } }
                }
            }
        }
        .background(UM.win)
        .overlay(alignment: .bottom) {
            UndoToast()
                .padding(.bottom, 22)
        }
        .onChange(of: store.snoozeMenuRequest) { _, _ in
            guard threadID != nil else { return }
            withAnimation(Motion.pop) { snoozeOpen.toggle() }
        }
        .onKeyPress(.escape) {
            guard snoozeOpen else { return .ignored }
            withAnimation(Motion.pop) { snoozeOpen = false }
            return .handled
        }
    }

    // MARK: Тулбар

    private var toolbar: some View {
        @Bindable var store = store
        let ids = threadID.map { [$0] } ?? []
        let last = threadID.flatMap { store.thread($0).last }
        let flagged = threadID.map { store.thread($0).contains(where: \.isFlagged) } ?? false

        return HStack(spacing: 6) {
            HStack(spacing: 0) {
                toolButton("arrowshape.turn.up.left", "Ответить · R", width: 32, height: 26, radius: 7) {
                    store.quickReplyRequest += 1
                }
                toolButton("arrowshape.turn.up.left.2", "Ответить всем", width: 32, height: 26, radius: 7) {
                    if let last { store.compose(.replyAll, from: last.id) }
                }
                toolButton("arrowshape.turn.up.right", "Переслать", width: 32, height: 26, radius: 7) {
                    if let last { store.compose(.forward, from: last.id) }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UM.field))

            Color.clear.frame(width: 6, height: 1)

            toolButton("archivebox", "Архив · E") { store.archive(threadIDs: ids) }
            toolButton("trash", "Удалить") { store.trash(threadIDs: ids) }

            Button {
                store.toggleFlag(threadIDs: ids)
                withAnimation(Motion.bouncy) { flagPulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    withAnimation(Motion.bouncy) { flagPulse = false }
                }
            } label: {
                Image(systemName: flagged ? "flag.fill" : "flag")
                    .scaleEffect(flagPulse ? 1.35 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ToolbarIconStyle(tint: flagged ? UM.orange : nil))
            .help("Флажок")
            .disabled(ids.isEmpty)

            Button {
                withAnimation(Motion.pop) { snoozeOpen.toggle() }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: "clock")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).padding(.leading, 3)
                }
                .padding(.leading, 7)
                .padding(.trailing, 6)
            }
            .buttonStyle(ToolbarIconStyle(width: 0, active: snoozeOpen))
            .help("Отложить · H")
            .disabled(ids.isEmpty)
            .overlay(alignment: .topLeading) {
                if snoozeOpen {
                    SnoozeMenu(threadIDs: ids) {
                        withAnimation(Motion.pop) { snoozeOpen = false }
                    }
                    .fixedSize()
                    .offset(y: 34)
                    .transition(Motion.popTransition)
                }
            }

            Menu {
                Button("Прочитано / не прочитано", systemImage: "envelope.badge") { store.toggleRead(threadIDs: ids) }
                Button("Во входящие", systemImage: "tray") { store.moveToInbox(threadIDs: ids) }
                Button("Это спам", systemImage: "exclamationmark.octagon") { store.markSpam(threadIDs: ids) }
                Divider()
                Button("Ответить в отдельном окне", systemImage: "macwindow") {
                    if let last { store.compose(.reply, from: last.id) }
                }
                if let threadID, store.isAwaitingReply(threadID: threadID) {
                    Button("Снять напоминание «нет ответа»", systemImage: "bell.slash") {
                        store.dismissFollowUp(threadID: threadID)
                    }
                }
                Divider()
                Button("Экспорт в PDF…", systemImage: "doc.richtext") {
                    if let threadID { ExportService.shared.exportThreadToPDF(threadID: threadID, store: store) }
                }
                Button("Напечатать…", systemImage: "printer") {
                    if let threadID { ExportService.shared.printThread(threadID: threadID, store: store) }
                }
                Button("Сохранить как .eml…", systemImage: "square.and.arrow.down") {
                    if let threadID { ExportService.shared.saveThreadMessageAsEML(threadID: threadID, store: store) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 28)
            .disabled(ids.isEmpty)
            .help("Ещё")

            Spacer(minLength: 8)

            SearchField(text: $store.searchText)
                .frame(width: narrow ? 150 : 200)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 52)
        .hairline(.bottom, color: UM.tbSep)
    }

    private func toolButton(_ symbol: String, _ help: String, width: CGFloat = 32, height: CGFloat = 28,
                            radius: CGFloat = 8, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(ToolbarIconStyle(width: width, height: height, radius: radius))
            .help(help)
            .disabled(threadID == nil)
    }
}

// MARK: - Поиск

@MainActor
struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13))
            TextField("", text: $text, prompt: Text("Поиск").foregroundColor(UM.fg3))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(UM.fg)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .foregroundStyle(UM.fg3)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UM.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? UM.accent : .clear, lineWidth: 1))
        .animation(Motion.snappy, value: text.isEmpty)
    }
}

// MARK: - Меню «Отложить»

@MainActor
struct SnoozeMenu: View {
    @Environment(MailStore.self) private var store
    let threadIDs: [String]
    var onClose: () -> Void

    @State private var showCustom = false
    @State private var custom = Date.now.addingTimeInterval(24 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Отложить до…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UM.fg3)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ForEach(TimePreset.allCases) { preset in
                MenuRow(symbol: preset.symbol, title: preset.title, detail: preset.subtitle) {
                    store.snooze(threadIDs: threadIDs, until: preset.date, label: preset.title)
                    onClose()
                }
            }
            MenuSeparator()
            MenuRow(symbol: "calendar", title: "Выбрать дату и время…") { showCustom = true }
                .popover(isPresented: $showCustom, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Отложить до").font(.system(size: 13, weight: .semibold))
                        DatePicker("", selection: $custom, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                        HStack {
                            Spacer()
                            Button("Отложить") {
                                store.snooze(threadIDs: threadIDs, until: custom)
                                showCustom = false
                                onClose()
                            }
                            .buttonStyle(UMButtonStyle())
                        }
                    }
                    .padding(16)
                    .frame(width: 300)
                }
        }
        .padding(5)
        .frame(width: 290)
        .umMenuSurface(radius: 12)
    }
}

// MARK: - Пустое окно чтения

@MainActor
private struct EmptyReader: View {
    @State private var floating = false

    private struct Shortcut: Identifiable {
        var title: String
        var keys: [String]
        var id: String { title }
    }

    private let shortcuts: [Shortcut] = [
        Shortcut(title: "Командная палитра", keys: ["⌘", "K"]),
        Shortcut(title: "Переключить ящик", keys: ["⌘", "1…9"]),
        Shortcut(title: "Следующее / предыдущее", keys: ["J", "K"]),
        Shortcut(title: "Архивировать", keys: ["E"]),
        Shortcut(title: "Отложить", keys: ["H"]),
        Shortcut(title: "Ответить", keys: ["R"]),
    ]

    var body: some View {
        VStack(spacing: 30) {
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(Color.black.opacity(floating ? 0.3 * 0.6 : 0.5 * 0.36))
                    .frame(width: 64, height: 10)
                    .blur(radius: 6)
                    .scaleEffect(x: floating ? 0.8 : 1, y: 1)
                Image(systemName: "envelope.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(UM.accent)
                    .frame(width: 88, height: 88)
                    .umCard(radius: 24)
                    .offset(y: floating ? -38 : -28)
            }
            .frame(width: 96, height: 116)
            .onAppear {
                guard !Motion.reduce else { return }
                withAnimation(.easeInOut(duration: 2.25).repeatForever(autoreverses: true)) { floating = true }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Горячие клавиши")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UM.fg3)
                    .padding(.bottom, 6)
                ForEach(shortcuts) { shortcut in
                    HStack(spacing: 10) {
                        Text(shortcut.title).font(.system(size: 12.5)).foregroundStyle(UM.fg2)
                        Spacer()
                        HStack(spacing: 3) {
                            ForEach(shortcut.keys, id: \.self) { KeyCap(text: $0) }
                        }
                    }
                    .frame(height: 30)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: 300)
            .umCard(radius: 14)
        }
        .padding(.bottom, 30)
    }
}
