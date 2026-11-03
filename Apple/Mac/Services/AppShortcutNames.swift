import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openMenuBar = Self("openMenuBar", initial: .init(.z, modifiers: [.command, .option]))
    static let openMainWindow = Self("openMainWindow", initial: .init(.x, modifiers: [.command, .option]))
    static let captureQRCode = Self("captureQRCode", initial: .init(.a, modifiers: [.command, .option]))
}
