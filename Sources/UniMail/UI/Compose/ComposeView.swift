import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Окно написания письма (экран 9 макета).
@MainActor
struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let request: ComposeRequest

    @State private var draft: OutgoingMessage
    @State private var showCc = false
    @State private var attachments: [URL] = []
    @State private var fromOpen = false
    @State private var sendMenuOpen = false
    @State private var confirmNoAttachment = false
    @State private var scheduleDay: Date = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var scheduleTime = "08:00"
    @State private var calendarMonth = Date.now
    @FocusState private var focus: Field?

    private enum Field { case to, subject, body }
    private let times = ["08:00", "09:30", "13:00", "18:00"]

    init(request: ComposeRequest) {
        self.request = request
        _draft = State(initialValue: request.draft)
        _showCc = State(initialValue: !request.draft.cc.isEmpty || !request.draft.bcc.isEmpty)
    }

    private var account: Account? { store.account(draft.accountID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            fields.zIndex(2)
            bodyEditor
                .overlay {
                    // Клик мимо меню закрывает его. Ловушка под полями (zIndex 2), чтобы не перекрывать меню «От».
                    if fromOpen || sendMenuOpen {
                        Color.black.opacity(0.001)
                            .onTapGesture { closeMenus() }
                    }
                }
            if !attachments.isEmpty { attachmentRow }
            bottomBar.zIndex(3)
        }
        .background(UM.win)
        .foregroundStyle(UM.fg)
        .font(.system(size: 13))
        .ignoresSafeArea()
        .overlay(alignment: .bottomTrailing) {
            if sendMenuOpen {
                sendMenu
                    .padding(.trailing, 14)
                    .padding(.bottom, 62)
                    .transition(Motion.reduce ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .animation(Motion.pop, value: sendMenuOpen)
        .animation(Motion.pop, value: fromOpen)
        .onAppear { focus = draft.to.isEmpty ? .to : .body }
        .onChange(of: draft) { _, value in store.saveDraft(value, requestID: request.id) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in withAnimation(Motion.bouncy) { attachments.append(url) } }
                }
            }
            return true
        }
        .confirmationDialog("В письме упомянуто вложение, но файлов нет", isPresented: $confirmNoAttachment) {
            Button("Всё равно отправить") { send() }
            Button("Прикрепить файл") { pickFiles() }
        }
    }

    // MARK: Шапка 44 pt

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 60, height: 1) // место под «светофор»
            Spacer()
            Text(request.mode == .new || request.mode == .draft ? "Новое письмо" : request.windowTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            HStack(spacing: 2) {
                Button {} label: { Image(systemName: "textformat") }
                    .buttonStyle(ToolbarIconStyle(width: 30, height: 26, radius: 7))
                    .help("Форматирование (этап 5)")
                Button { NSApp.keyWindow?.zoom(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(ToolbarIconStyle(width: 30, height: 26, radius: 7))
                    .help("Развернуть")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .hairline(.bottom)
    }

    // MARK: Поля

    private var fields: some View {
        VStack(spacing: 0) {
            fieldRow("От", height: 42) {
                Button { withAnimation(Motion.pop) { fromOpen.toggle() } } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(account?.tint.color ?? UM.fg3)
                            .frame(width: 9, height: 9)
                        Text(account?.displayName ?? "").fontWeight(.medium)
                        Text(draft.fromAddress).foregroundStyle(UM.fg3)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(UM.fg3)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 8)
                    .frame(height: 28)
                }
                .buttonStyle(HoverStyle(radius: 8, pressScale: 1))
                .overlay(alignment: .topLeading) {
                    if fromOpen {
                        fromMenu
                            .offset(y: 32)
                            .transition(Motion.popTransition)
                    }
                }
                Spacer()
            }
            .zIndex(2)

            fieldRow("Кому", minHeight: 42) {
                AddressField(addresses: $draft.to)
                    .focused($focus, equals: .to)
                if !showCc {
                    Button("Копия, Скрытая") { withAnimation(Motion.smooth) { showCc = true } }
                        .buttonStyle(HoverStyle(radius: 6, pressScale: 1))
                        .font(.system(size: 12.5))
                        .foregroundStyle(UM.fg3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
            }

            if showCc {
                fieldRow("Копия", minHeight: 42) { AddressField(addresses: $draft.cc) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                fieldRow("Скрытая", minHeight: 42) { AddressField(addresses: $draft.bcc) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            fieldRow("Тема", height: 46) {
                TextField("", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .focused($focus, equals: .subject)
            }
        }
        .padding(.horizontal, 20)
    }

    private func fieldRow<Content: View>(_ label: String, height: CGFloat? = nil, minHeight: CGFloat? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .foregroundStyle(UM.fg3)
                .frame(width: 52, alignment: .leading)
            content()
        }
        .padding(.vertical, minHeight == nil ? 0 : 6)
        .frame(minHeight: minHeight, idealHeight: height, maxHeight: height)
        .hairline(.bottom)
    }

    private var fromMenu: some View {
        VStack(spacing: 0) {
            ForEach(store.accounts) { acc in
                ForEach([acc.email] + acc.aliases, id: \.self) { address in
                    FromRow(account: acc, address: address,
                            label: address == acc.email ? acc.displayName : "\(acc.displayName) · алиас",
                            checked: draft.accountID == acc.id && draft.fromAddress == address) {
                        draft.accountID = acc.id
                        draft.fromAddress = address
                        withAnimation(Motion.pop) { fromOpen = false }
                    }
                }
            }
        }
        .padding(5)
        .frame(width: 330)
        .umMenuSurface(radius: 11)
    }

    // MARK: Текст и вложения

    private var bodyEditor: some View {
        TextEditor(text: $draft.body)
            .font(.system(size: 13.5))
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .body)
            .padding(.top, 18)
            .padding(.leading, 77)
            .padding(.trailing, 20)
            .padding(.bottom, 8)
    }

    private var attachmentRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(attachments, id: \.self) { url in
                AttachmentChip(attachment: attachment(for: url), removable: true) {
                    withAnimation(Motion.bouncy) { attachments.removeAll { $0 == url } }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 82)
        .padding(.trailing, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attachment(for url: URL) -> Attachment {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return Attachment(filename: url.lastPathComponent, size: size, mimeType: type)
    }

    // MARK: Нижняя панель 56 pt

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(action: pickFiles) {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 13))
                    Text("Вложить")
                }
                .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(UMButtonStyle(kind: .secondary, height: 30, radius: 8, horizontal: 11))

            Button { draft.sendSeparately.toggle() } label: {
                HStack(spacing: 8) {
                    MiniSwitch(isOn: draft.sendSeparately, width: 28, height: 17)
                    Text("Каждому отдельно").font(.system(size: 12.5))
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
            }
            .buttonStyle(HoverStyle(radius: 8, pressScale: 1))
            .help("Каждый получатель получит отдельное письмо и не увидит остальных")

            if let sendAt = draft.sendAt {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.circle").font(.system(size: 13))
                    Text("Отправится \(RelativeDate.long(sendAt).lowercased())")
                    Button {
                        withAnimation(Motion.snappy) { draft.sendAt = nil }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UM.accent)
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .frame(height: 26)
                .background(Capsule().fill(UM.accentSoft))
                .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            Button {
                store.discardDraft(requestID: request.id)
                dismiss()
            } label: { Image(systemName: "trash") }
                .buttonStyle(ToolbarIconStyle(width: 32, height: 30))
                .help("Удалить черновик")

            // Split-кнопка: отправить / меню «Отправить позже».
            HStack(spacing: 0) {
                Button(action: attemptSend) {
                    HStack(spacing: 6) {
                        Image(systemName: draft.sendAt == nil ? "paperplane.fill" : "paperplane.circle.fill")
                            .font(.system(size: 13))
                        Text(draft.sendAt == nil ? "Отправить" : "Запланировать")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.to.isEmpty)

                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 0.5).padding(.vertical, 6)

                Button { withAnimation(Motion.pop) { sendMenuOpen.toggle() } } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UM.accent))
            .shadow(color: Color(red: 40 / 255, green: 80 / 255, blue: 220 / 255).opacity(0.3), radius: 1, y: 1)
            .opacity(draft.to.isEmpty ? 0.6 : 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 56)
        .background(UM.list)
        .hairline(.top)
        .animation(Motion.snappy, value: draft.sendAt)
    }

    // MARK: Меню отправки

    private var scheduleDate: Date {
        let parts = scheduleTime.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 8, minute: parts.last ?? 0, second: 0, of: scheduleDay) ?? scheduleDay
    }

    private var sendMenu: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(RelativeDate.monthTitle(calendarMonth)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    HStack(spacing: 2) {
                        Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                        Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UM.fg3)
                }
                .padding(.bottom, 8)

                MonthGrid(month: calendarMonth, selected: scheduleDay, cellHeight: 30, circle: 28, fontSize: 12,
                          disablePast: true) { day in
                    scheduleDay = day
                }

                HStack(spacing: 5) {
                    ForEach(times, id: \.self) { time in
                        let on = time == scheduleTime
                        Button { scheduleTime = time } label: {
                            Text(time).monospacedDigit().frame(maxWidth: .infinity)
                        }
                        .buttonStyle(UMButtonStyle(kind: .custom(on ? UM.accentSoft : UM.field, on ? UM.accent : UM.fg),
                                                   height: 28, radius: 7, horizontal: 0))
                    }
                }
                .padding(.top, 10)

                Button {
                    draft.sendAt = scheduleDate
                    withAnimation(Motion.pop) { sendMenuOpen = false }
                } label: {
                    Text("Запланировать · \(RelativeDate.dayMonthShort(scheduleDay)), \(scheduleTime)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(UMButtonStyle(kind: .primary, height: 30, radius: 8))
                .disabled(scheduleDate < .now)
                .padding(.top, 12)
            }
            .padding(14)
            .frame(width: 282)
            .umMenuSurface(radius: 13)

            VStack(spacing: 0) {
                MenuRow(symbol: "paperplane", title: "Отправить сейчас", detail: "⌘↩") {
                    draft.sendAt = nil
                    sendMenuOpen = false
                    attemptSend()
                }
                MenuRow(symbol: "paperplane.circle", title: "Отправить позже", trailingSymbol: "chevron.right",
                        highlighted: true) {}
                MenuSeparator()
                MenuRow(symbol: draft.remindIfNoReply ? "checkmark" : "bell", title: "Напомнить, если нет ответа") {
                    draft.remindIfNoReply.toggle()
                }
            }
            .padding(5)
            .frame(width: 230)
            .umMenuSurface(radius: 11)
        }
    }

    private func shiftMonth(_ delta: Int) {
        calendarMonth = Calendar.current.date(byAdding: .month, value: delta, to: calendarMonth) ?? calendarMonth
    }

    // MARK: Действия

    private func closeMenus() {
        withAnimation(Motion.pop) {
            fromOpen = false
            sendMenuOpen = false
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            withAnimation(Motion.bouncy) { attachments.append(contentsOf: panel.urls) }
        }
    }

    private func attemptSend() {
        guard !draft.to.isEmpty else { return }
        let mentions = ["вложен", "прикреп", "attach"].contains { draft.body.lowercased().contains($0) }
        if mentions && attachments.isEmpty {
            confirmNoAttachment = true
        } else {
            send()
        }
    }

    private func send() {
        store.send(draft, requestID: request.id)
        dismiss()
    }
}

/// Строка выбора отправителя с галочкой.
@MainActor
private struct FromRow: View {
    let account: Account
    let address: String
    let label: String
    let checked: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(account.tint.color).frame(width: 9, height: 9)
                Text(label).fontWeight(.medium)
                Text(address).font(.system(size: 12)).opacity(0.6).lineLimit(1)
                Spacer()
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(checked ? 1 : 0)
            }
            .foregroundStyle(hovering ? Color.white : UM.fg)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? UM.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
