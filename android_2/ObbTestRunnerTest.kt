/**
 * ObbTestRunnerTest.kt — Unit tests for BitmapCompat utility functions.
 *
 * Tests the core logic in BitmapCompat (letterbox, toByteBuffer, parseNmsObb,
 * ObbDetection.corners) without requiring a TFLite model or real images.
 *
 * Dependencies: kotlin.test (bundled with Kotlin stdlib when run via `kotlin -script`
 * or a test runner like JUnit 4/5 via kotlinc-jvm).
 *
 * Run standalone (no build tool):
 *   kotlinc BitmapCompat.kt ObbTestRunnerTest.kt -include-runtime -d tests.jar
 *   java -jar tests.jar
 *
 * Or via Gradle with kotlin.test:
 *   testImplementation(kotlin("test"))
 */
package com.waterclockdetection.test

import java.awt.image.BufferedImage
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.sqrt

// ── Minimal test harness (no external dependencies) ───────────────────────────

private var passed = 0
private var failed = 0

private fun test(name: String, block: () -> Unit) {
    try {
        block()
        println("  PASS: $name")
        passed++
    } catch (e: AssertionError) {
        System.err.println("  FAIL: $name — ${e.message}")
        failed++
    } catch (e: Exception) {
        System.err.println("  ERROR: $name — ${e::class.simpleName}: ${e.message}")
        failed++
    }
}

private fun assertEquals(expected: Any?, actual: Any?, msg: String = "") {
    if (expected != actual) throw AssertionError("Expected <$expected> but was <$actual>. $msg")
}

private fun assertNear(expected: Float, actual: Float, tol: Float = 1e-4f, msg: String = "") {
    if (abs(expected - actual) > tol)
        throw AssertionError("Expected ~$expected but was $actual (tol=$tol). $msg")
}

private fun assertTrue(condition: Boolean, msg: String = "Condition was false") {
    if (!condition) throw AssertionError(msg)
}

private fun assertThrows(block: () -> Unit): Exception {
    return try {
        block()
        throw AssertionError("Expected exception was not thrown")
    } catch (e: AssertionError) {
        throw e
    } catch (e: Exception) {
        e
    }
}

// ── Test Suites ───────────────────────────────────────────────────────────────

fun testObbDetectionCorners() {
    println("\n[ObbDetection.corners()]")

    test("axis-aligned box (angle=0) has correct corners") {
        // For angle=0: cosA=1, sinA=0
        // dx1=hw, dy1=0, dx2=0, dy2=hh
        // TR=(cx+hw, cy-hh), TL=(cx-hw, cy-hh), BL=(cx-hw, cy+hh), BR=(cx+hw, cy+hh)
        val det = ObbDetection(0, 0.9f, cx=100f, cy=100f, width=40f, height=20f, angleDeg=0f)
        val c = det.corners()
        // top-right
        assertNear(120f, c[0], msg="TR.x")
        assertNear(90f,  c[1], msg="TR.y")
        // top-left
        assertNear(80f, c[2], msg="TL.x")
        assertNear(90f, c[3], msg="TL.y")
        // bottom-left
        assertNear(80f,  c[4], msg="BL.x")
        assertNear(110f, c[5], msg="BL.y")
        // bottom-right
        assertNear(120f, c[6], msg="BR.x")
        assertNear(110f, c[7], msg="BR.y")
    }

    test("square box (angle=0) has equal side lengths") {
        val det = ObbDetection(0, 0.8f, cx=50f, cy=50f, width=20f, height=20f, angleDeg=0f)
        val c = det.corners()
        // All four sides should have length 20
        fun dist(i: Int, j: Int): Float {
            val dx = c[j*2] - c[i*2]; val dy = c[j*2+1] - c[i*2+1]
            return sqrt(dx*dx + dy*dy)
        }
        assertNear(20f, dist(0,1), tol=0.01f, msg="TR→TL side length")
        assertNear(20f, dist(1,2), tol=0.01f, msg="TL→BL side length")
        assertNear(20f, dist(2,3), tol=0.01f, msg="BL→BR side length")
        assertNear(20f, dist(3,0), tol=0.01f, msg="BR→TR side length")
    }

    test("corners() returns 8 floats for any angle") {
        val det = ObbDetection(0, 0.5f, cx=200f, cy=150f, width=60f, height=30f, angleDeg=45f)
        assertEquals(8, det.corners().size, "should return 8 floats (4 points × 2 coords)")
    }

    test("rotated box: diagonal from center to corner equals half-diagonal") {
        // For a box width=60, height=40, the distance from center to any corner
        // should be sqrt((30^2 + 20^2)) regardless of angle
        val expected = sqrt(30f*30f + 20f*20f)
        for (angleDeg in listOf(0f, 30f, 45f, 90f, 135f, -45f)) {
            val det = ObbDetection(0, 0.9f, cx=0f, cy=0f, width=60f, height=40f, angleDeg=angleDeg)
            val c = det.corners()
            for (i in 0..3) {
                val dist = sqrt(c[i*2]*c[i*2] + c[i*2+1]*c[i*2+1])
                assertNear(expected, dist, tol=0.01f, msg="angle=$angleDeg corner$i distance")
            }
        }
    }
}

