import AppKit
import SwiftUI

/// Restricts password fields to Roman keyboard input sources: passwords may contain only digits, Latin letters and ASCII symbols.
/// In a plain-text field, input methods such as Chinese show a candidate window. In a hidden `SecureField`, input methods such as
/// Pinyin keep letters that do not form a syllable (such as a leading "u") as uncommitted marked text, which a secure field neither
/// shows nor commits, so the letter is lost. Both states therefore restrict the field editor currently editing when the field gains
/// focus (a secure field has its own field editor, not the window's shared one), and restore it on blur or disappearance, without
/// affecting other fields in the window.
///
/// When focus moves from one password field to another, the old field's "release" and the new field's "restrict" both run later,
/// in no fixed order, so release only restores when the restricted field is no longer being edited. The check is by field rather
/// than by field editor: secure fields in one window share a field editor, and so do plain-text and ordinary fields.
@MainActor
enum RomanInputOnly {
    private static weak var restrictedEditor: NSTextView?
    private static weak var restrictedField: AnyObject?

    static func apply(_ enabled: Bool) {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        if enabled {
            guard let editor else { return }
            editor.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
            restrictedEditor = editor
            restrictedField = editor.delegate
        } else {
            // Focus has already moved to another restricted field: leave it alone.
            if let field = restrictedField, editor?.delegate === field { return }
            restrictedEditor?.inputContext?.allowedInputSourceLocales = nil
            restrictedEditor = nil
            restrictedField = nil
        }
    }
}

extension View {
    /// `focused` is whether the password field has focus. Toggling `revealed` swaps in a different field (and field editor), so it
    /// is applied again. The field editor attaches to the field only after focus changes, and focus returns to the new field only
    /// a moment after toggling, so both cases apply it later.
    func romanInputOnly(focused: Bool, revealed: Bool) -> some View {
        onChange(of: focused) { _, value in
            Task { @MainActor in RomanInputOnly.apply(value) }
        }
        .onChange(of: revealed) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                if focused { RomanInputOnly.apply(true) }
            }
        }
        .onDisappear {
            if focused { RomanInputOnly.apply(false) }
        }
    }
}
