package com.waterclockdetection.detection.test

import com.waterclockdetection.detection.LetterboxMeta
import org.junit.Assert.*
import org.junit.Test

/**
 * Unit tests for [LetterboxMeta] data class.
 *
 * Primarily verifies that the data class stores and retrieves values correctly,
 * and that equality/copy semantics work as expected.
 */
class LetterboxMetaTest {

    @Test
    fun `stores all fields correctly`() {
        val meta = LetterboxMeta(scale = 0.5f, padTop = 80, padLeft = 0, origWidth = 1280, origHeight = 720)
        assertEquals(0.5f, meta.scale, 0.001f)
        assertEquals(80, meta.padTop)
        assertEquals(0, meta.padLeft)
        assertEquals(1280, meta.origWidth)
        assertEquals(720, meta.origHeight)
    }

    @Test
    fun `equals and hashCode work correctly`() {
        val m1 = LetterboxMeta(1.0f, 10, 20, 640, 480)
        val m2 = LetterboxMeta(1.0f, 10, 20, 640, 480)
        assertEquals(m1, m2)
        assertEquals(m1.hashCode(), m2.hashCode())
    }

    @Test
    fun `copy with modified scale produces correct object`() {
        val meta = LetterboxMeta(1.0f, 80, 0, 320, 240)
        val scaled = meta.copy(scale = 2.0f)
        assertEquals(2.0f, scaled.scale, 0.001f)
        assertEquals(meta.padTop, scaled.padTop)
        assertEquals(meta.origWidth, scaled.origWidth)
    }
}
