import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Paste Link" tab: one `otpauth://` or migration link per line. Accepts dropped plain text or `.txt` / `.text` / `.otpauth` /
/// `.csv` files, and lists the parsed results below.
struct OTPAuthTextPanel: View {
    @Binding var text: String
    /// Deduplicated parse results (the parent uses them to decide whether saving is possible).
    var items: [ParsedOTPAuth]

    @State private var isResolvingDroppedTextFile = false
    /// Dropped files whose content is already merged into the text: path lines the editor inserts for them afterwards are removed
    /// rather than expanded again.
    @State private var appendedDroppedFileURLs: Set<URL> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 150)
                .overlay(alignment: .topLeading) {
                    // When empty, show sample links; clearer than a blank area about what to paste.
                    if text.isEmpty {
                        Text(verbatim: "otpauth://totp/GitHub:you@example.com?secret=…&issuer=GitHub\notpauth-migration://offline?data=…")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .kakeyInputChrome(cornerRadius: 7)
                .onChange(of: text) { _, newValue in
                    resolveDroppedTextFileReferences(in: newValue)
                }
                .onDrop(
                    of: [UTType.plainText.identifier, UTType.text.identifier, UTType.fileURL.identifier],
                    isTargeted: nil,
                    perform: handleDroppedOTPAuthText
                )
            Text(L10n.tr("Paste one otpauth:// URL or Google Authenticator migration URL per line, or drop in a plain text file."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !items.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            HStack {
                                Text(item.isValid ? "\(item.issuer) — \(item.account)" : (item.reason ?? L10n.tr("Unable to parse")))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(item.isValid ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(item.isValid ? L10n.tr("Parsed") : L10n.tr("Unable to parse"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(item.isValid ? .green : .red)
                            }
                            .padding(8)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 6 * 37)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func handleDroppedOTPAuthText(_ providers: [NSItemProvider]) -> Bool {
        var didAcceptDrop = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didAcceptDrop = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = Self.droppedFileURL(from: item),
                        let text = try? String(contentsOf: url, encoding: .utf8)
                    else {
                        return
                    }
                    Task { @MainActor in
                        appendDroppedOTPAuthFile(url: url, text: text)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                didAcceptDrop = true
                provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                    guard let text = Self.droppedText(from: item) else { return }
                    Task { @MainActor in
                        appendDroppedOTPAuthText(text)
                    }
                }
            }
        }

        return didAcceptDrop
    }

    private func appendDroppedOTPAuthText(_ droppedText: String) {
        let cleanText = droppedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = cleanText
        } else {
            text += "\n\(cleanText)"
        }
    }

    /// Merges the file content immediately. The editor may insert a file path line a moment later, which
    /// `resolveDroppedTextFileReferences` removes.
    private func appendDroppedOTPAuthFile(url: URL, text fileText: String) {
        let cleanText = fileText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        appendedDroppedFileURLs.insert(url.standardizedFileURL)
        text = OTPAuthTextDropResolver.resolvedText(currentText: text, droppedFileURL: url, droppedFileText: cleanText)
    }

    private func resolveDroppedTextFileReferences(in currentText: String) {
        guard !isResolvingDroppedTextFile else { return }

        let withoutAppended = OTPAuthTextDropResolver.removingReferences(to: appendedDroppedFileURLs, from: currentText)
        let resolvedText = OTPAuthTextDropResolver.resolvedText(currentText: withoutAppended) { url in
            guard Self.isReadablePlainTextFile(url),
                let fileText = try? String(contentsOf: url, encoding: .utf8)
            else {
                return nil
            }
            return fileText
        }
        guard resolvedText != currentText else { return }

        isResolvingDroppedTextFile = true
        Task { @MainActor in
            text = resolvedText
            isResolvingDroppedTextFile = false
        }
    }

    nonisolated private static func droppedText(from item: NSSecureCoding?) -> String? {
        if let text = item as? String {
            return text
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    nonisolated private static func droppedFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data,
            let text = String(data: data, encoding: .utf8)
        {
            return OTPAuthTextDropResolver.fileURL(fromDroppedText: text)
        }
        if let text = item as? String {
            return OTPAuthTextDropResolver.fileURL(fromDroppedText: text)
        }
        return nil
    }

    nonisolated private static func isReadablePlainTextFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let allowedExtensions = ["txt", "text", "otpauth", "csv"]
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) || ext.isEmpty else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
}
