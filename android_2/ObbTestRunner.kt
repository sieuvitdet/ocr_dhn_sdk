/**
 * ObbTestRunner.kt — Standalone JVM test runner for TFLite OBB detection model.
 *
 * Functionally equivalent to test_models.py test_tflite() but runs on desktop JVM
 * without an Android runtime. For each test image it:
 *   1. Loads the image via javax.imageio.ImageIO → BufferedImage
 *   2. Letterboxes to 640×640 with gray padding
 *   3. Converts to float32 NHWC ByteBuffer
 *   4. Runs TFLite inference (using Interpreter(File) — no Android Context needed)
 *   5. Parses detections (class_id, confidence, cx, cy, w, h, angle_deg)
 *   6. Draws OBBs on the original image using Graphics2D
 *   7. Saves annotated output to exported_models/tflite_kotlin_{name}.jpg
 *   8. Prints inference time and per-detection fields
 *
 * All image logic is in BitmapCompat.kt (same package).
 *
 * ─── Build Notes ────────────────────────────────────────────────────────────
 * Requires org.tensorflow:tensorflow-lite on the classpath.
 *
 * Minimal Gradle setup (build.gradle.kts):
 *   plugins { kotlin("jvm") }
 *   dependencies {
 *       implementation("org.tensorflow:tensorflow-lite:2.14.0")
 *   }
 *   application { mainClass.set("com.waterclockdetection.test.ObbTestRunnerKt") }
 *
 * Or compile manually:
 *   kotlinc -cp tensorflow-lite.jar BitmapCompat.kt ObbTestRunner.kt \
 *           -include-runtime -d runner.jar
 *   java -cp runner.jar:tensorflow-lite.jar com.waterclockdetection.test.ObbTestRunnerKt
 * ────────────────────────────────────────────────────────────────────────────
 */
package com.waterclockdetection.test

import org.tensorflow.lite.Interpreter
import java.io.File
import javax.imageio.ImageIO
import java.awt.image.BufferedImage

// ── Configuration ─────────────────────────────────────────────────────────────

private const val MODEL_PATH       = "/Users/longvu/Desktop/water-clock-mobile/exported_models/best.tflite"
private const val TEST_IMAGES_DIR  = "/Users/longvu/Desktop/water-clock-mobile/test_images"
private const val OUTPUT_DIR       = "/Users/longvu/Desktop/water-clock-mobile/exported_models"

/** Low threshold because model is newly trained; raise to 0.25 when model is mature. */
private const val CONF_THRESHOLD   = 0.02f

private const val NUM_THREADS      = 4

// ── Entry Point ───────────────────────────────────────────────────────────────

fun main() {
    val modelFile     = File(MODEL_PATH)
    val testImagesDir = File(TEST_IMAGES_DIR)
    val outputDir     = File(OUTPUT_DIR)

    require(modelFile.exists()) {
        "TFLite model not found: $MODEL_PATH"
    }
    require(testImagesDir.isDirectory) {
        "Test images directory not found: $TEST_IMAGES_DIR"
    }

    outputDir.mkdirs()

    println("Model:           $MODEL_PATH")
    println("Test images dir: $TEST_IMAGES_DIR")
    println("Output dir:      $OUTPUT_DIR")
    println("Conf threshold:  $CONF_THRESHOLD")
    println()

    // Load interpreter once; reuse across all images
    val interpreter = loadInterpreter(modelFile)
    interpreter.use { interp ->
        logTensorShapes(interp)
        println()

        val maxDet = interp.getOutputTensor(0).shape()[1]

        val imageFiles = collectImageFiles(testImagesDir)
        if (imageFiles.isEmpty()) {
            println("No images found in $TEST_IMAGES_DIR")
            return
        }
        println("Images: ${imageFiles.size}\n")

        for (imageFile in imageFiles) {
            processImage(imageFile, interp, maxDet, outputDir)
            println()
        }
    }

    println("DONE — annotated images in $OUTPUT_DIR")
}

// ── Core Pipeline ─────────────────────────────────────────────────────────────

