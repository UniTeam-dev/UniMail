import SwiftUI

/// Папки выбранного ящика (или единые папки всех ящиков).
@MainActor
struct MailboxList: View {
    @Environment(MailStore.self) private var store
    @Namespace private var selectionNS

    private let primary: [MailboxRole] = [.inbox, .snoozed, .flagged, .drafts, .scheduled, .sent]
    private let secondary: [MailboxRole] = [.archive, .spam, .trash]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(primary) { role in row(role) }
                    sectionTitle("Ещё")
                    ForEach(secondary) { role in row(role) }

                    if store.scope.accountID == nil {
                        sectionTitle("Показывать ящики")
                        ForEach(store.accounts) { account in
                            accountToggle(account)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            footer
        }
    }

    // MARK: Заголовок

    private var header: some View {
        let account = store.scope.accountID.flatMap { store.account($0) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(account?.displayName ?? "Все ящики")
                .font(.title3.weight(.semibold))
            Text(account?.email ?? "\(store.accounts.count) аккаунта в одном списке")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .id(store.scope.accountID)
        .transition(.push(from: .bottom).combined(with: .opacity))
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    // MARK: Строки

    private func row(_ role: MailboxRole) -> some View {
        let scope = store.scope.with(role: role)
        let isSelected = store.scope == scope
        let unread = store.unreadCount(scope)
        let total = role.countsUnread ? 0 : store.totalCount(scope)

        return Button {
            store.select(scope: scope)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? role.selectedSymbol : role.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20)
                    .contentTransition(.symbolEffect(.replace))
                Text(role.title)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
                if unread > 0 {
                    CountBadge(count: unread, tint: .accentColor, prominent: isSelected)
                } else if total > 0 {
                    Text("\(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText(value: Double(total)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .matchedGeometryEffect(id: "mailbox-selection", in: selectionNS)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .animation(Motion.bouncy, value: unread)
    }

    private func accountToggle(_ account: Account) -> some View {
        let visible = !store.hiddenAccountIDs.contains(account.id)
        return Button {
            store.toggleHidden(account.id)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(account.tint.color)
                    .frame(width: 12, height: 12)
                    .opacity(visible ? 1 : 0.3)
                Text(account.displayName)
                    .foregroundStyle(visible ? .primary : .tertiary)
                Spacer()
                Image(systemName: visible ? "eye" : "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    // MARK: Статус

    private var footer: some View {
        let failing = store.accounts.filter { store.accountErrors[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(failing) { account in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(account.displayName): \(store.accountErrors[account.id] ?? "")").lineLimit(3)
                }
                .font(.caption)
            }
            HStack(spacing: 6) {
                if store.syncingAccountIDs.isEmpty {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("Почта обновлена")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Синхронизация…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.smooth, value: store.syncingAccountIDs.isEmpty)
    }
}

/// Строка с подсветкой при наведении.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Motion.snappy, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
