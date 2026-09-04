/**
 * Stability-gated auto capture for CameraX.
 *
 * Attach as an ImageAnalysis.Analyzer; it watches the preview's luminance
 * plane and invokes [onTrigger] when the frame has been steady and sharp for
 * [stableSamples] consecutive samples. The app then takes a full-res photo
 * with ImageCapture, scans it, and calls [rearmAfterEmptyResult] if the scan
 * found no nutrition table. See README.md for the wiring example.
 */
package com.foodcore.nutritionscanner

import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import kotlin.math.abs

class AutoCaptureAnalyzer(
    private val onTrigger: () -> Unit,
    private val onStatus: (String) -> Unit = {},
    private val stableSamples: Int = 2,
    /** Floor of the adaptive stillness threshold. */
    private val motionStable: Double = 10.0,
    /** The adaptive stillness threshold never exceeds this. */
    private val motionCeil: Double = 25.0,
    private val motionRearm: Double = 30.0,
    private val sharpnessMin: Double = 8.0,
    /** Sample rows that must look like text lines before capturing (0 disables). */
    private val textRowsMin: Int = 8,
    private val textCrossings: Int = 6,
    private val textEdge: Double = 16.0,
    private val maxAttempts: Int = 6,
    private val sampleEveryMs: Long = 250,
    private val settleMs: Long = 1000,
) : ImageAnalysis.Analyzer {

    private val startedAt = System.currentTimeMillis()
    private var lastSampleAt = 0L
    private var previous: FloatArray? = null
    private var stillCount = 0
    private var armed = true
    private val motionHistory = ArrayDeque<Double>()

    @Volatile var paused = false
    @Volatile var attempts = 0
        private set

    private companion object {
        const val W = 64
        const val H = 48
    }

    override fun analyze(image: ImageProxy) {
        try {
            val now = System.currentTimeMillis()
            if (paused || now - startedAt < settleMs || now - lastSampleAt < sampleEveryMs) return
            lastSampleAt = now

            // Downsample the Y plane to 64x48.
            val plane = image.planes[0]
            val buffer = plane.buffer
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val sample = FloatArray(W * H)
            for (y in 0 until H) {
                val srcY = y * image.height / H
                for (x in 0 until W) {
                    val srcX = x * image.width / W
                    val index = srcY * rowStride + srcX * pixelStride
                    sample[y * W + x] = (buffer.get(index).toInt() and 0xFF).toFloat()
                }
            }

            // Brightness-compensated diff: auto-exposure flicker isn't motion.
            val motion = previous?.let { prev ->
                var meanPrev = 0.0
                var meanCur = 0.0
                for (i in sample.indices) { meanPrev += prev[i]; meanCur += sample[i] }
                meanPrev /= sample.size
                meanCur /= sample.size
                var sum = 0.0
                for (i in sample.indices) sum += abs(sample[i] - meanCur - (prev[i] - meanPrev))
                sum / sample.size
            } ?: 255.0
            previous = sample

            // Adaptive stillness bar: "still" means "close to the quietest
            // this session has been", clamped to [motionStable, motionCeil].
            motionHistory.addLast(motion)
            if (motionHistory.size > 16) motionHistory.removeFirst()
            val stillBar = minOf(motionCeil, maxOf(motionStable, motionHistory.min() * 1.6))

            if (!armed) {
                if (motion > motionRearm && attempts < maxAttempts) {
                    armed = true
                    onStatus("Hold steady over the nutrition table…")
                }
                return
            }
            if (motion >= stillBar) {
                stillCount = 0
                onStatus("Hold the phone still…")
                return
            }

            var sharp = 0.0
            var n = 0
            var textRows = 0
            for (y in 0 until H - 1) {
                var crossings = 0
                var prevSign = 0
                for (x in 0 until W - 1) {
                    val i = y * W + x
                    val dx = sample[i + 1] - sample[i]
                    sharp += abs(dx) + abs(sample[i] - sample[i + W])
                    n++
                    if (abs(dx) >= textEdge) {
                        val sign = if (dx > 0) 1 else -1
                        if (prevSign != 0 && sign != prevSign) crossings++
                        prevSign = sign
                    }
                }
                if (crossings >= textCrossings) textRows++
            }
            if (sharp / n < sharpnessMin) {
                stillCount = 0
                onStatus("Too blurry — move closer or improve the light…")
                return
            }
            if (textRowsMin > 0 && textRows < textRowsMin) {
                stillCount = 0
                onStatus("Point at the nutrition table…")
                return
            }

            stillCount++
            onStatus("Hold steady…")
            if (stillCount >= stableSamples) {
                stillCount = 0
                attempts++
                paused = true // resume via rearmAfterEmptyResult()
                onTrigger()
            }
        } finally {
            image.close()
        }
    }

    /** Call after a scan that found no table: waits for a deliberate reposition. */
    fun rearmAfterEmptyResult() {
        armed = false
        paused = false
        onStatus(
            if (attempts >= maxAttempts) "No nutrition table found — capture manually."
            else "No nutrition table found — aim at the label, then hold steady."
        )
    }
}
