//
//  Stability-gated auto capture for AVFoundation.
//
//  Attach to an AVCaptureVideoDataOutput; it watches the preview's luminance
//  and calls `onTrigger` when the frame has been steady and sharp for
//  `stableSamples` consecutive samples. The app then captures a full-res
//  photo (AVCapturePhotoOutput), scans it, and calls
//  `rearmAfterEmptyResult()` if no nutrition table was found.
//  See README.md for the full wiring example.
//

import AVFoundation
import CoreVideo
import Foundation

public final class AutoCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    public var onTrigger: () -> Void = {}
    public var onStatus: (String) -> Void = { _ in }

    public var stableSamples = 2
    /// Floor of the adaptive stillness threshold.
    public var motionStable = 10.0
    /// The adaptive stillness threshold never exceeds this.
    public var motionCeil = 25.0
    public var motionRearm = 30.0
    public var sharpnessMin = 8.0
    /// Sample rows that must look like text lines before capturing (0 disables).
    public var textRowsMin = 8
    public var textCrossings = 6
    public var textEdge: Float = 16
    public var maxAttempts = 6
    public var sampleEvery: TimeInterval = 0.25
    public var settle: TimeInterval = 1.0

    public private(set) var attempts = 0
    public var paused = false

    private let startedAt = Date()
    private var lastSampleAt = Date.distantPast
    private var previous: [Float]?
    private var stillCount = 0
    private var armed = true
    private var motionHistory: [Double] = []

    private let sampleWidth = 64
    private let sampleHeight = 48

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard !paused,
              now.timeIntervalSince(startedAt) >= settle,
              now.timeIntervalSince(lastSampleAt) >= sampleEvery,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lastSampleAt = now

        // Downsample the luma (Y) plane to 64x48. Requires a YpCbCr format,
        // which is AVCaptureVideoDataOutput's default on iOS.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var sample = [Float](repeating: 0, count: sampleWidth * sampleHeight)
        for y in 0..<sampleHeight {
            let srcY = y * height / sampleHeight
            for x in 0..<sampleWidth {
                let srcX = x * width / sampleWidth
                sample[y * sampleWidth + x] = Float(bytes[srcY * rowStride + srcX])
            }
        }

        var motion = 255.0
        if let previous {
            // Brightness-compensated diff: auto-exposure flicker isn't motion.
            var meanPrev: Float = 0
            var meanCur: Float = 0
            for i in 0..<sample.count { meanPrev += previous[i]; meanCur += sample[i] }
            meanPrev /= Float(sample.count)
            meanCur /= Float(sample.count)
            var sum = 0.0
            for i in 0..<sample.count {
                sum += Double(abs((sample[i] - meanCur) - (previous[i] - meanPrev)))
            }
            motion = sum / Double(sample.count)
        }
        previous = sample

        // Adaptive stillness bar: "still" means "close to the quietest this
        // session has been", clamped to [motionStable, motionCeil].
        motionHistory.append(motion)
        if motionHistory.count > 16 { motionHistory.removeFirst() }
        let stillBar = min(motionCeil, max(motionStable, (motionHistory.min() ?? motion) * 1.6))

        if !armed {
            if motion > motionRearm && attempts < maxAttempts {
                armed = true
                onStatus("Hold steady over the nutrition table…")
            }
            return
        }
        if motion >= stillBar {
            stillCount = 0
            onStatus("Hold the phone still…")
            return
        }

        var sharp = 0.0
        var count = 0
        var textRows = 0
        for y in 0..<(sampleHeight - 1) {
            var crossings = 0
            var prevSign = 0
            for x in 0..<(sampleWidth - 1) {
                let i = y * sampleWidth + x
                let dx = sample[i + 1] - sample[i]
                sharp += Double(abs(dx) + abs(sample[i] - sample[i + sampleWidth]))
                count += 1
                if abs(dx) >= textEdge {
                    let sign = dx > 0 ? 1 : -1
                    if prevSign != 0 && sign != prevSign { crossings += 1 }
                    prevSign = sign
                }
            }
            if crossings >= textCrossings { textRows += 1 }
        }
        if sharp / Double(count) < sharpnessMin {
            stillCount = 0
            onStatus("Too blurry — move closer or improve the light…")
            return
        }
        if textRowsMin > 0 && textRows < textRowsMin {
            stillCount = 0
            onStatus("Point at the nutrition table…")
            return
        }

        stillCount += 1
        onStatus("Hold steady…")
        if stillCount >= stableSamples {
            stillCount = 0
            attempts += 1
            paused = true // resume via rearmAfterEmptyResult()
            onTrigger()
        }
    }

    /// Call after a scan that found no table: waits for a deliberate reposition.
    public func rearmAfterEmptyResult() {
        armed = false
        paused = false
        onStatus(attempts >= maxAttempts
            ? "No nutrition table found — capture manually."
            : "No nutrition table found — aim at the label, then hold steady.")
    }
}
