import Foundation

/// Text merge rules for files dropped onto the "Paste Link" tab (pure functions, testable).
enum OTPAuthTextDropResolver {
    /// Appends the dropped files' content to the current text, first removing path lines that point at the same files.
    static func resolvedText(
        currentText: String,
        droppedFileURL: URL,
        droppedFileText: String
    ) -> String {
        let cleanFileText = droppedFileText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanFileText.isEmpty else { return currentText }

        let filteredCurrentText = removingReferences(to: [droppedFileURL], from: currentText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if filteredCurrentText.isEmpty {
            return cleanFileText
        }
        return "\(filteredCurrentText)\n\(cleanFileText)"
    }

    /// Replaces every line that is a file path / file URL with the content read by `readFileText`.
    static func resolvedText(
        currentText: String,
        readFileText: (URL) -> String?
    ) -> String {
        currentText
            .components(separatedBy: .newlines)
            .map { line -> String in
                guard let url = fileURL(fromDroppedText: line),
                    let fileText = readFileText(url)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !fileText.isEmpty
                else {
                    return line
                }
                return fileText
            }
            .joined(separator: "\n")
    }

    /// Removes path lines pointing at these files: their content is already in the text, so paths the editor inserts afterwards
    /// are not expanded again.
    static func removingReferences(to urls: Set<URL>, from text: String) -> String {
        let standardized = Set(urls.map(\.standardizedFileURL))
        return
            text
            .components(separatedBy: .newlines)
            .filter { line in
                guard let candidate = fileURL(fromDroppedText: line) else { return true }
                return !standardized.contains(candidate.standardizedFileURL)
            }
            .joined(separator: "\n")
    }

    static func fileURL(fromDroppedText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.isFileURL {
            return url
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }
}
