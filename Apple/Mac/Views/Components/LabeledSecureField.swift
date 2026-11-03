import AppKit
import SwiftUI

/// Password field with a label above and a show / hide button on the right (shared by onboarding and change master password). No
/// placeholder text inside the field.
/// Return first ends editing (the window resigns first responder, the same path as clicking empty space) and then calls `onSubmit`,
/// so callers can validate after leaving the field or submit directly when the input is already valid.
/// When AppKit handles Return it sends the action (onSubmit) first, then selects all text and keeps the field focused, which undoes
/// a synchronous resign inside onSubmit; so the resign is deferred until this key event has been handled.
/// `focused` can be omitted when the caller does not need it; the component then owns the focus state.
struct LabeledSecureField: View {
    var label: String
    @Binding var text: String
    @Binding var reveal: Bool
    var focused: FocusState<Bool>.Binding? = nil
    var onSubmit: () -> Void = {}

    @FocusState private var ownFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                field
                    .focused(focused ?? $ownFocus)
                    .accessibilityLabel(label)
                    .onSubmit {
                        Task { @MainActor in
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            onSubmit()
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .romanInputOnly(focused: focused?.wrappedValue ?? ownFocus, revealed: reveal)

                RevealSecretButton(isRevealed: reveal) { reveal.toggle() }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 42)
            .kakeyInputChrome(cornerRadius: 8)
        }
    }

    @ViewBuilder
    private var field: some View {
        if reveal {
            TextField("", text: $text)
        } else {
            SecureField("", text: $text)
        }
    }
}
