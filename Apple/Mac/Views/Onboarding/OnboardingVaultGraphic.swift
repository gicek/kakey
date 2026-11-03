import SwiftUI

/// Horizontal graphic at the top of the onboarding sidebar: a 6-digit code on the left whose digits scramble into ciphertext one by
/// one and flow along a thin line into the app icon on the right; the icon glows briefly and the next code starts. It shows "codes are
/// encrypted into Kakey" at a glance. Purely decorative and hidden from VoiceOver; with Reduce Motion it draws a single static frame.
/// Driven by `TimelineView`: each frame's state is computed from the time alone, with no stored animation state.
struct OnboardingVaultGraphic: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cycle: Double = 3.6
    private static let iconSize: CGFloat = 64

    var body: some View {
        Group {
            if reduceMotion {
                frame(at: 0.4)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    frame(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(height: Self.iconSize)
        .accessibilityHidden(true)
    }

    private func frame(at time: Double) -> some View {
        let round = Int(time / Self.cycle)
        let phase = Phase(t: time.truncatingRemainder(dividingBy: Self.cycle))
        return HStack(spacing: 0) {
            codeCard(digits: Self.code(for: phase.showsNextCode ? round + 1 : round), phase: phase, time: time)
            connector(phase: phase)
            Image(nsImage: KakeyAssets.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .scaleEffect(1 + 0.05 * phase.arrival)
                .shadow(color: Color.accentColor.opacity(0.35 * phase.arrival), radius: 12)
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        }
    }

    // MARK: - Code

    private func codeCard(digits: [Int], phase: Phase, time: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                glyph(for: digits[index], index: index, phase: phase, time: time)
                    .frame(width: 11)
                if index == 2 {
                    Spacer().frame(width: 5)
                }
            }
        }
        .font(.system(size: 17, weight: .semibold, design: .monospaced))
        .opacity(phase.codeOpacity)
        .padding(.horizontal, 9)
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
    }

    /// Each digit: plain text -> briefly scrolling hex noise -> ciphertext dot.
    @ViewBuilder
    private func glyph(for digit: Int, index: Int, phase: Phase, time: Double) -> some View {
        switch phase.state(ofDigit: index) {
        case .plain:
            Text(verbatim: "\(digit)").foregroundStyle(.primary)
        case .scrambling:
            let tick = Int(time * 18) &+ index &* 7
            Text(verbatim: String(Self.hex[abs(tick) % Self.hex.count])).foregroundStyle(Color.accentColor)
        case .sealed:
            Text(verbatim: "•").foregroundStyle(.tertiary)
        }
    }

    // MARK: - Line and ciphertext flow

    private func connector(phase: Phase) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(nsColor: .separatorColor).opacity(0.4), Color.accentColor.opacity(0.45)],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(height: 1.5)
                ForEach(0..<4, id: \.self) { index in
                    let progress = phase.transfer - Double(index) * 0.16
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 3)
                        .offset(x: max(0, min(1, progress)) * (width - 7))
                        .opacity(progress > 0 && progress < 1 ? sin(progress * .pi) : 0)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Timeline

    /// Segments of one cycle: 0-0.9 s shows the plain code; from 0.9 s the digits scramble one by one and turn into dots; 1.6-2.7 s
    /// the ciphertext flows into the icon; 2.5-3.0 s the icon glows; from 3.0 s the dots fade out and the next code fades in.
    private struct Phase {
        enum DigitState { case plain, scrambling, sealed }

        let t: Double

        func state(ofDigit index: Int) -> DigitState {
            guard !showsNextCode else { return .plain }
            let start = 0.9 + Double(index) * 0.1
            if t < start { return .plain }
            return t < start + 0.32 ? .scrambling : .sealed
        }

        var transfer: Double { (t - 1.6) / 1.1 }

        var arrival: Double {
            let x = (t - 2.5) / 0.5
            return x > 0 && x < 1 ? sin(x * .pi) : 0
        }

        var showsNextCode: Bool { t >= 3.3 }

        var codeOpacity: Double {
            if t >= 3.0 && t < 3.3 { return 1 - (t - 3.0) / 0.3 * 0.6 }
            if t >= 3.3 { return 0.4 + (t - 3.3) / 0.3 * 0.6 }
            return 1
        }
    }

    private static let hex = Array("0123456789ABCDEF")

    /// A fixed "code" per round: illustration only, unrelated to any account.
    private static func code(for round: Int) -> [Int] {
        var state = UInt64(truncatingIfNeeded: round) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<6).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % 10)
        }
    }
}
