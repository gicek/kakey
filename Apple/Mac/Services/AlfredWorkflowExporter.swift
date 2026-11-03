import AppKit
import Foundation

/// Opens `Kakey.alfredworkflow` (in `Contents/Resources/`, generated at build time by
/// `Apple/Mac/scripts/build-alfred-workflow.py` from `scripts/alfred/search.py`, `scripts/alfred/reveal.sh` and the app icon; see
/// the Makefile `alfred-workflow` target) and hands it to Alfred's own importer.
enum AlfredWorkflowExporter {
    enum ExportError: LocalizedError {
        case missingWorkflow

        var errorDescription: String? {
            L10n.tr("Workflow scripts are missing; the install may be corrupt")
        }
    }

    @MainActor
    static func exportAndOpen() throws {
        guard let workflowURL = Bundle.main.url(forResource: "Kakey", withExtension: "alfredworkflow") else {
            throw ExportError.missingWorkflow
        }
        NSWorkspace.shared.open(workflowURL)
    }
}
