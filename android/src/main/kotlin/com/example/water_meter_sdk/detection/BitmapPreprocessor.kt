package com.example.water_meter_sdk.detection

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Handles letterbox resize and ByteBuffer preparation for TFLite input.
 *
 * Python equivalent (test_models.py):
 *   padded, scale, top, left, h0, w0 = letterbox(img, 640)
 *   input_data = padded[:,:,::-1].astype(np.float32) / 255.0  # BGR→RGB + normalize
 *   input_data = np.expand_dims(input_data, 0)                 # add batch dim
 *
 * Note: Android Bitmap is ARGB (RGB channel order), so no BGR flip is needed
 * unlike the OpenCV version in Python.
 */
object BitmapPreprocessor {

    const val INPUT_SIZE = 640

    // Buffer size: 1 batch × 640 × 640 × 3 channels × 4 bytes (float32)
    private const val BUFFER_SIZE = 1 * INPUT_SIZE * INPUT_SIZE * 3 * 4

    // Letterbox fill color matching Python default: RGB(114, 114, 114)
    private val PAD_COLOR = Color.rgb(114, 114, 114)

    /**
     * Apply letterbox padding to [src] and return a 640×640 Bitmap with [LetterboxMeta].
     *
     * The source image is scaled uniformly (preserving aspect ratio) to fit within 640×640,
     * and the remaining area is filled with gray (114, 114, 114) padding.
     *
     * Caller is responsible for recycling the returned Bitmap after use.
     *
     * @param src Source bitmap of any size.
     * @return Pair of (640×640 letterboxed Bitmap, LetterboxMeta for inverse transform).
     */
    fun letterbox(src: Bitmap): Pair<Bitmap, LetterboxMeta> {
        val origW = src.width
        val origH = src.height

        // Uniform scale to fit within INPUT_SIZE × INPUT_SIZE
        val scale = minOf(INPUT_SIZE.toFloat() / origH, INPUT_SIZE.toFloat() / origW)
        val newW = (origW * scale).toInt()
        val newH = (origH * scale).toInt()

        // Center padding
        val padTop = (INPUT_SIZE - newH) / 2
        val padLeft = (INPUT_SIZE - newW) / 2

        // Create 640×640 canvas filled with pad color
        val padded = Bitmap.createBitmap(INPUT_SIZE, INPUT_SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(padded)
        canvas.drawColor(PAD_COLOR)

        // Draw scaled source image into the center
        val scaled = Bitmap.createScaledBitmap(src, newW, newH, true)
        val destRect = Rect(padLeft, padTop, padLeft + newW, padTop + newH)
        canvas.drawBitmap(scaled, null, destRect, null)
        scaled.recycle()

        val meta = LetterboxMeta(scale, padTop, padLeft, origW, origH)
        return Pair(padded, meta)
    }

    /**
     * Convert a 640×640 letterboxed Bitmap to a float32 NHWC [ByteBuffer] for TFLite input.
     *
     * Output layout: [R, G, B, R, G, B, ...] normalized to [0.0, 1.0] per channel.
     * Buffer is rewound before returning, ready for [org.tensorflow.lite.Interpreter.run].
     *
     * @param bitmap Must be exactly [INPUT_SIZE]×[INPUT_SIZE] pixels.
     * @return Direct [ByteBuffer] in native byte order, rewound to position 0.
     * @throws IllegalArgumentException if bitmap dimensions don't match [INPUT_SIZE].
     */
    fun toByteBuffer(bitmap: Bitmap): ByteBuffer {
        require(bitmap.width == INPUT_SIZE && bitmap.height == INPUT_SIZE) {
            "Expected ${INPUT_SIZE}x${INPUT_SIZE} bitmap, got ${bitmap.width}x${bitmap.height}"
        }

        val buf = ByteBuffer.allocateDirect(BUFFER_SIZE).apply {
            order(ByteOrder.nativeOrder())
        }

        val pixels = IntArray(INPUT_SIZE * INPUT_SIZE)
        bitmap.getPixels(pixels, 0, INPUT_SIZE, 0, 0, INPUT_SIZE, INPUT_SIZE)

        for (pixel in pixels) {
            // ARGB_8888: bits [31..24]=A, [23..16]=R, [15..8]=G, [7..0]=B
            buf.putFloat(((pixel shr 16) and 0xFF) / 255f)  // R
            buf.putFloat(((pixel shr 8) and 0xFF) / 255f)   // G
            buf.putFloat((pixel and 0xFF) / 255f)            // B
        }

        buf.rewind()
        return buf
    }
}