/**
 * Run the full OBB detection pipeline on one image file.
 *
 * Mirrors test_models.py::test_tflite() step-for-step.
 *
 * @param imageFile   Source image (.jpg, .jpeg, or .png).
 * @param interpreter Initialized TFLite interpreter.
 * @param maxDet      Maximum detections from the output tensor shape.
 * @param outputDir   Directory where the annotated image will be saved.
 */
private fun processImage(
    imageFile: File,
    interpreter: Interpreter,
    maxDet: Int,
    outputDir: File
) {
    println("[${imageFile.name}]")
    println("  --- TFLite Kotlin ---")

    // Step 1: Load image
    val src: BufferedImage? = ImageIO.read(imageFile)
    if (src == null) {
        System.err.println("  ERROR: Could not decode image: ${imageFile.absolutePath}")
        return
    }
    println("  Image size: ${src.width}x${src.height}")

    // Step 2: Letterbox to 640×640 with gray padding (114,114,114)
    val (letterboxed, meta) = BitmapCompat.letterbox(src)

    // Step 3: Convert to float32 NHWC ByteBuffer (R,G,B normalized 0–1)
    val inputBuffer = BitmapCompat.toByteBuffer(letterboxed)

    // Step 4: Allocate output tensor [1][maxDet][7]
    val output = Array(1) { Array(maxDet) { FloatArray(7) } }

    // Step 5: Run inference and measure wall-clock time
    val t0 = System.currentTimeMillis()
    interpreter.run(inputBuffer, output)
    val inferenceMs = System.currentTimeMillis() - t0

    // Step 6: Parse results — filter, denormalize, invert letterbox, sort by confidence
    val detections = BitmapCompat.parseNmsObb(output, CONF_THRESHOLD, meta)

    // Step 7: Print summary matching Python format
    println("  Time: ${inferenceMs}ms | Detected: ${detections.size}")
    for (det in detections) {
        println(
            "    cls=${det.classId} " +
            "conf=${"%.3f".format(det.confidence)} " +
            "(${det.cx.toInt()},${det.cy.toInt()}) " +
            "${det.width.toInt()}x${det.height.toInt()} " +
            "angle=${"%.1f".format(det.angleDeg)}"
        )
    }

    // Step 8: Draw OBBs on the original (un-letterboxed) image
    val annotated = BitmapCompat.drawObbResults(src, detections, title = "TFLite Kotlin")

    // Step 9: Save annotated output
    // File name mirrors Python: tflite_{stem}.jpg → tflite_kotlin_{stem}.jpg
    val stem    = imageFile.nameWithoutExtension
    val outFile = File(outputDir, "tflite_kotlin_$stem.jpg")
    val saved   = ImageIO.write(annotated, "jpg", outFile)
    if (saved) {
        println("  -> ${outFile.absolutePath}")
    } else {
        System.err.println("  ERROR: javax.imageio could not write JPEG. Is a JPEG writer registered?")
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Load the TFLite model from [modelFile] using memory-mapped I/O.
 *
 * Uses [Interpreter(File, Options)] — the file-path constructor that requires
 * no Android Context. This is the desktop-JVM-compatible alternative to
 * [YoloObbDetector]'s asset-based loader.
 */
private fun loadInterpreter(modelFile: File): Interpreter {
    val opts = Interpreter.Options().apply {
        setNumThreads(NUM_THREADS)
        // To enable GPU delegate (requires tensorflow-lite-gpu on classpath):
        // addDelegate(GpuDelegate())
    }
    return Interpreter(modelFile, opts)
}

/**
 * Collect and sort image files from [dir] by file name (ascending).
 * Accepts .jpg, .jpeg, and .png extensions (case-insensitive).
 */
private fun collectImageFiles(dir: File): List<File> {
    val validExtensions = setOf("jpg", "jpeg", "png")
    return dir
        .listFiles { f -> f.extension.lowercase() in validExtensions }
        ?.sortedBy { it.name }
        ?: emptyList()
}

/** Print input/output tensor shapes for debugging model compatibility. */
private fun logTensorShapes(interpreter: Interpreter) {
    val inputShape  = interpreter.getInputTensor(0).shape()
    val outputShape = interpreter.getOutputTensor(0).shape()
    println("Input tensor shape:  ${inputShape.toList()}")
    println("Output tensor shape: ${outputShape.toList()}")
}
