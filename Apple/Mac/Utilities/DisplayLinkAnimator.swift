import AppKit
import QuartzCore

/// Drives a timed animation from screen refresh callbacks: each frame reports normalized progress 0...1 (0 on the first frame,
/// 1 on the last) and ends early if the enclosing task is cancelled.
@MainActor
final class DisplayLinkAnimator: NSObject {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Never>?
    private var startTime: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var frame: (@MainActor (Double) -> Void)?

    static func run(duration: TimeInterval, frame: @escaping @MainActor (Double) -> Void) async {
        await DisplayLinkAnimator().start(duration: duration, frame: frame)
    }

    private func start(duration: TimeInterval, frame: @escaping @MainActor (Double) -> Void) async {
        self.duration = max(duration, 0.001)
        self.frame = frame
        startTime = CACurrentMediaTime()
        frame(0)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            frame(1)
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                link.add(to: .main, forMode: .common)
            }
        } onCancel: {
            Task { @MainActor in self.finish() }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let progress = min(max((CACurrentMediaTime() - startTime) / duration, 0), 1)
        frame?(progress)
        if progress >= 1 {
            finish()
        }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        frame = nil
        continuation?.resume()
        continuation = nil
    }
}
