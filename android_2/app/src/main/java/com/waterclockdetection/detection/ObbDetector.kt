package com.waterclockdetection.detection

import android.graphics.Bitmap

/**
 * Contract for the OBB (Oriented Bounding Box) detection pipeline.
 *
 * Implementations handle the full pipeline: preprocessing, inference, and postprocessing.
 * Extends [AutoCloseable] because implementations hold native resources (e.g. TFLite Interpreter)
 * that must be released explicitly. Use with `use {}` or call [close] when done.
 *
 * Example:
 * ```kotlin
 * YoloObbDetector(context).use { detector ->
 *     val detections = detector.detect(bitmap)
 * }
 * ```
 */
interface ObbDetector : AutoCloseable {
    /**
     * Run OBB detection on the given bitmap.
     *
     * This operation is CPU-intensive and synchronous. Always call from a background thread
     * (e.g. [kotlinx.coroutines.Dispatchers.Default]) to avoid blocking the main thread.
     *
     * @param bitmap Source image to run detection on. Any size; letterboxing is applied internally.
     * @return List of [ObbDetection] in ORIGINAL bitmap coordinate space, sorted by confidence desc.
     */
    fun detect(bitmap: Bitmap): List<ObbDetection>
}