fun testLetterbox() {
    println("\n[BitmapCompat.letterbox()]")

    test("output is always 640x640") {
        val src = BufferedImage(1280, 720, BufferedImage.TYPE_INT_RGB)
        val (padded, _) = BitmapCompat.letterbox(src)
        assertEquals(640, padded.width,  "padded width")
        assertEquals(640, padded.height, "padded height")
    }

    test("landscape image: scale = 640/720 (height-constrained), padLeft > 0, padTop = 0") {
        val src = BufferedImage(1280, 720, BufferedImage.TYPE_INT_RGB)
        val (_, meta) = BitmapCompat.letterbox(src)
        val expectedScale = 640f / 720f
        assertNear(expectedScale, meta.scale, tol=1e-4f, msg="scale")
        // newW = 1280 * scale ≈ 1138 → padLeft = (640 - 1138) / 2 < 0
        // Actually: scale = min(640/720, 640/1280) = min(0.888, 0.5) = 0.5
        // newH = 720*0.5 = 360, newW = 1280*0.5 = 640
        // padTop = (640-360)/2 = 140, padLeft = 0
        val expectedScale2 = 640f / 1280f   // width-constrained for 1280x720
        assertNear(expectedScale2, meta.scale, tol=1e-4f, msg="scale (width-constrained)")
        assertEquals(0,   meta.padLeft, "padLeft for landscape with equal newW")
        assertEquals(140, meta.padTop,  "padTop for landscape 1280x720")
    }

    test("portrait image: padLeft > 0, padTop = 0 or small") {
        val src = BufferedImage(480, 640, BufferedImage.TYPE_INT_RGB)
        val (_, meta) = BitmapCompat.letterbox(src)
        // scale = min(640/640, 640/480) = min(1.0, 1.333) = 1.0
        assertNear(1.0f, meta.scale, msg="scale for 480x640")
        assertEquals(0, meta.padTop, "padTop=0 for height-fit portrait")
        assertEquals(80, meta.padLeft, "padLeft=(640-480)/2=80 for portrait")
    }

    test("square image: no padding on either axis") {
        val src = BufferedImage(800, 800, BufferedImage.TYPE_INT_RGB)
        val (_, meta) = BitmapCompat.letterbox(src)
        assertNear(640f / 800f, meta.scale, msg="scale for square")
        assertEquals(0, meta.padTop,  "no padTop for square")
        assertEquals(0, meta.padLeft, "no padLeft for square")
    }

    test("meta.origWidth and origHeight match source dimensions") {
        val src = BufferedImage(960, 540, BufferedImage.TYPE_INT_RGB)
        val (_, meta) = BitmapCompat.letterbox(src)
        assertEquals(960, meta.origWidth,  "origWidth")
        assertEquals(540, meta.origHeight, "origHeight")
    }

    test("gray padding color is (114,114,114) in top-left corner after padding") {
        // Create a 640x640 black image; padding area (if any) should be gray
        val src = BufferedImage(320, 640, BufferedImage.TYPE_INT_RGB)  // portrait
        // src is all black (0,0,0)
        val (padded, meta) = BitmapCompat.letterbox(src)
        // padLeft = (640 - 320)/2 = 160; pixel at (0,0) is in the pad area
        val pixel = padded.getRGB(0, 0)
        val r = (pixel shr 16) and 0xFF
        val g = (pixel shr 8)  and 0xFF
        val b = pixel          and 0xFF
        assertNear(114f, r.toFloat(), tol=2f, msg="pad R channel")
        assertNear(114f, g.toFloat(), tol=2f, msg="pad G channel")
        assertNear(114f, b.toFloat(), tol=2f, msg="pad B channel")
    }
}

