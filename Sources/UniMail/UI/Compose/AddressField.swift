import SwiftUI

/// Поле адресов с токенами. Enter, запятая или пробел превращают текст в токен,
/// Backspace в пустом поле удаляет последний.
/// Этап 5: автодополнение из истории переписки и Контактов macOS.
@MainActor
struct AddressField: View {
    @Binding var addresses: [Address]
    var placeholder: String

    @State var text = ""

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(addresses, id: \.email) { address in
                token(address)
            }
            TextField(addresses.isEmpty ? placeholder : "", text: $text)
                .textFieldStyle(.plain)
                .frame(minWidth: 140)
                .onSubmit(commit)
                .onChange(of: text) { _, value in
                    if value.hasSuffix(",") || value.hasSuffix(";") || (value.hasSuffix(" ") && value.contains("@")) {
                        commit()
                    }
                }
                .onKeyPress(.delete) {
                    guard text.isEmpty, !addresses.isEmpty else { return .ignored }
                    withAnimation(Motion.bouncy) { _ = addresses.removeLast() }
                    return .handled
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func token(_ address: Address) -> some View {
        let valid = address.email.contains("@") && address.email.contains(".")
        return HStack(spacing: 4) {
            Text(address.display)
                .font(.system(size: 12, weight: .medium))
            Button {
                withAnimation(Motion.bouncy) { addresses.removeAll { $0.email == address.email } }
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(valid ? Color.accentColor.opacity(0.14) : Color.red.opacity(0.15)))
        .foregroundStyle(valid ? Color.primary : Color.red)
        .help(address.full)
        .transition(.scale.combined(with: .opacity))
    }

    private func commit() {
        let raw = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        text = ""
        guard !raw.isEmpty else { return }
        let parsed = Self.parse(raw)
        guard !addresses.contains(where: { $0.email == parsed.email }) else { return }
        withAnimation(Motion.bouncy) { addresses.append(parsed) }
    }

    /// «Имя <адрес>» или просто «адрес».
    static func parse(_ raw: String) -> Address {
        if let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">"), open < close {
            let name = raw[..<open].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
            let email = String(raw[raw.index(after: open)..<close])
            return Address(name: name.isEmpty ? nil : name, email: email)
        }
        return Address(name: nil, email: raw)
    }
}
