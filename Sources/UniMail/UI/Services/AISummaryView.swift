import SwiftUI

/// Карточка AI над письмами треда: «Кратко пересказать» и «Черновик ответа».
/// Если AI выключен в настройках, ничего не показывает.
///
/// Встраивается интегратором в `ThreadView` между заголовком и карточками писем:
/// `AISummaryView(threadID: threadID).padding(.top, 16)`.
@MainActor
struct AISummaryView: View {
    let threadID: String

    @Environment(MailStore.self) private var store
    @AppStorage(AppSettings.aiEnabled) private var aiEnabled = false

    @State private var phase: Phase = .idle
    @State private var activeThreadID: String?
    @State private var draftOpen = false
    @State private var instruction = ""
    @State private var drafting = false
    @State private var draftError: String?

    private enum Phase: Equatable {
        case idle
        case loading
        case done(String)
        case failed(String)
    }

    var body: some View {
        if aiEnabled {
            card
                .task(id: threadID) { reset() }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UM.accent)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UM.accentSoft))
                Text("AI-помощник")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                summaryControls
                Button {
                    withAnimation(Motion.snappy) { draftOpen.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .semibold))
                        Text("Черновик ответа")
                    }
                }
                .buttonStyle(UMButtonStyle(kind: draftOpen ? .primary : .secondary, height: 26, radius: 7, horizontal: 10))
            }

            switch phase {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Читаю переписку…").foregroundStyle(UM.fg3)
                }
                .font(.system(size: 12.5))
                .transition(.opacity)
            case .done(let text):
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(UM.fg)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            case .failed(let message):
                errorText(message)
            }

            if draftOpen {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Пожелание: «вежливо отказать», «согласиться на вторник»…", text: $instruction)
                            .umFieldStyle()
                            .onSubmit(makeDraft)
                            .disabled(drafting)
                        if drafting {
                            ProgressView().controlSize(.small).frame(width: 28)
                        } else {
                            Button("Написать", action: makeDraft)
                                .buttonStyle(UMButtonStyle(kind: .primary))
                        }
                    }
                    Text("Черновик откроется в окне ответа — его можно поправить перед отправкой.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(UM.fg3)
                    if let draftError { errorText(draftError) }
                }
                .transition(Motion.contentTransition)
            }
        }
        .padding(14)
        .umCard(radius: 14, small: true)
        .animation(Motion.smooth, value: phase)
        .animation(Motion.smooth, value: draftOpen)
    }

    @ViewBuilder
    private var summaryControls: some View {
        switch phase {
        case .idle, .failed:
            Button("Кратко пересказать", action: startSummary)
                .buttonStyle(UMButtonStyle(kind: .secondary, height: 26, radius: 7, horizontal: 10))
        case .loading:
            EmptyView()
        case .done:
            Button(action: { summarize(force: true) }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(ToolbarIconStyle(width: 26, height: 26, radius: 7))
            .help("Пересказать заново")
            Button(action: { withAnimation(Motion.smooth) { phase = .idle } }) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(ToolbarIconStyle(width: 26, height: 26, radius: 7))
            .help("Скрыть сводку")
        }
    }

    private func errorText(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(UM.badFg)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UM.bad))
    }

    // MARK: Действия

    private func reset() {
        activeThreadID = threadID
        let messages = store.thread(threadID)
        if let cached = AIService.shared.cachedSummary(threadID: threadID, messageCount: messages.count) {
            phase = .done(cached)
        } else {
            phase = .idle
        }
        draftOpen = false
        instruction = ""
        drafting = false
        draftError = nil
    }

    private func startSummary() {
        summarize(force: false)
    }

    private func summarize(force: Bool) {
        let requested = threadID
        let messages = store.thread(requested)
        if !force, let cached = AIService.shared.cachedSummary(threadID: requested, messageCount: messages.count) {
            phase = .done(cached)
            return
        }
        if force { AIService.shared.forgetSummary(threadID: requested, messageCount: messages.count) }
        phase = .loading
        Task {
            do {
                let text = try await AIService.shared.summarize(thread: messages)
                guard activeThreadID == requested else { return }
                phase = .done(text)
            } catch {
                guard activeThreadID == requested else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func makeDraft() {
        guard !drafting else { return }
        let requested = threadID
        let messages = store.thread(requested)
        let wish = instruction
        drafting = true
        draftError = nil
        Task {
            do {
                let text = try await AIService.shared.draftReply(thread: messages, instruction: wish)
                guard activeThreadID == requested else { return }
                drafting = false
                draftOpen = false
                instruction = ""
                store.composeReply(threadID: requested, prefilledText: text)
            } catch {
                guard activeThreadID == requested else { return }
                drafting = false
                draftError = error.localizedDescription
            }
        }
    }
}
