/**
 * Viewfinder overlay: corner brackets, animated scan line + "Analyzing
 * label…" while scanning, status text, and a flash toggle. Add it over your
 * CameraX PreviewView (e.g. as a sibling in a FrameLayout). Every element is
 * configurable; setting [isVisible] false renders nothing.
 *
 * Flash wiring: overlay exposes the button + state; the app applies it with
 * `camera.cameraControl.enableTorch(on)` in [onToggleFlash].
 */
package com.foodcore.nutritionscanner

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.Gravity
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.ImageButton
import android.graphics.drawable.GradientDrawable

class ScannerOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {

    /** Corner-bracket framing box. */
    var showBrackets = true
        set(value) { field = value; invalidate() }

    /** Flash button (shown by default; hide by setting false). */
    var showFlashButton = true
        set(value) { field = value; flashButton.visibility = if (value) VISIBLE else GONE }

    var analyzingText = "Analyzing label…"

    /** Called when the user taps the flash button; apply with
     *  camera.cameraControl.enableTorch(on). */
    var onToggleFlash: ((on: Boolean) -> Unit)? = null

    private var analyzing = false
    private var scanY = 0f
    private var flashOn = false

    private val bracketPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        alpha = 235
        strokeWidth = 3f * resources.displayMetrics.density
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        alpha = 242
        strokeWidth = 2f * resources.displayMetrics.density
        setShadowLayer(8f, 0f, 0f, Color.WHITE)
    }

    private val statusView = TextView(context).apply {
        setTextColor(Color.WHITE)
        textSize = 15f
        gravity = Gravity.CENTER_HORIZONTAL
        setShadowLayer(4f, 0f, 1f, Color.argb(217, 0, 0, 0))
    }
    private val flashButton = ImageButton(context).apply {
        setImageResource(android.R.drawable.ic_menu_camera) // replace with a flash icon in your app
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.argb(115, 0, 0, 0))
        }
        contentDescription = "Toggle flash"
        setOnClickListener {
            flashOn = !flashOn
            (background as GradientDrawable).setColor(
                if (flashOn) Color.argb(235, 255, 255, 255) else Color.argb(115, 0, 0, 0)
            )
            onToggleFlash?.invoke(flashOn)
        }
    }

    private val scanAnimator = ValueAnimator.ofFloat(0.08f, 0.9f).apply {
        duration = 2200
        repeatMode = ValueAnimator.REVERSE
        repeatCount = ValueAnimator.INFINITE
        interpolator = AccelerateDecelerateInterpolator()
        addUpdateListener { scanY = it.animatedValue as Float; invalidate() }
    }

    init {
        setWillNotDraw(false)
        val density = resources.displayMetrics.density
        addView(statusView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.BOTTOM
            bottomMargin = (16 * density).toInt()
            leftMargin = (16 * density).toInt()
            rightMargin = (16 * density).toInt()
        })
        addView(flashButton, LayoutParams((42 * density).toInt(), (42 * density).toInt()).apply {
            gravity = Gravity.TOP or Gravity.END
            topMargin = (10 * density).toInt()
            rightMargin = (10 * density).toInt()
        })
    }

    /** Update the guidance line ("Hold steady…"). */
    fun setStatus(message: String) {
        if (!analyzing) statusView.text = message
    }

    /** Toggle the analyzing state: animated scan line + analyzingText. */
    fun setAnalyzing(on: Boolean) {
        analyzing = on
        if (on) {
            statusView.text = analyzingText
            scanAnimator.start()
        } else {
            scanAnimator.cancel()
        }
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (showBrackets) {
            val insetX = w * 0.06f
            val insetY = h * 0.06f
            val arm = minOf(w, h) * 0.09f
            fun corner(x: Float, y: Float, dx: Float, dy: Float) {
                canvas.drawLine(x, y, x + arm * dx, y, bracketPaint)
                canvas.drawLine(x, y, x, y + arm * dy, bracketPaint)
            }
            corner(insetX, insetY, 1f, 1f)
            corner(w - insetX, insetY, -1f, 1f)
            corner(insetX, h - insetY, 1f, -1f)
            corner(w - insetX, h - insetY, -1f, -1f)
        }
        if (analyzing) {
            val y = h * scanY
            canvas.drawLine(w * 0.08f, y, w * 0.92f, y, linePaint)
        }
    }
}
