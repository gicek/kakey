import CoreImage.CIFilterBuiltins
import SwiftUI

/// App brand mark (lock shield on a transparent background), used on the lock screen, onboarding, and privacy cover.
struct BrandMark: View {
    var size: CGFloat

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Service initial badge; the core picks the color from the issuer so all three platforms match.
struct MonogramBadge: View {
    var issuer: String
    var size: CGFloat = 40

    var body: some View {
        let color = Account.color(for: issuer)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(Account.monogram(for: issuer))
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
            .accessibilityHidden(true)
    }
}

/// Ring showing the time left in the current period; turns orange for the last 5 seconds.
struct CountdownRing: View {
    var progress: Double
    var secondsRemaining: Int
    var size: CGFloat = 22

    var body: some View {
        let urgent = secondsRemaining <= 5
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(urgent ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
            Text("\(secondsRemaining)")
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(urgent ? Color.orange : Color.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(L10n.format("Refreshes in %llds", secondsRemaining))
    }
}

/// Large monospaced verification code with a gap in the middle.
struct CodeText: View {
    var code: String
    var urgent: Bool
    var font: Font = CodeFont.font(size: 20, relativeTo: .title3)

    var body: some View {
        Text(TOTPService.formatted(code: code))
            .font(font)
            .monospacedDigit()
            // The code always stays on one line; when space runs short the service name is compressed, not the code
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(urgent ? Color.orange : Color.primary)
            .contentTransition(.numericText())
            .accessibilityLabel(code.map(String.init).joined(separator: " "))
    }
}

enum QRCodeImage {
    /// QR code for an otpauth URI (CoreImage, generated on device).
    static func make(from text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Password strength bar (rules live in the core's `password.rs`).
struct PasswordStrengthBar: View {
    var password: String

    var body: some View {
        let strength = PasswordStrength.evaluate(password)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(1...4, id: \.self) { index in
                    Capsule()
                        .fill(index <= strength.rawValue ? color(for: strength) : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                }
            }
            Text(strength.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.2), value: strength)
    }

    private func color(for strength: PasswordStrength) -> Color {
        switch strength {
        case .empty, .weak: .red
        case .fair: .orange
        case .good, .strong: .green
        }
    }
}
