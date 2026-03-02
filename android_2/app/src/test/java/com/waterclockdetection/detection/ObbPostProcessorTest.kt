package com.waterclockdetection.detection.test

import com.waterclockdetection.detection.LetterboxMeta
import com.waterclockdetection.detection.ObbPostProcessor
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI

/**
 * Unit tests for [ObbPostProcessor.parse].
 *
 * Verifies filtering, denormalization, letterbox inverse transform, angle conversion,
 * and result ordering — mirroring parse_nms_obb() in test_models.py (normalized=True path).
 */
class ObbPostProcessorTest {

    private val DELTA = 0.1f

    // Helpers to build output tensors
    private fun makeRow(
        x: Float, y: Float, w: Float, h: Float,
        conf: Float, cls: Float, angleRad: Float
    ) = floatArrayOf(x, y, w, h, conf, cls, angleRad)

    private fun wrap(vararg rows: FloatArray): Array<Array<FloatArray>> =
        arrayOf(rows.toList().toTypedArray())

    // A simple square-image meta: scale=1.0, no padding
    private val squareMeta = LetterboxMeta(scale = 1.0f, padTop = 0, padLeft = 0, origWidth = 640, origHeight = 640)

    // --- Filtering ---

    @Test
    fun `detections below threshold are excluded`() {
        val output = wrap(
            makeRow(0.5f, 0.5f, 0.1f, 0.1f, conf = 0.10f, cls = 0f, angleRad = 0f),
            makeRow(0.5f, 0.5f, 0.1f, 0.1f, conf = 0.30f, cls = 0f, angleRad = 0f)
        )
        val results = ObbPostProcessor.parse(output, squareMeta, confThresh = 0.25f)
        assertEquals(1, results.size)
        assertEquals(0.30f, results[0].confidence, DELTA)
    }

    @Test
    fun `detections exactly at threshold are included`() {
        val output = wrap(
            makeRow(0.5f, 0.5f, 0.1f, 0.1f, conf = 0.25f, cls = 0f, angleRad = 0f)
        )
        val results = ObbPostProcessor.parse(output, squareMeta, confThresh = 0.25f)
        assertEquals(1, results.size)
    }

    @Test
    fun `empty output returns empty list`() {
        val output = wrap(
            makeRow(0.5f, 0.5f, 0.1f, 0.1f, conf = 0.0f, cls = 0f, angleRad = 0f)
        )
        val results = ObbPostProcessor.parse(output, squareMeta, confThresh = 0.25f)
        assertTrue(results.isEmpty())
    }

    // --- Coordinate denormalization & inverse letterbox (no padding, scale=1) ---

    @Test
    fun `normalized center at 0_5 maps to center of 640x640 image when no padding`() {
        val output = wrap(
            makeRow(x = 0.5f, y = 0.5f, w = 0.1f, h = 0.1f, conf = 0.9f, cls = 0f, angleRad = 0f)
        )
        val results = ObbPostProcessor.parse(output, squareMeta)
        val det = results[0]
        // px = 0.5 * 640 = 320; cx = (320 - 0) / 1.0 = 320
        assertEquals(320f, det.cx, DELTA)
        assertEquals(320f, det.cy, DELTA)
    }

    @Test
    fun `coordinate transform correctly removes padding and undoes scale`() {
        // Simulate a 320x240 original → letterboxed to 640x640
        // scale = min(640/240, 640/320) = min(2.67, 2.0) = 2.0
        // newW = 640, newH = 480, padTop = (640-480)/2 = 80, padLeft = 0
        val meta = LetterboxMeta(scale = 2.0f, padTop = 80, padLeft = 0, origWidth = 320, origHeight = 240)

        // Detection at normalized 0.5, 0.5 in 640x640 space
        val output = wrap(
            makeRow(x = 0.5f, y = 0.5f, w = 0.2f, h = 0.1f, conf = 0.9f, cls = 1f, angleRad = 0f)
        )
        val results = ObbPostProcessor.parse(output, meta)
        val det = results[0]

        // px = 320, py = 320
        // cx = (320 - 0) / 2.0 = 160
        // cy = (320 - 80) / 2.0 = 120
        assertEquals(160f, det.cx, DELTA)
        assertEquals(120f, det.cy, DELTA)

        // pw = 0.2 * 640 = 128; bw = 128 / 2.0 = 64
        assertEquals(64f, det.width, DELTA)
        // ph = 0.1 * 640 = 64; bh = 64 / 2.0 = 32
        assertEquals(32f, det.height, DELTA)
    }

    // --- Angle conversion ---

    @Test
    fun `angle_rad is converted to degrees`() {
        val output = wrap(
            makeRow(0.5f, 0.5f, 0.1f, 0.1f, conf = 0.9f, cls = 0f, angleRad = (PI / 2).toFloat())
        )
        val results = ObbPostProcessor.parse(output, squareMeta)
        assertEquals(90f, results[0].angleDeg, 0.01f)
    }

    @Test
    fun `zero angle_rad maps to 0 degrees`() {
        val output = wrap(
            makeRow(0.5f, 0.5f, 0.1f, 0.1f, conf = 0.9f, cls = 0f, angleRad = 0f)
        )
        val results = ObbPostProcessor.parse(output, squareMeta)
        assertEquals(0f, results[0].angleDeg, 0.01f)
    }

    // --- Class ID ---

    @Test
    fun `class_id float is rounded to nearest int`() {
        val output = wrap(
            makeRow(0.5f, 0.5f, 0.1f, 0.1f, conf = 0.9f, cls = 2.6f, angleRad = 0f)
        )
        val results = ObbPostProcessor.parse(output, squareMeta)
        assertEquals(3, results[0].classId)
    }

    // --- Sorting ---

    @Test
    fun `results are sorted by confidence descending`() {
        val output = wrap(
            makeRow(0.1f, 0.1f, 0.1f, 0.1f, conf = 0.5f, cls = 0f, angleRad = 0f),
            makeRow(0.2f, 0.2f, 0.1f, 0.1f, conf = 0.9f, cls = 0f, angleRad = 0f),
            makeRow(0.3f, 0.3f, 0.1f, 0.1f, conf = 0.7f, cls = 0f, angleRad = 0f)
        )
        val results = ObbPostProcessor.parse(output, squareMeta, confThresh = 0.25f)
        assertEquals(3, results.size)
        assertEquals(0.9f, results[0].confidence, DELTA)
        assertEquals(0.7f, results[1].confidence, DELTA)
        assertEquals(0.5f, results[2].confidence, DELTA)
    }

    // --- Validation ---

    @Test(expected = IllegalArgumentException::class)
    fun `mismatched field count throws IllegalArgumentException`() {
        // 6 fields instead of 7
        val badOutput = arrayOf(arrayOf(floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.9f, 0f)))
        ObbPostProcessor.parse(badOutput, squareMeta)
    }
}
