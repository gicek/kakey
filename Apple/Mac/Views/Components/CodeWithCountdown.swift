import SwiftUI

/// Shared countdown rules for verification codes, used by list rows, cards, menu bar rows, details and the drag preview.
enum CodeCountdown {
    /// The ring turns red when this many seconds or fewer remain.
    static let urgentSeconds = 5

    /// Ticks once per second aligned to whole seconds; every row / card shares the same fixed origin, so rebuilding the parent does
    /// not reset the beat.
    static let tickSchedule = PeriodicTimelineSchedule(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)

    /// A pausable tick: while paused it yields only the starting frame and never refreshes. The menu bar panel content stays alive
    /// and is paused through `codeCountdownPaused` when hidden; otherwise every row in the hidden panel would recompute and relayout
    /// every second.
    struct TickSchedule: TimelineSchedule {
        var paused: Bool

        func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
            if paused {
                var emitted = false
                return AnyIterator {
                    guard !emitted else { return nil }
                    emitted = true
                    return startDate
                }
            }
            var ticks = CodeCountdown.tickSchedule.entries(from: startDate, mode: mode).makeIterator()
            return AnyIterator { ticks.next() }
        }
    }

    static func isUrgent(_ account: Account, at date: Date) -> Bool {
        TOTPService.secondsRemaining(for: account, date: date) <= urgentSeconds
    }
}

/// Verification code and countdown ring. Each instance owns its own whole-second `TimelineView`, so only this small piece refreshes
/// every second and the rest of the row / card does not. The list does not host a shared timer (rebuilding would reset it, and the
/// whole screen would redraw every second).
struct CodeWithCountdown: View {
    enum Layout {
        /// Code right-aligned at a fixed width, "Copied" in the empty space to its left, 28 pt ring.
        case listRow
        /// Code left-aligned, "Copied" in the empty space to its right, 20 pt ring at the end of the row.
        case card
        /// Compact: "Copied" replaces the code in place, 20 pt ring.
        case menuBarRow
        /// Details: large code, with a small ring and "Refreshes in N s" on the next line.
        case detail
    }

    var account: Account
    var isCopied: Bool
    var layout: Layout
    /// Static rendering such as the drag preview: draws a fixed moment without a timeline.
    var frozenAt: Date? = nil

    @Environment(\.codeCountdownPaused) private var paused

    var body: some View {
        if let frozenAt {
            content(at: frozenAt)
        } else {
            TimelineView(CodeCountdown.TickSchedule(paused: paused)) { context in
                content(at: context.date)
            }
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        switch layout {
        case .listRow:
            HStack(spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    if isCopied {
                        copiedLabel(fontSize: 12)
                    }
                    code(at: date, fontSize: 19)
                        .frame(width: 118, alignment: .trailing)
                }
                .animation(.easeOut(duration: 0.12), value: isCopied)
                ring(at: date, size: 28)
            }
        case .card:
            HStack(spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    code(at: date, fontSize: 21)
                    if isCopied {
                        copiedLabel(fontSize: 12)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isCopied)
                Spacer(minLength: 8)
                ring(at: date, size: 20)
            }
        case .menuBarRow:
            HStack(spacing: 10) {
                Text(TOTPService.formattedCode(for: account, date: date))
                    .font(CodeFont.font(size: 14))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(isCopied ? 0 : 1)
                    .frame(width: 84, alignment: .trailing)
                    .overlay(alignment: .trailing) {
                        if isCopied {
                            copiedLabel(fontSize: 11.5)
                        }
                    }
                ring(at: date, size: 20)
            }
        case .detail:
            VStack(alignment: .trailing, spacing: 3) {
                // "Copied" sits left of the code, aligned on the last baseline, without covering the code.
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    if isCopied {
                        copiedLabel(fontSize: 13)
                    }
                    code(at: date, fontSize: 26)
                }
                HStack(spacing: 5) {
                    ring(at: date, size: 12)
                    // Reserve two digits' width with monospaced digits: the text width stays constant as seconds tick (including
                    // 10 -> 9), so the ring does not jump sideways.
                    ZStack(alignment: .trailing) {
                        Text(L10n.format("Refreshes in %llds", 88)).hidden()
                        Text(L10n.format("Refreshes in %llds", TOTPService.secondsRemaining(for: account, date: date)))
                    }
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isCopied)
        }
    }

    /// The code never compresses; when space is short only the hint truncates, so the code never moves.
    private func code(at date: Date, fontSize: CGFloat) -> some View {
        Text(TOTPService.formattedCode(for: account, date: date))
            .font(CodeFont.font(size: fontSize))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private func ring(at date: Date, size: CGFloat) -> some View {
        CodeRing(
            progress: TOTPService.progress(for: account, date: date),
            isLow: CodeCountdown.isUrgent(account, at: date),
            size: size
        )
    }

    private func copiedLabel(fontSize: CGFloat) -> some View {
        Label(L10n.tr("Copied"), systemImage: "checkmark")
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.green)
            .lineLimit(1)
            .fixedSize()
            .transition(.opacity)
    }
}

private struct CodeCountdownPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true, the code and countdown freeze on the current frame (used while the host is invisible; see
    /// `CodeCountdown.TickSchedule`).
    var codeCountdownPaused: Bool {
        get { self[CodeCountdownPausedKey.self] }
        set { self[CodeCountdownPausedKey.self] = newValue }
    }
}
