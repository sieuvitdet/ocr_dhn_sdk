package com.example.water_meter_sdk.detection

/**
 * Metadata captured during letterbox preprocessing.
 *
 * Used by [ObbPostProcessor] to invert the letterbox transform and map
 * model output coordinates back to the original image coordinate space.
 *
 * @param scale      Uniform resize scale applied to the original image (min of h_scale, w_scale)
 * @param padTop     Top padding in pixels applied in the 640x640 letterboxed space
 * @param padLeft    Left padding in pixels applied in the 640x640 letterboxed space
 * @param origWidth  Width of the original source image in pixels
 * @param origHeight Height of the original source image in pixels
 */
data class LetterboxMeta(
    val scale: Float,
    val padTop: Int,
    val padLeft: Int,
    val origWidth: Int,
    val origHeight: Int
)
