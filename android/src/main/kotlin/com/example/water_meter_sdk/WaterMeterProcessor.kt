package com.example.water_meter_sdk

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.util.Log

/**
 * Water Meter Processor for Android
 * Handles OCR processing using PaddleOCR models
 */
class WaterMeterProcessor(private val context: Context) {
    private val TAG = "WaterMeterProcessor"
    private var isInitialized = false
    
    // OCR pipeline components
    private var ocrPipeline: OCRPipeline? = null
    
    // Preprocess image: resize to target width and convert to grayscale
    private fun preprocess(bitmap: Bitmap): Bitmap {
        val targetWidth = 640
        val scale = targetWidth.toFloat() / bitmap.width
        val newHeight = (bitmap.height * scale).toInt()
        val resized = Bitmap.createScaledBitmap(bitmap, targetWidth, newHeight, true)
        val grayBitmap = Bitmap.createBitmap(resized.width, resized.height, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(grayBitmap)
        val paint = android.graphics.Paint()
        val colorMatrix = android.graphics.ColorMatrix().apply { setSaturation(0f) }
        paint.colorFilter = android.graphics.ColorMatrixColorFilter(colorMatrix)
        canvas.drawBitmap(resized, 0f, 0f, paint)
        return grayBitmap
    }
    
    /**
     * Initialize the processor with PaddleOCR models
     */
    fun initialize() {
        try {
            Log.d(TAG, "Initializing WaterMeterProcessor...")
            
            // Initialize OCR pipeline with models from assets
            ocrPipeline = OCRPipeline(context)
            ocrPipeline?.initialize()
            
            isInitialized = true
            Log.d(TAG, "WaterMeterProcessor initialized successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize WaterMeterProcessor", e)
            throw e
        }
    }
    
    /**
     * Process image and extract water meter reading
     */
    fun processImage(bitmap: Bitmap): Map<String, Any?>? {
        if (!isInitialized) {
            Log.e(TAG, "Processor not initialized")
            return null
        }
        
        val startTime = System.currentTimeMillis()
        
        try {
            // Step 1: Preprocess image for detection
            val prepped = preprocess(bitmap)
            val detections = ocrPipeline?.detectText(prepped) ?: emptyList()
            
            if (detections.isEmpty()) {
                return createResult(false, 0.0f, null, null, System.currentTimeMillis() - startTime)
            }
            
            // Step 2: Filter detections - keep reasonable regions
            val meterDetections = detections.filter { detection ->
                detection.confidence > 0.3f &&
                detection.bounds.width() > 50 &&
                detection.bounds.height() > 20
            }
            
            if (meterDetections.isEmpty()) {
                return createResult(false, 0.0f, null, null, System.currentTimeMillis() - startTime)
            }
            
            // Step 3: Extract text from meter regions
            val readings = mutableListOf<String>()
            var maxConfidence = 0.0f
            
            for (detection in meterDetections) {
                val rect = detection.bounds
                val text = ocrPipeline?.recognizeText(prepped, rect)
                if (!text.isNullOrEmpty()) {
                    // Keep only digit sequences of length 4 or 5
                    val digits = text.filter { it.isDigit() }
                    if (digits.length in 4..5) {
                        readings.add(digits)
                        maxConfidence = maxOf(maxConfidence, detection.confidence)
                    }
                }
            }
            
            // Step 4: Process and validate readings
            // Deduplicate and pick first as best reading
            val uniqueReadings = readings.distinct()
            val bestReading = uniqueReadings.firstOrNull()
            val meterType = determineMeterType(bestReading)
            
            val processingTime = System.currentTimeMillis() - startTime
            
            return createResult(
                isWaterMeter = bestReading != null,
                confidence = maxConfidence,
                reading = bestReading,
                meterType = meterType,
                processingTime = processingTime,
                textRegions = meterDetections.map { it.toMap() }
            )
            
        } catch (e: Exception) {
            Log.e(TAG, "Error processing image", e)
            return null
        }
    }
    
    /**
     * Detect water meter regions only
     */
    fun detectMeterRegions(bitmap: Bitmap): List<Map<String, Any>>? {
        if (!isInitialized) {
            Log.e(TAG, "Processor not initialized")
            return null
        }
        
        try {
            // Preprocess image for detection
            val prepped = preprocess(bitmap)
            val detections = ocrPipeline?.detectText(prepped) ?: emptyList()
            val meterDetections = filterWaterMeterDetections(detections)
            return meterDetections.map { it.toMap() }
        } catch (e: Exception) {
            Log.e(TAG, "Error detecting meter regions", e)
            return null
        }
    }
    
    /**
     * Recognize text in specific regions
     */
    fun recognizeTextInRegions(bitmap: Bitmap, regions: List<List<Double>>): List<String>? {
        if (!isInitialized) {
            Log.e(TAG, "Processor not initialized")
            return null
        }
        
        try {
            // Use preprocessed image for recognition as well
            val prepped = preprocess(bitmap)
            val results = mutableListOf<String>()
            
            for (region in regions) {
                if (region.size >= 4) {
                    val rect = Rect(
                        region[0].toInt(),
                        region[1].toInt(),
                        (region[0] + region[2]).toInt(),
                        (region[1] + region[3]).toInt()
                    )
                    val text = ocrPipeline?.recognizeText(prepped, rect)
                    if (!text.isNullOrEmpty()) {
                        results.add(text)
                    }
                }
            }
            
            return results
        } catch (e: Exception) {
            Log.e(TAG, "Error recognizing text in regions", e)
            return null
        }
    }
    
    /**
     * Filter detections that likely contain water meter readings
     */
    private fun filterWaterMeterDetections(detections: List<TextDetection>): List<TextDetection> {
        return detections.filter { detection ->
            // Filter criteria for water meter readings:
            // 1. Confidence above threshold
            // 2. Text contains digits
            // 3. Reasonable size and aspect ratio
            detection.confidence > 0.3f &&
            detection.text.any { it.isDigit() } &&
            detection.bounds.width() > 50 &&
            detection.bounds.height() > 20
        }
    }
    
    /**
     * Determine meter type based on reading
     */
    private fun determineMeterType(reading: String?): Int? {
        if (reading == null) return null
        
        val digitCount = reading.count { it.isDigit() }
        return when {
            digitCount <= 4 -> 0 // fourDigit
            digitCount >= 7 -> 1 // sevenDigit
            else -> 2 // unknown
        }
    }
    
    /**
     * Create result map
     */
    private fun createResult(
        isWaterMeter: Boolean,
        confidence: Float,
        reading: String?,
        meterType: Int?,
        processingTime: Long,
        textRegions: List<Map<String, Any>>? = null
    ): Map<String, Any?> {
        return mapOf(
            "isWaterMeter" to isWaterMeter,
            "confidence" to confidence,
            "reading" to reading,
            "meterType" to meterType,
            "processingTime" to processingTime,
            "textRegions" to textRegions
        )
    }
    
    /**
     * Release resources
     */
    fun dispose() {
        ocrPipeline?.dispose()
        ocrPipeline = null
        isInitialized = false
        Log.d(TAG, "WaterMeterProcessor disposed")
    }
    
    /**
     * Check if processor is initialized
     */
    fun isInitialized(): Boolean = isInitialized
}

/**
 * Data class for text detection results
 */
data class TextDetection(
    val text: String,
    val confidence: Float,
    val bounds: Rect
) {
    fun toMap(): Map<String, Any> = mapOf(
        "text" to text,
        "confidence" to confidence,
        "bounds" to listOf(bounds.left, bounds.top, bounds.width(), bounds.height())
    )
}
