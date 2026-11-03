@preconcurrency import AVFoundation
import CoreImage
import SwiftUI

/// Camera QR preview. Configuring the device and starting capture happen in the background (the system can take over a second to
/// start the camera, which must not block the UI); `onReady` fires when capture actually starts, and the caller shows a waiting
/// indicator until then.
///
/// The coordinator is on the main actor. The AVFoundation pipeline (`CameraPipeline`) is a `Sendable` object holding only immutable
/// and lock-protected state, and recognized content returns to the main actor through `@Sendable` callbacks.
struct QRCodeCameraScanner: NSViewRepresentable {
    var isActive: Bool
    var onResult: (OTPAuthScanResult) -> Void
    var onError: (QRScanError) -> Void
    var onReady: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult, onError: onError, onReady: onReady)
    }

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        context.coordinator.previewView = view
        context.coordinator.configureIfNeeded()
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        context.coordinator.onResult = onResult
        context.coordinator.onError = onError
        context.coordinator.onReady = onReady
        isActive ? context.coordinator.start() : context.coordinator.stop()
    }

    final class PreviewView: NSView {
        override var wantsUpdateLayer: Bool { true }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as? AVCaptureVideoPreviewLayer ?? AVCaptureVideoPreviewLayer()
        }

        override func makeBackingLayer() -> CALayer {
            AVCaptureVideoPreviewLayer()
        }
    }

    @MainActor
    final class Coordinator {
        var onResult: (OTPAuthScanResult) -> Void
        var onError: (QRScanError) -> Void
        var onReady: () -> Void
        weak var previewView: PreviewView?
        /// The background configure-and-start task; stopping is queued after it so it does not interleave with starting.
        private var startTask: Task<Void, Never>?
        private var pipeline: CameraPipeline?
        private var isConfigured = false
        private var hasResult = false
        private var seenMessages = Set<String>()
        /// Capture stops only once all migration codes are collected (rules in the shared `MigrationBatchCollector`).
        private var migrationBatches = MigrationBatchCollector()

        init(
            onResult: @escaping (OTPAuthScanResult) -> Void,
            onError: @escaping (QRScanError) -> Void,
            onReady: @escaping () -> Void
        ) {
            self.onResult = onResult
            self.onError = onError
            self.onReady = onReady
        }

        func configureIfNeeded() {
            guard !isConfigured else { return }
            isConfigured = true

            // The caller grants access before expanding the preview; this is only a fallback. Real configuration happens in the
            // background task in start().
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                break
            case .notDetermined:
                Task {
                    if await AVCaptureDevice.requestAccess(for: .video) {
                        start()
                    } else {
                        onError(.cameraPermission)
                    }
                }
            case .denied, .restricted:
                onError(.cameraPermission)
            @unknown default:
                onError(.cameraUnavailable)
            }
        }

        func start() {
            configureIfNeeded()
            guard startTask == nil, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
            let pipeline = self.pipeline ?? makePipeline()
            self.pipeline = pipeline
            guard !pipeline.isRunning else { return }
            hasResult = false
            pipeline.resetDetection()
            startTask = Task {
                let isRunning = await pipeline.configureAndStart()
                previewView?.videoPreviewLayer.session = pipeline.session
                startTask = nil
                if isRunning { onReady() }
            }
        }

        func stop() {
            guard let pipeline else { return }
            let pending = startTask
            Task {
                await pending?.value
                await pipeline.stop()
            }
        }

        private func makePipeline() -> CameraPipeline {
            CameraPipeline(
                onMessage: { [weak self] message in
                    Task { @MainActor in self?.handleMessage(message) }
                },
                onError: { [weak self] error in
                    Task { @MainActor in self?.onError(error) }
                }
            )
        }

        private func handleMessage(_ message: String) {
            guard !hasResult else { return }
            guard seenMessages.insert(message).inserted else { return }

            let result = OTPAuthParser.parseScanResult(message)
            guard result.hasValidAccounts else {
                // The QR code in front of the camera is readable but not a usable verification code; report each code only once.
                onError(.invalidQRCode)
                return
            }

            switch migrationBatches.add(result) {
            case .partial:
                // Migration codes not complete yet: hand this one to the UI to accumulate and keep capturing.
                onResult(result)
            case .complete:
                hasResult = true
                pipeline?.finishDetection()
                stop()
                onResult(result)
            }
        }
    }
}

/// AVFoundation capture pipeline. Configuration and start / stop run on a background thread (they block for over a second);
/// metadata callbacks arrive on the main queue, and sample buffer callbacks on the serial `DispatchQueue` AVFoundation requires
/// (`AVCaptureVideoDataOutput` accepts only a dispatch queue, so it cannot move to Swift concurrency). The only mutable state is
/// the lock-protected `isFinished` and the sample counter.
private final class CameraPipeline: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable
{
    /// AVCaptureSession is itself thread-safe; configuration and start / stop are serialized through `startTask`, and the preview
    /// layer reads it only on the main thread.
    nonisolated(unsafe) let session = AVCaptureSession()
    private let frameQueue = DispatchQueue(label: "kakey.qr.camera.frames")
    /// Used only on `frameQueue`.
    nonisolated(unsafe) private let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    private let isFinished = Locked(false)
    private let frameIndex = Locked(0)
    private let onMessage: @Sendable (String) -> Void
    private let onError: @Sendable (QRScanError) -> Void

    init(onMessage: @escaping @Sendable (String) -> Void, onError: @escaping @Sendable (QRScanError) -> Void) {
        self.onMessage = onMessage
        self.onError = onError
    }

    var isRunning: Bool { session.isRunning }

    func resetDetection() {
        isFinished.value = false
    }

    /// Stops decoding further frames once results are complete (sample callbacks may still be queued).
    func finishDetection() {
        isFinished.value = true
    }

    /// Configures and starts in the background; returns whether capture is running.
    func configureAndStart() async -> Bool {
        await Task.detached(priority: .userInitiated) { [self] in
            if configureSession(), !session.isRunning {
                session.startRunning()
            }
            return session.isRunning
        }.value
    }

    func stop() async {
        await Task.detached { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }.value
    }

    /// Called in the background. Returns whether capture can start.
    private func configureSession() -> Bool {
        guard session.inputs.isEmpty else { return true }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            onError(.cameraUnavailable)
            return false
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                onError(.cameraUnavailable)
                return false
            }
            session.addInput(input)
        } catch {
            onError(.cameraUnavailable)
            return false
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError(.cameraUnavailable)
            return false
        }

        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        }

        return true
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection
    ) {
        guard !isFinished.value else { return }
        let message =
            metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .first(where: { $0.type == .qr })?
            .stringValue

        guard let message else { return }
        onMessage(message)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isFinished.value else { return }
        let index = frameIndex.withLock { value -> Int in
            value += 1
            return value
        }
        guard index % 6 == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let messages = detector?.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString } ?? []
        guard let message = messages.first else { return }
        onMessage(message)
    }
}
