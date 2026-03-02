package com.waterclockdetection.detection

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.View

/**
 * Custom [View] that renders OBB detections as rotated bounding boxes.
 * Coordinate mapping matches ImageView's fitCenter scaleType.
 */
class ObbOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyle: Int = 0
) : View(context, attrs, defStyle) {

    private var detections: List<ObbDetection> = emptyList()
    // Uniform scale + offset to match ImageView fitCenter
    private var uniformScale: Float = 1f
    private var offsetX: Float = 0f
    private var offsetY: Float = 0f

    private val boxPaint = Paint().apply {
        color = Color.GREEN
        strokeWidth = 3f
        style = Paint.Style.STROKE
        isAntiAlias = true
    }

    private val textPaint = Paint().apply {
        color = Color.GREEN
        textSize = 36f
        isAntiAlias = true
    }

    private val textBgPaint = Paint().apply {
        color = Color.argb(160, 0, 0, 0)
        style = Paint.Style.FILL
    }

    /**
     * Set detections and compute fitCenter mapping from original image to view.
     */
    fun setDetections(detections: List<ObbDetection>, origW: Int, origH: Int) {
        if (origW <= 0 || origH <= 0 || width == 0 || height == 0) {
            this.detections = detections
            return
        }

        // Match ImageView fitCenter: uniform scale, centered
        val scaleX = width.toFloat() / origW
        val scaleY = height.toFloat() / origH
        uniformScale = minOf(scaleX, scaleY)
        offsetX = (width - origW * uniformScale) / 2f
        offsetY = (height - origH * uniformScale) / 2f

        this.detections = detections
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        for (det in detections) {
            drawObb(canvas, det)
        }
    }

    private fun drawObb(canvas: Canvas, det: ObbDetection) {
        // Map detection from original image space to view space (uniform scale)
        val corners = det.corners()

        // Transform all 4 corners: image coords → view coords
        for (i in corners.indices step 2) {
            corners[i] = corners[i] * uniformScale + offsetX
            corners[i + 1] = corners[i + 1] * uniformScale + offsetY
        }

        val path = Path().apply {
            moveTo(corners[0], corners[1])
            lineTo(corners[2], corners[3])
            lineTo(corners[4], corners[5])
            lineTo(corners[6], corners[7])
            close()
        }
        canvas.drawPath(path, boxPaint)

        drawLabel(canvas, det, corners)
    }

    private fun drawLabel(canvas: Canvas, det: ObbDetection, corners: FloatArray) {
        val label = "cls${det.classId} ${"%.2f".format(det.confidence)} ${"%.1f".format(det.angleDeg)}°"

        var minX = Float.MAX_VALUE
        var minY = Float.MAX_VALUE
        for (i in corners.indices step 2) {
            if (corners[i] < minX) minX = corners[i]
            if (corners[i + 1] < minY) minY = corners[i + 1]
        }
        minY -= 8f

        val textW = textPaint.measureText(label)
        val textH = textPaint.textSize

        canvas.drawRect(minX, minY - textH, minX + textW, minY, textBgPaint)
        canvas.drawText(label, minX, minY, textPaint)
    }
}
