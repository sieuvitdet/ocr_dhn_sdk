package com.waterclockdetection.detection.test

import com.waterclockdetection.detection.ObbDetection
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Unit tests for [ObbDetection] — primarily verifying corners() geometry.
 */
class ObbDetectionTest {

    private val DELTA = 0.5f  // pixel-level tolerance for floating point comparisons

    // --- corners() geometry tests ---

    @Test
    fun `corners at zero angle returns axis-aligned rectangle`() {
        // A 10x6 box centered at (100, 100), 0° rotation
        val det = ObbDetection(
            classId = 0, confidence = 0.9f,
            cx = 100f, cy = 100f,
            width = 10f, height = 6f,
            angleDeg = 0f
        )
        val c = det.corners()
        // Expected corners (TR, TL, BL, BR) for axis-aligned rect:
        //   TR = (105, 97), TL = (95, 97), BL = (95, 103), BR = (105, 103)
        assertCornersClose(c, floatArrayOf(
            105f, 97f,   // TR: cx + w/2, cy - h/2
             95f, 97f,   // TL: cx - w/2, cy - h/2
             95f, 103f,  // BL: cx - w/2, cy + h/2
            105f, 103f   // BR: cx + w/2, cy + h/2
        ))
    }

    @Test
    fun `corners at 90 degrees swaps width and height axes`() {
        val det = ObbDetection(
            classId = 0, confidence = 0.8f,
            cx = 50f, cy = 50f,
            width = 10f, height = 4f,
            angleDeg = 90f
        )
        val c = det.corners()
        // At 90°: cos=0, sin=1
        // dx1=cos*w/2=0, dy1=sin*w/2=5   (width axis now points down)
        // dx2=sin*h/2=2, dy2=cos*h/2=0   (height axis now points right)
        // TR: (0-2, 5-0) + center = (48, 55)
        // TL: (0-2, -5-0) + center = (48, 45)
        // BL: (0+2, -5+0) + center = (52, 45)
        // BR: (0+2, 5+0) + center = (52, 55)
        assertCornersClose(c, floatArrayOf(
            48f, 55f,
            48f, 45f,
            52f, 45f,
            52f, 55f
        ))
    }

    @Test
    fun `corners returns 8 floats for 4 points`() {
        val det = ObbDetection(0, 0.5f, 100f, 100f, 20f, 10f, 45f)
        assertEquals(8, det.corners().size)
    }

    @Test
    fun `corners centroid matches cx cy`() {
        // The centroid of the 4 corners must equal (cx, cy)
        val det = ObbDetection(0, 0.9f, 123f, 456f, 50f, 30f, 37f)
        val c = det.corners()
        val avgX = (c[0] + c[2] + c[4] + c[6]) / 4f
        val avgY = (c[1] + c[3] + c[5] + c[7]) / 4f
        assertEquals(det.cx, avgX, DELTA)
        assertEquals(det.cy, avgY, DELTA)
    }

    @Test
    fun `corners diagonal distance matches expected from width and height`() {
        // For a rectangle, diagonal = sqrt(w^2 + h^2)
        // Distance from center to any corner = diagonal / 2
        val w = 30f; val h = 20f
        val det = ObbDetection(0, 0.9f, 0f, 0f, w, h, 25f)
        val c = det.corners()
        val expectedDist = sqrt((w * w + h * h) / 4f)
        for (i in 0 until 4) {
            val dx = c[i * 2]
            val dy = c[i * 2 + 1]
            val dist = sqrt(dx * dx + dy * dy)
            assertEquals("Corner $i distance from origin", expectedDist, dist, DELTA)
        }
    }

    @Test
    fun `data class copy preserves original values`() {
        val det = ObbDetection(1, 0.75f, 100f, 200f, 50f, 30f, 15f)
        val scaled = det.copy(cx = det.cx * 2f, cy = det.cy * 2f)
        assertEquals(200f, scaled.cx, DELTA)
        assertEquals(400f, scaled.cy, DELTA)
        assertEquals(det.classId, scaled.classId)
        assertEquals(det.confidence, scaled.confidence, DELTA)
    }

    // --- Helpers ---

    private fun assertCornersClose(actual: FloatArray, expected: FloatArray) {
        assertEquals("Corner array length", expected.size, actual.size)
        for (i in expected.indices) {
            assertEquals("Corner[$i]", expected[i], actual[i], DELTA)
        }
    }
}
