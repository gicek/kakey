import Foundation
import SwiftUI

/// The scoring rules live in the Rust core (`Core/crates/kakey-core/src/password.rs`); this only provides the text.
enum PasswordStrength: Int, CaseIterable {
    case empty = 0
    case weak = 1
    case fair = 2
    case good = 3
    case strong = 4

    var label: String {
        switch self {
        case .empty: L10n.tr("At least 8 characters")
        case .weak: L10n.tr("Weak")
        case .fair: L10n.tr("Fair")
        case .good: L10n.tr("Strong")
        case .strong: L10n.tr("Very Strong")
        }
    }

    static func evaluate(_ password: String) -> PasswordStrength {
        switch coreEvaluatePassword(password: password) {
        case .empty: .empty
        case .weak: .weak
        case .fair: .fair
        case .good: .good
        case .strong: .strong
        }
    }
}

/// Acceptance rules for master and export passwords. The rules live in the Rust core (`password.rs`); UI code calls only
/// this.
enum PasswordPolicy {
    /// The "at least 8 characters" in UI text must match this value.
    static var minimumLength: Int { Int(coreMinPasswordLength()) }

    /// New vault or master password change: at least 8 characters, allowed characters only, and at least Fair strength
    /// (Weak is rejected). Fair passwords are confirmed with `fairPasswordConfirmation` before submitting.
    static func isAcceptableMasterPassword(_ password: String) -> Bool {
        coreIsAcceptableMasterPassword(password: password)
    }

    /// Input filter for new passwords: keeps only digits, ASCII letters and ASCII symbols (no spaces), dropping anything else
    /// as it is typed or pasted, and truncates to 128 characters.
    static func filterInput(_ text: String) -> String {
        coreFilterPasswordInput(input: text)
    }

    /// Encrypted export: same rules as the master password; Fair passwords are likewise confirmed before exporting.
    static func isAcceptableExportPassword(_ password: String) -> Bool {
        coreIsAcceptableExportPassword(password: password)
    }

    /// Inline explanation of why a new password is unacceptable, checking length first and then strength; nil when acceptable
    /// (or still empty). Shared by every new-password screen.
    static func problem(for password: String) -> String? {
        guard !password.isEmpty else { return nil }
        if password.count < minimumLength { return L10n.tr("Password needs at least 8 characters") }
        if PasswordStrength.evaluate(password) == .weak {
            return L10n.tr("Too easy to crack. Use a longer password, or a few unrelated words.")
        }
        return nil
    }
}

extension View {
    /// For new-password fields (new vault, master password change, export password): keeps only allowed characters as the
    /// user types or pastes (the rules live in the core). Not used for unlock or import fields, so existing passwords can
    /// still be entered. Rewrites the value after it changes rather than intercepting in the `Binding`: if a rejected
    /// character leaves the bound value unchanged, the field keeps displaying it.
    func newPasswordInput(_ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, value in
            let filtered = PasswordPolicy.filterInput(value)
            if filtered != value { text.wrappedValue = filtered }
        }
    }
}

extension View {
    /// Confirmation before submitting a Fair-strength password, with the same text for master and export passwords: the user
    /// must read the warning and explicitly choose "Use Anyway". The default button (Return) picks a stronger password; "Use
    /// Anyway" can only be clicked.
    func fairPasswordConfirmation(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        alert(L10n.tr("Password Isn’t Strong Enough"), isPresented: isPresented) {
            Button(L10n.tr("Choose Stronger Password"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(L10n.tr("Use Anyway"), action: onConfirm)
        } message: {
            Text(L10n.tr("A strong password is recommended. It keeps your data safer and makes it harder to crack."))
        }
    }
}
