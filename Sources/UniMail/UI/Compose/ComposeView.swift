import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Окно написания письма.
@MainActor
struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let request: ComposeRequest

    @State private var draft: OutgoingMessage
    @State private var showCc = false
    @State private var attachments: [URL] = []
    @State private var showSchedule = false
    @State private var customDate = Date.now.addingTimeInterval(3600)
    @State private var confirmNoAttachment = false
    @State private var sendPulse = 0
    @FocusState private var focus: Field?

    private enum Field { case to, subject, body }

    init(request: ComposeRequest) {
        self.request = request
        _draft = State(initialValue: request.draft)
        _showCc = State(initialValue: !request.draft.cc.isEmpty || !request.draft.bcc.isEmpty)
    }

    private var account: Account? { store.account(draft.accountID) }

    var body: some View {
        VStack(spacing: 0) {
            fields
            Divider()
            TextEditor(text: $draft.body)
                .font(.system(size: 14))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .focused($focus, equals: .body)

            if !attachments.isEmpty {
                Divider()
                FlowLayout(spacing: 8) {
                    ForEach(attachments, id: \.self) { url in
                        attachmentChip(url)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            bottomBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(draft.subject.isEmpty ? request.windowTitle : draft.subject)
        .onAppear {
            focus = draft.to.isEmpty ? .to : .body
        }
        .onChange(of: draft) { _, value in
            store.saveDraft(value, requestID: request.id)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in withAnimation(Motion.bouncy) { attachments.append(url) } } }
                }
            }
            return true
        }
        .confirmationDialog("В письме упомянуто вложение, но файлов нет", isPresented: $confirmNoAttachment) {
            Button("Всё равно отправить") { send() }
            Button("Прикрепить файл") { pickFiles() }
        }
    }

    // MARK: Поля

    private var fields: some View {
        VStack(spacing: 0) {
            fieldRow("От") {
                Menu {
                    ForEach(store.accounts) { acc in
                        ForEach([acc.email] + acc.aliases, id: \.self) { address in
                            Button {
                                draft.accountID = acc.id
                                draft.fromAddress = address
                            } label: {
                                Text("\(acc.displayName) — \(address)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(account?.tint.color ?? .gray).frame(width: 8, height: 8)
                        Text(account.map { "\($0.displayName) <\(draft.fromAddress)>" } ?? draft.fromAddress)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }

            fieldRow("Кому") {
                AddressField(addresses: $draft.to, placeholder: "Имя или адрес")
                    .focused($focus, equals: .to)
                if !showCc {
                    Button("Копия") { withAnimation(Motion.smooth) { showCc = true } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            if showCc {
                fieldRow("Копия") { AddressField(addresses: $draft.cc, placeholder: "") }
                    .transition(.move(edge: .top).combined(with: .opacity))
                fieldRow("Скрытая") { AddressField(addresses: $draft.bcc, placeholder: "") }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            fieldRow("Тема") {
                TextField("", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($focus, equals: .subject)
            }
        }
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider().padding(.leading, 82)
        }
    }

    private func attachmentChip(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 18, height: 18)
            Text(url.lastPathComponent).font(.caption).lineLimit(1)
            Button {
                withAnimation(Motion.bouncy) { attachments.removeAll { $0 == url } }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: Нижняя панель

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { pickFiles() } label: {
                Label("Вложить", systemImage: "paperclip")
            }
            .help("Прикрепить файлы (или перетащите их в окно)")

            Toggle(isOn: $draft.sendSeparately) {
                Label("Каждому отдельно", systemImage: "person.2.slash")
            }
            .toggleStyle(.button)
            .help("Каждый получатель получит отдельное письмо и не увидит остальных")

            Spacer()

            if let sendAt = draft.sendAt {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.badge.clock")
                    Text(sendAt.formatted(.dateTime.day().month().hour().minute()))
                    Button {
                        withAnimation(Motion.snappy) { draft.sendAt = nil }
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .transition(.scale.combined(with: .opacity))
            }

            Button(role: .destructive) {
                store.discardDraft(requestID: request.id)
                dismiss()
            } label: {
                Image(systemName: "trash")
            }
            .help("Удалить черновик")

            Menu {
                Section("Отправить позже") {
                    ForEach(TimePreset.allCases) { preset in
                        Button("\(preset.title) — \(preset.subtitle)") {
                            withAnimation(Motion.snappy) { draft.sendAt = preset.date }
                        }
                    }
                    Button("Выбрать дату и время…") { showSchedule = true }
                }
            } label: {
                Label(draft.sendAt == nil ? "Отправить" : "Запланировать", systemImage: "paperplane.fill")
                    .symbolEffect(.bounce, value: sendPulse)
            } primaryAction: {
                attemptSend()
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(draft.to.isEmpty)
            .background {
                // ⌘↩ — отправить. Невидимая кнопка: у Menu шорткат не вызывает primaryAction.
                Button("Отправить", action: attemptSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.to.isEmpty)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            .popover(isPresented: $showSchedule, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Когда отправить?").font(.headline)
                    DatePicker("", selection: $customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    HStack {
                        Spacer()
                        Button("Готово") {
                            withAnimation(Motion.snappy) { draft.sendAt = customDate }
                            showSchedule = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .frame(width: 300)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Действия

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            withAnimation(Motion.bouncy) { attachments.append(contentsOf: panel.urls) }
        }
    }

    private func attemptSend() {
        let mentions = ["вложен", "прикреп", "attach"].contains { draft.body.lowercased().contains($0) }
        if mentions && attachments.isEmpty {
            confirmNoAttachment = true
        } else {
            send()
        }
    }

    private func send() {
        sendPulse += 1
        store.send(draft, requestID: request.id)
        dismiss()
    }
}
