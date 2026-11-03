import AppKit

/// Flight animation between the permission row and the guide card: a parabola with an apex crossfade and bell-shaped blur; the
/// stand-in window advances frame by frame with the screen refresh. The curve functions are pure.
@MainActor
enum PermissionGuideFlight {
    /// - Parameter onApex: Called once on reaching the apex (t >= 0.5); the reverse flight uses it to restore the permission row while
    ///   the stand-in covers it.
    static func run(
        replicant: FlightReplicantWindow,
        from sourceFrame: NSRect,
        to targetFrame: NSRect,
        sourceImage: NSImage?,
        targetImage: NSImage?,
        reversed: Bool,
        onApex: @escaping @MainActor () -> Void
    ) async {
        replicant.model.sourceImage = sourceImage
        replicant.model.targetImage = targetImage

        let rowCornerRadius: CGFloat = 12
        let cardCornerRadius = ScreenCaptureGuideView.cardCornerRadius
        let duration: TimeInterval = reversed ? 0.6 : 0.78
        let maxBlur: CGFloat = 12
        let arcHeight: CGFloat = 160
        var apexReached = false

        replicant.apply(
            frame: reversed ? targetFrame : sourceFrame,
            cornerRadius: reversed ? cardCornerRadius : rowCornerRadius,
            progress: reversed ? 1 : 0,
            shadowOpacity: reversed ? 1 : 0,
            blurRadius: 0
        )
        replicant.orderFrontRegardless()

        // Advance frame by frame with screen refresh callbacks.
        await DisplayLinkAnimator.run(duration: duration) { t in
            let eased = easeInOutCubic(t)
            let progress = reversed ? 1 - eased : eased

            if !apexReached, t >= 0.5 {
                apexReached = true
                onApex()
            }

            let center = parabolicPoint(
                t: progress,
                start: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
                end: CGPoint(x: targetFrame.midX, y: targetFrame.midY),
                arcHeight: arcHeight
            )
            let width = sourceFrame.width + (targetFrame.width - sourceFrame.width) * progress
            let height = sourceFrame.height + (targetFrame.height - sourceFrame.height) * progress
            let crossfade = apexCrossfade(t)

            replicant.apply(
                frame: NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
                cornerRadius: rowCornerRadius + (cardCornerRadius - rowCornerRadius) * progress,
                progress: reversed ? 1 - crossfade : crossfade,
                shadowOpacity: progress,
                blurRadius: bellBlur(t) * maxBlur
            )
        }
    }

    static func parabolicPoint(t: CGFloat, start: CGPoint, end: CGPoint, arcHeight: CGFloat) -> CGPoint {
        let control = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + arcHeight)
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }

    /// Bell-shaped blur curve: 0 at both ends, maximum at the apex of the parabola.
    static func bellBlur(_ t: CGFloat) -> CGFloat {
        4 * t * (1 - t)
    }

    /// A smooth crossfade concentrated around the apex: the first 35% keeps the source image, the middle 30% switches, and the last
    /// 35% keeps the target image.
    static func apexCrossfade(_ t: CGFloat) -> CGFloat {
        if t < 0.35 { return 0 }
        if t > 0.65 { return 1 }
        let local = (t - 0.35) / 0.3
        return local * local * (3 - 2 * local)
    }

    static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
