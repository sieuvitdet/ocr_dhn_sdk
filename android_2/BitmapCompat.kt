/**
 * BitmapCompat.kt — Desktop JVM bridge for the TFLite OBB detection pipeline.
 *
 * Mirrors the logic of the Android detection classes:
 *   - BitmapPreprocessor → BitmapCompat.letterbox / toByteBuffer
 *   - ObbPostProcessor   → BitmapCompat.parseNmsObb
 *   - ObbDetection       → ObbDetection (data class here)
 *   - LetterboxMeta      → LetterboxMeta (data class here)
 *
 * Uses java.awt.image.BufferedImage instead of android.graphics.Bitmap so this
 * runs on desktop JVM (Mac/Linux/Windows) without an Android runtime.
 *
 * Python equivalents (test_models.py):
 *   letterbox()       → BitmapCompat.letterbox()
 *   parse_nms_obb()   → BitmapCompat.parseNmsObb()
 *   draw_obb_results() → BitmapCompat.drawObbResults()
 *
 * Build requirement: no extra dependencies beyond JDK (javax.imageio is in the JDK).
 */
package com.waterclockdetection.test

import java.awt.BasicStroke
import java.awt.Color
import java.awt.Font
import java.awt.RenderingHints
import java.awt.geom.GeneralPath
import java.awt.image.BufferedImage
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

// ── Data Classes ──────────────────────────────────────────────────────────────

/**
 * Metadata captured during letterbox preprocessing.
 *
 * Mirrors [com.waterclockdetection.detection.LetterboxMeta] for desktop JVM.
 * Used to invert the letterbox transform in [BitmapCompat.parseNmsObb].
 *
 * @param scale      Uniform resize scale (= min(targetSize/origH, targetSize/origW))
 * @param padTop     Top gray-padding pixels in the 640x640 letterboxed space
 * @param padLeft    Left gray-padding pixels in the 640x640 letterboxed space
 * @param origWidth  Source image width in pixels
 * @param origHeight Source image height in pixels
 */
data class LetterboxMeta(
    val scale: Float,
    val padTop: Int,
    val padLeft: Int,
    val origWidth: Int,
    val origHeight: Int
)

/**
 * Single OBB detection result in ORIGINAL image coordinate space.
 *
 * Mirrors [com.waterclockdetection.detection.ObbDetection] for desktop JVM.
 *
 * @param classId    Integer class index from model output field [5]
 * @param confidence 0.0–1.0 confidence score from model output field [4]
 * @param cx         Center X in original image pixels
 * @param cy         Center Y in original image pixels
 * @param width      Box width in original image pixels
 * @param height     Box height in original image pixels
 * @param angleDeg   Rotation angle in degrees (converted from model's angle_rad field [6])
 */
data class ObbDetection(
    val classId: Int,
    val confidence: Float,
    val cx: Float,
    val cy: Float,
    val width: Float,
    val height: Float,
    val angleDeg: Float
) {
    /**
     * Compute the 4 corner points of the rotated bounding box.
     *
     * Mirrors the Android [ObbDetection.corners()] implementation exactly.
     * Equivalent to cv2.boxPoints((cx, cy), (w, h), angle) in Python.
     *
     * @return FloatArray of 8 floats: [x0,y0, x1,y1, x2,y2, x3,y3]
     *         in order: top-right, top-left, bottom-left, bottom-right
     */
    fun corners(): FloatArray {
        val rad  = Math.toRadians(angleDeg.toDouble())
        val cosA = Math.cos(rad).toFloat()
        val sinA = Math.sin(rad).toFloat()
        val hw = width  / 2f
        val hh = height / 2f

        val dx1 = cosA * hw;  val dy1 = sinA * hw  // along width axis
        val dx2 = sinA * hh;  val dy2 = cosA * hh  // along height axis (perpendicular)

        return floatArrayOf(
            cx + dx1 - dx2, cy + dy1 - dy2,   // top-right
            cx - dx1 - dx2, cy - dy1 - dy2,   // top-left
            cx - dx1 + dx2, cy - dy1 + dy2,   // bottom-left
            cx + dx1 + dx2, cy + dy1 + dy2    // bottom-right
        )
    }
}

// ── BitmapCompat ──────────────────────────────────────────────────────────────

/**
 * Desktop JVM image processing utilities for the TFLite OBB detection pipeline.
 *
 * Provides the same preprocessing, postprocessing, and rendering as the Android
 * detection classes, using java.awt APIs instead of android.graphics.
 */
object BitmapCompat {

    const val INPUT_SIZE = 640

    // Buffer size: 1 × 640 × 640 × 3 channels × 4 bytes (float32)
    private const val BUFFER_SIZE = INPUT_SIZE * INPUT_SIZE * 3 * 4

    private const val OUTPUT_FIELDS = 7

    // Letterbox fill color: RGB(114, 114, 114) — matches Python default
    private val PAD_COLOR = Color(114, 114, 114)

