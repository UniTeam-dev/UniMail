import SwiftUI

/// Поле адресов с токенами. Enter, запятая или пробел после адреса превращают текст в токен,
/// Backspace в пустом поле удаляет последний. Некорректный адрес — красный токен.
/// Этап 5: автодополнение из истории переписки и Контактов macOS.
@MainActor
struct AddressField: View {
    @Binding var addresses: [Address]
    var placeholder: String = ""

    @State var text = ""

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(addresses, id: \.email) { address in
                token(address)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            TextField("", text: $text, prompt: Text(addresses.isEmpty ? placeholder : "").foregroundColor(UM.fg3))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 80, idealWidth: 160)
                .frame(height: 24)
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
        .animation(Motion.bouncy, value: addresses)
    }

    private func token(_ address: Address) -> some View {
        let bad = !address.isValid
        return HStack(spacing: 5) {
            if bad {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13))
            } else {
                SenderAvatar(address: address, size: 18, fontSize: 9)
            }
            Text(address.name ?? address.email)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Button {
                withAnimation(Motion.bouncy) { addresses.removeAll { $0.email == address.email } }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.55)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(bad ? UM.badFg : UM.fg)
        .padding(.leading, bad ? 7 : 3)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(Capsule().fill(bad ? UM.bad : UM.field))
        .overlay(Capsule().strokeBorder(bad ? UM.red.opacity(0.45) : .clear, lineWidth: 1))
        .help(address.full + (bad ? " — некорректный адрес" : ""))
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