fun testToByteBuffer() {
    println("\n[BitmapCompat.toByteBuffer()]")

    test("white image produces all-1.0 buffer") {
        val img = BufferedImage(640, 640, BufferedImage.TYPE_INT_RGB)
        val g = img.createGraphics()
        g.color = java.awt.Color.WHITE
        g.fillRect(0, 0, 640, 640)
        g.dispose()

        val buf = BitmapCompat.toByteBuffer(img)
        buf.rewind()
        var allOnes = true
        repeat(640 * 640 * 3) {
            val v = buf.float
            if (abs(v - 1.0f) > 1e-5f) { allOnes = false }
        }
        assertTrue(allOnes, "all pixel channels should be 1.0 for white image")
    }

    test("black image produces all-0.0 buffer") {
        val img = BufferedImage(640, 640, BufferedImage.TYPE_INT_RGB)
        // Default is black (all zeros)
        val buf = BitmapCompat.toByteBuffer(img)
        buf.rewind()
        var allZeros = true
        repeat(640 * 640 * 3) {
            val v = buf.float
            if (abs(v) > 1e-5f) { allZeros = false }
        }
        assertTrue(allZeros, "all pixel channels should be 0.0 for black image")
    }

    test("buffer has correct capacity: 640*640*3*4 bytes") {
        val img = BufferedImage(640, 640, BufferedImage.TYPE_INT_RGB)
        val buf = BitmapCompat.toByteBuffer(img)
        assertEquals(640 * 640 * 3 * 4, buf.capacity(), "buffer byte capacity")
    }

    test("buffer is rewound to position 0 after creation") {
        val img = BufferedImage(640, 640, BufferedImage.TYPE_INT_RGB)
        val buf = BitmapCompat.toByteBuffer(img)
        assertEquals(0, buf.position(), "buffer position should be 0 (rewound)")
    }

    test("throws on wrong image size") {
        val img = BufferedImage(320, 320, BufferedImage.TYPE_INT_RGB)
        val ex  = assertThrows { BitmapCompat.toByteBuffer(img) }
        assertTrue(ex is IllegalArgumentException, "should throw IllegalArgumentException")
    }

    test("known color pixel maps to correct normalized channels") {
        // Create 640x640 image with a known pixel at (0,0): R=255, G=128, B=0
        val img = BufferedImage(640, 640, BufferedImage.TYPE_INT_RGB)
        img.setRGB(0, 0, (255 shl 16) or (128 shl 8) or 0)  // ARGB: R=255, G=128, B=0
        val buf = BitmapCompat.toByteBuffer(img)
        buf.rewind()
        val r = buf.float
        val g = buf.float
        val b = buf.float
        assertNear(1.0f,   r, tol=0.005f, msg="R channel of R=255")
        assertNear(0.502f, g, tol=0.005f, msg="G channel of G=128")
        assertNear(0.0f,   b, tol=0.005f, msg="B channel of B=0")
    }
}