    // Field indices within each detection row [x, y, w, h, conf, cls, angle_rad]
    private const val IDX_X     = 0
    private const val IDX_Y     = 1
    private const val IDX_W     = 2
    private const val IDX_H     = 3
    private const val IDX_CONF  = 4
    private const val IDX_CLS   = 5
    private const val IDX_ANGLE = 6

    /**
     * Apply letterbox padding to [src] and return a 640×640 [BufferedImage] with [LetterboxMeta].
     *
     * The source image is scaled uniformly (preserving aspect ratio) to fit within INPUT_SIZE,
     * and the remaining area is filled with gray (114, 114, 114) — matching the Python default.
     *
     * Python equivalent:
     *   padded, scale, top, left, h0, w0 = letterbox(img_bgr, 640)
     *
     * @param src Source image of any dimension.
     * @return Pair of (640×640 letterboxed image, LetterboxMeta for inverse coordinate transform).
     */
    fun letterbox(src: BufferedImage): Pair<BufferedImage, LetterboxMeta> {
        val origW = src.width
        val origH = src.height

        val scale  = minOf(INPUT_SIZE.toFloat() / origH, INPUT_SIZE.toFloat() / origW)
        val newW   = (origW * scale).toInt()
        val newH   = (origH * scale).toInt()
        val padTop  = (INPUT_SIZE - newH) / 2
        val padLeft = (INPUT_SIZE - newW) / 2

        val padded = BufferedImage(INPUT_SIZE, INPUT_SIZE, BufferedImage.TYPE_INT_RGB)
        val g = padded.createGraphics()
        g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR)

        // Fill with gray pad color
        g.color = PAD_COLOR
        g.fillRect(0, 0, INPUT_SIZE, INPUT_SIZE)

        // Draw source image scaled and centered
        // drawImage(img, dx1, dy1, dx2, dy2, sx1, sy1, sx2, sy2, observer)
        g.drawImage(src, padLeft, padTop, padLeft + newW, padTop + newH, 0, 0, origW, origH, null)
        g.dispose()

