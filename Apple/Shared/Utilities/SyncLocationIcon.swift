import SwiftUI

/// Icon tile for a backup location. iCloud and cloud storage providers use their brand marks in original colors (exported
/// from design/brands by scripts/export-brand-icons.py); generic locations such as folders and WebDAV use an SF Symbol in
/// the accent color. The plate is a neutral light gray so brand colors never mix with the accent color. Shared by the
/// location lists, connection screens and status cards on Mac and iOS.
struct SyncLocationIcon: View {
    enum Kind: Equatable {
        case iCloud
        case folder
        case provider(CloudProvider)
        /// A Kakey export file (in the iOS first-time restore location list).
        case exportFile
    }

    var kind: Kind
    var size: CGFloat = 32
    /// The plate; callers placing the icon on a white card next to the app icon swap in that same background.
    var plate: AnyShapeStyle = AnyShapeStyle(.quaternary.opacity(0.6))
    /// When set, brand marks and symbols are both drawn in this color (iOS location list); when nil, brand marks keep their
    /// original colors and symbols use the accent color.
    var tint: Color?

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .background(plate, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if let asset {
            Image(asset, bundle: AppResourceBundle.bundle)
                .renderingMode(tint == nil ? .original : .template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.62, height: size * 0.62)
                .foregroundStyle(tint ?? Color.accentColor)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.5))
                .foregroundStyle(tint ?? Color.accentColor)
        }
    }

    private var asset: String? {
        switch kind {
        case .iCloud: "Brand-iCloud"
        case .provider(.dropbox): "Brand-Dropbox"
        case .provider(.oneDrive): "Brand-OneDrive"
        case .provider(.googleDrive): "Brand-GoogleDrive"
        case .provider(.nextcloud): "Brand-Nextcloud"
        case .folder, .exportFile, .provider(.webDAV): nil
        }
    }

    private var symbol: String {
        switch kind {
        case .folder: "folder.fill"
        case .exportFile: "doc.fill"
        default: "server.rack"
        }
    }
}

extension SyncLocation {
    var iconKind: SyncLocationIcon.Kind {
        switch self {
        case .iCloud: .iCloud
        case .folder: .folder
        case .cloud(let location): .provider(location.provider)
        }
    }
}