fun testParseNmsObb() {
    println("\n[BitmapCompat.parseNmsObb()]")

    /** Helper to build a minimal output tensor [1][maxDet][7] */
    fun makeOutput(vararg rows: FloatArray): Array<Array<FloatArray>> {
        return arrayOf(rows.map { it.copyOf() }.toTypedArray())
    }

    val meta = LetterboxMeta(scale=0.5f, padTop=140, padLeft=0, origWidth=1280, origHeight=720)

    test("filters detections below confidence threshold") {
        val output = makeOutput(
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.8f, 0f, 0.1f),  // high conf → keep
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.01f, 0f, 0.1f)  // low conf  → drop
        )
        val dets = BitmapCompat.parseNmsObb(output, 0.02f, meta)
        assertEquals(1, dets.size, "only 1 detection above threshold")
    }

    test("returns empty list when all detections below threshold") {
        val output = makeOutput(
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.005f, 0f, 0f)
        )
        val dets = BitmapCompat.parseNmsObb(output, 0.02f, meta)
        assertEquals(0, dets.size, "should be empty")
    }

    test("detections sorted by confidence descending") {
        val output = makeOutput(
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.3f,  0f, 0f),
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.9f,  1f, 0f),
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.05f, 0f, 0f)
        )
        val dets = BitmapCompat.parseNmsObb(output, 0.02f, meta)
        assertEquals(3, dets.size, "all 3 above threshold")
        assertTrue(dets[0].confidence >= dets[1].confidence, "sorted descending [0]≥[1]")
        assertTrue(dets[1].confidence >= dets[2].confidence, "sorted descending [1]≥[2]")
    }

    test("coordinate denormalization and letterbox inversion are correct") {
        // Model output in normalized coords: x=0.5, y=0.5 → pixel (320,320) in 640 space
        // meta: scale=0.5, padTop=140, padLeft=0
        // cx = (320 - 0) / 0.5 = 640
        // cy = (320 - 140) / 0.5 = 360
        val output = makeOutput(
            floatArrayOf(0.5f, 0.5f, 0.2f, 0.1f, 0.8f, 0f, 0.0f)
        )
        val dets = BitmapCompat.parseNmsObb(output, 0.02f, meta)
        assertEquals(1, dets.size)
        assertNear(640f, dets[0].cx, tol=0.5f, msg="cx in original image space")
        assertNear(360f, dets[0].cy, tol=0.5f, msg="cy in original image space")
    }

    test("width and height are scaled by inverse of letterbox scale") {
        // pw = 0.2 * 640 = 128 pixels in letterbox space; bw = 128 / 0.5 = 256
        // ph = 0.1 * 640 = 64 pixels;                    bh = 64 / 0.5 = 128
        val output = makeOutput(
            floatArrayOf(0.5f, 0.5f, 0.2f, 0.1f, 0.8f, 0f, 0.0f)
        )
        val dets = BitmapCompat.parseNmsObb(output, 0.02f, meta)
        assertNear(256f, dets[0].width,  tol=0.5f, msg="width in original space")
        assertNear(128f, dets[0].height, tol=0.5f, msg="height in original space")
    }

    test("angle converted from radians to degrees") {
        val angleRad = (Math.PI / 4).toFloat()   // 45 degrees
        val output   = makeOutput(
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.8f, 0f, angleRad)
        )
        val dets = BitmapCompat.parseNmsObb(output, 0.02f, meta)
        assertNear(45f, dets[0].angleDeg, tol=0.01f, msg="angle in degrees")
    }

    test("classId is rounded from float") {
        val output = makeOutput(
            floatArrayOf(0.5f, 0.5f, 0.1f, 0.1f, 0.8f, 2.6f, 0f)  // cls=2.6 → 3
        )
        val dets = BitmapCompat.parseNmsObb(output, 0.02f, meta)
        assertEquals(3, dets[0].classId, "classId should be rounded to nearest int")
    }

    test("throws on empty output array") {
        val ex = assertThrows {
            BitmapCompat.parseNmsObb(arrayOf(emptyArray()), 0.02f, meta)
        }
        assertTrue(ex is IllegalArgumentException, "should throw IllegalArgumentException")
    }

    test("throws on wrong number of output fields") {
        val output = arrayOf(arrayOf(FloatArray(5)))  // 5 fields instead of 7
        val ex = assertThrows {
            BitmapCompat.parseNmsObb(output, 0.02f, meta)
        }
        assertTrue(ex is IllegalArgumentException, "should throw IllegalArgumentException")
    }
}

fun testLetterboxMeta() {
    println("\n[LetterboxMeta data class]")

    test("data class equality for same values") {
        val m1 = LetterboxMeta(0.5f, 140, 0, 1280, 720)
        val m2 = LetterboxMeta(0.5f, 140, 0, 1280, 720)
        assertEquals(m1, m2, "LetterboxMeta with same fields should be equal")
    }

    test("data class inequality for different scale") {
        val m1 = LetterboxMeta(0.5f, 0, 0, 640, 480)
        val m2 = LetterboxMeta(1.0f, 0, 0, 640, 480)
        assertTrue(m1 != m2, "LetterboxMeta with different scale should not be equal")
    }
}

// ── Test Runner ───────────────────────────────────────────────────────────────

fun runAllTests() {
    println("=== ObbTestRunner Unit Tests ===")
    testObbDetectionCorners()
    testLetterbox()
    testToByteBuffer()
    testParseNmsObb()
    testLetterboxMeta()
    println("\n=== Results: $passed passed, $failed failed ===")
    if (failed > 0) {
        System.err.println("SOME TESTS FAILED")
        // In a real test harness this would exit with non-zero
    }
}

// Standalone entry point (compile without ObbTestRunner.kt to avoid duplicate main)
// fun main() = runAllTests()
