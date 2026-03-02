package com.waterclockdetection.detection

/**
 * Single OBB detection result, mapped back to ORIGINAL image coordinate space.
 *
 * @param classId    Integer class index from model output field class_id
 * @param confidence 0.0–1.0 confidence score from model
 * @param cx         Center X in original image pixels
 * @param cy         Center Y in original image pixels
 * @param width      Box width in original image pixels
 * @param height     Box height in original image pixels
 * @param angleDeg   Rotation angle in degrees (converted from model's angle_rad)
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
     * Equivalent to cv2.boxPoints((cx, cy), (w, h), angle) in Python.
     *
     * @return FloatArray of 8 floats: [x0,y0, x1,y1, x2,y2, x3,y3]
     *         in order: top-right, top-left, bottom-left, bottom-right
     */
    fun corners(): FloatArray {
        val rad = Math.toRadians(angleDeg.toDouble())
        val cosA = Math.cos(rad).toFloat()
        val sinA = Math.sin(rad).toFloat()
        val hw = width / 2f
        val hh = height / 2f

        // cv2.boxPoints equivalent: rotate each corner offset (±hw, ±hh) by angle
        // Rotation matrix: [cos, -sin; sin, cos]
        // corner = center + R * offset
        return floatArrayOf(
            cx + cosA * hw - sinA * (-hh), cy + sinA * hw + cosA * (-hh),  // (+hw, -hh)
            cx + cosA * (-hw) - sinA * (-hh), cy + sinA * (-hw) + cosA * (-hh),  // (-hw, -hh)
            cx + cosA * (-hw) - sinA * hh, cy + sinA * (-hw) + cosA * hh,  // (-hw, +hh)
            cx + cosA * hw - sinA * hh, cy + sinA * hw + cosA * hh   // (+hw, +hh)
        )
    }
}
