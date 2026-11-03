import SwiftUI

struct AccountQRCodeView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    var account: Account
    @State private var didCopy = false
    /// How long the "Copied" feedback stays. It does not hide a code here, so it can stay longer than
    /// `VaultStore.copiedFeedbackDuration`.
    private static let copiedFeedbackDuration: Duration = .seconds(1.1)

    private var uri: String {
        OTPAuthCanonicalizer.otpauthURLString(for: account)
    }

    private var qrImage: NSImage? {
        QRCodeService.image(for: uri, scale: 12)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(account.issuer)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    Text(account.username)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 250, height: 250)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Text(uri)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .kakeyInputChrome(cornerRadius: 7)

                Button {
                    copyURI()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 18, height: 18)
                        Text(didCopy ? L10n.tr("Copied") : L10n.tr("Copy URI"))
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(width: 126, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(width: 154, height: 42)
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 22)

            FloatingSheetCloseButton {
                dismiss()
            }
            .padding(14)
        }
    }

    /// Contains the full secret: written through the store's concealed / transient pasteboard path and cleared after 60 seconds.
    private func copyURI() {
        store.copySecretURI(for: account)
        didCopy = true
        Task {
            try? await Task.sleep(for: Self.copiedFeedbackDuration)
            didCopy = false
        }
    }
}
