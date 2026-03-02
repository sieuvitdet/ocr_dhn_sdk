package com.example.water_meter_sdk.detection

import android.util.Log
import kotlin.math.roundToInt

/**
 * Parses raw TFLite output into a filtered, sorted [List] of [ObbDetection].
 *
 * Model output shape: (1, maxDet, 7)
 * Field layout per detection row: [x, y, w, h, confidence, class_id, angle_rad]
 * Coordinates are normalized 0–1 in the 640×640 letterboxed space (TFLite post-NMS variant).
 *
 * Python equivalent (test_models.py): parse_nms_obb() with normalized=True
 */
object ObbPostProcessor {

    private const val TAG = "ObbPostProcessor"

    const val IMGSZ = 640f
    const val OUTPUT_FIELDS = 7

    // Field indices within each detection row
    private const val IDX_X = 0
    private const val IDX_Y = 1
    private const val IDX_W = 2
    private const val IDX_H = 3
    private const val IDX_CONF = 4
    private const val IDX_CLS = 5
    private const val IDX_ANGLE = 6

    /**
     * Parse raw TFLite output into [ObbDetection] objects in original image space.
     *
     * Steps:
     * 1. Filter detections below [confThresh].
     * 2. Denormalize coordinates from 0–1 to 640×640 pixel space.
     * 3. Invert the letterbox transform (remove padding, undo scale).
     * 4. Convert angle from radians to degrees.
     * 5. Sort by confidence descending.
     *
     * @param output     Raw float array of shape [1][maxDet][7] from TFLite interpreter.
     * @param meta       [LetterboxMeta] from preprocessing, used for inverse transform.
     * @param confThresh Minimum confidence to include a detection (default 0.25).
     * @return List of [ObbDetection] in original image pixel coordinates, confidence descending.
     */
    fun parse(
        output: Array<Array<FloatArray>>,
        meta: LetterboxMeta,
        confThresh: Float = 0.25f
    ): List<ObbDetection> {
        require(output.isNotEmpty() && output[0].isNotEmpty()) {
            "Output tensor must have shape [1][maxDet][7], got empty array"
        }
        require(output[0][0].size == OUTPUT_FIELDS) {
            "Expected $OUTPUT_FIELDS output fields per detection, got ${output[0][0].size}"
        }

        val detections = output[0]   // shape: (maxDet, 7)
        val results = mutableListOf<ObbDetection>()

        for (det in detections) {
            val conf = det[IDX_CONF]
            if (conf < confThresh) continue

            // Step 1: Denormalize from 0–1 to 640×640 pixel space
            val px = det[IDX_X] * IMGSZ
            val py = det[IDX_Y] * IMGSZ
            val pw = det[IDX_W] * IMGSZ
            val ph = det[IDX_H] * IMGSZ

            // Step 2: Invert letterbox — remove padding offset and undo scale
            val cx = (px - meta.padLeft) / meta.scale
            val cy = (py - meta.padTop) / meta.scale
            val bw = pw / meta.scale
            val bh = ph / meta.scale

            // Step 3: Convert angle from radians to degrees
            val angleDeg = Math.toDegrees(det[IDX_ANGLE].toDouble()).toFloat()

            results.add(
                ObbDetection(
                    classId = det[IDX_CLS].roundToInt(),
                    confidence = conf,
                    cx = cx,
                    cy = cy,
                    width = bw,
                    height = bh,
                    angleDeg = angleDeg
                )
            )
        }

        Log.d(TAG, "Parsed ${results.size} detections above conf=$confThresh")
        return results.sortedByDescending { it.confidence }
    }
}