        val meta = LetterboxMeta(scale, padTop, padLeft, origW, origH)
        return Pair(padded, meta)
    }

    /**
     * Convert a 640×640 letterboxed [BufferedImage] to a float32 NHWC [ByteBuffer] for TFLite.
     *
     * Output layout: [R, G, B, R, G, B, ...] normalized to [0.0, 1.0].
     * Buffer is rewound before returning, ready for [org.tensorflow.lite.Interpreter.run].
     *
     * Python equivalent:
     *   input_data = padded[:,:,::-1].astype(np.float32) / 255.0   # BGR→RGB + normalize
     *   Note: BufferedImage.getRGB() always returns ARGB format, so no BGR flip is needed.
     *
     * @param img Must be exactly [INPUT_SIZE]×[INPUT_SIZE].
     * @return Direct ByteBuffer in native byte order, position 0.
     * @throws IllegalArgumentException if image dimensions don't match INPUT_SIZE.
     */
    fun toByteBuffer(img: BufferedImage): ByteBuffer {
        require(img.width == INPUT_SIZE && img.height == INPUT_SIZE) {
            "Expected ${INPUT_SIZE}x${INPUT_SIZE} image, got ${img.width}x${img.height}"
        }

        val buf = ByteBuffer.allocateDirect(BUFFER_SIZE).apply {
            order(ByteOrder.nativeOrder())
        }

        // getRGB() always returns pixels in ARGB format: [31..24]=A, [23..16]=R, [15..8]=G, [7..0]=B
        val pixels = img.getRGB(0, 0, INPUT_SIZE, INPUT_SIZE, null, 0, INPUT_SIZE)
        for (pixel in pixels) {
            buf.putFloat(((pixel shr 16) and 0xFF) / 255f)  // R
            buf.putFloat(((pixel shr 8)  and 0xFF) / 255f)  // G
            buf.putFloat((pixel          and 0xFF) / 255f)  // B
        }

        buf.rewind()
        return buf
    }

    /**
     * Parse raw TFLite output (shape [1][maxDet][7]) into a filtered, sorted [List] of [ObbDetection].
     *
     * Mirrors [com.waterclockdetection.detection.ObbPostProcessor.parse] exactly.
     * Python equivalent: parse_nms_obb() with normalized=True.
     *
     * Steps:
     *  1. Filter detections below [confThresh].
     *  2. Denormalize from 0–1 to 640×640 pixel space.
     *  3. Invert letterbox (remove padding, undo scale) → original image coordinates.
     *  4. Convert angle from radians to degrees.
     *  5. Sort by confidence descending.
     *
     * @param output     Raw float output from interpreter.run(), shape [1][maxDet][7].
     * @param confThresh Minimum confidence to keep a detection.
     * @param meta       Letterbox metadata for coordinate inverse transform.
     * @return Detections in original image pixel space, sorted by confidence descending.
     */
    fun parseNmsObb(
        output: Array<Array<FloatArray>>,
        confThresh: Float,
        meta: LetterboxMeta
    ): List<ObbDetection> {
        require(output.isNotEmpty() && output[0].isNotEmpty()) {
            "Output array must have shape [1][maxDet][7], got empty array"
        }
        require(output[0][0].size == OUTPUT_FIELDS) {
            "Expected $OUTPUT_FIELDS fields per detection, got ${output[0][0].size}"
        }

        val results = mutableListOf<ObbDetection>()

        for (det in output[0]) {
            val conf = det[IDX_CONF]
            if (conf < confThresh) continue

            // Denormalize from 0–1 to 640×640 pixel space
            val px = det[IDX_X] * INPUT_SIZE
            val py = det[IDX_Y] * INPUT_SIZE
            val pw = det[IDX_W] * INPUT_SIZE
            val ph = det[IDX_H] * INPUT_SIZE

            // Invert letterbox: remove padding offset, then undo scale
            val cx = (px - meta.padLeft) / meta.scale
            val cy = (py - meta.padTop)  / meta.scale
            val bw = pw / meta.scale
            val bh = ph / meta.scale

            val angleDeg = Math.toDegrees(det[IDX_ANGLE].toDouble()).toFloat()

            results.add(
                ObbDetection(
                    classId    = det[IDX_CLS].roundToInt(),
                    confidence = conf,
                    cx         = cx,
                    cy         = cy,
                    width      = bw,
                    height     = bh,
                    angleDeg   = angleDeg
                )
            )
        }

        return results.sortedByDescending { it.confidence }
    }

    /**
     * Draw OBB detections on a copy of [src] using [java.awt.Graphics2D].
     *
     * Python equivalent: draw_obb_results(img, results, title)
     *
     * Renders:
     *   - Rotated bounding box (green, 2px stroke)
     *   - Label: "cls{id} {conf:.2f} {angle:.1f}deg" at the top-left of the box
     *   - Optional title in blue at top-left of the image
     *
     * @param src        Source image (not modified; a copy is returned).
     * @param detections Detections in original image coordinate space.
     * @param title      Optional title drawn at (10, 30) in blue (empty = skip).
     * @return New [BufferedImage] with annotations drawn on it.
     */
    fun drawObbResults(
        src: BufferedImage,
        detections: List<ObbDetection>,
        title: String = ""
    ): BufferedImage {
        val out = BufferedImage(src.width, src.height, BufferedImage.TYPE_INT_RGB)
        val g   = out.createGraphics()
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)

        // Copy source pixels
        g.drawImage(src, 0, 0, null)

        val boxColor  = Color(0, 255, 0)       // green — matches Python (0,255,0)
        val textColor = Color(0, 255, 0)
        val textBg    = Color(0, 0, 0, 160)    // semi-transparent black
        val labelFont = Font("SansSerif", Font.PLAIN, 14)

        g.stroke = BasicStroke(2f)

        for (det in detections) {
            val corners = det.corners()  // [x0,y0, x1,y1, x2,y2, x3,y3]

            // Draw rotated bounding box as a closed path
            val path = GeneralPath()
            path.moveTo(corners[0].toDouble(), corners[1].toDouble())
            path.lineTo(corners[2].toDouble(), corners[3].toDouble())
            path.lineTo(corners[4].toDouble(), corners[5].toDouble())
            path.lineTo(corners[6].toDouble(), corners[7].toDouble())
            path.closePath()

            g.color = boxColor
            g.draw(path)

            // Label: "cls{id} {conf:.2f} {angle:.1f}deg"
            val label = "cls${det.classId} ${"%.2f".format(det.confidence)} ${"%.1f".format(det.angleDeg)}deg"
            g.font = labelFont

            // Place label at the top-left corner of the bounding box
            val xs = floatArrayOf(corners[0], corners[2], corners[4], corners[6])
            val ys = floatArrayOf(corners[1], corners[3], corners[5], corners[7])
            val tx = xs.min().toInt()
            val ty = (ys.min() - 5).toInt().coerceAtLeast(g.fontMetrics.height)

            val fm    = g.fontMetrics
            val textW = fm.stringWidth(label)
            val textH = fm.height

            g.color = textBg
            g.fillRect(tx, ty - textH + fm.descent, textW + 2, textH)
            g.color = textColor
            g.drawString(label, tx + 1, ty)
        }

        // Draw title at top-left (blue, bold — matches Python red-channel label style)
        if (title.isNotEmpty()) {
            g.font  = Font("SansSerif", Font.BOLD, 24)
            g.color = Color(0, 0, 255)   // blue matches Python (0,0,255) in BGR → blue
            g.drawString(title, 10, 30)
        }

        g.dispose()
        return out
    }
}
