package com.example.water_meter_sdk

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

/**
 * OCR Pipeline using PaddleOCR models
 * Handles text detection and recognition
 */
class OCRPipeline(private val context: Context) {
    private val TAG = "OCRPipeline"
    
    // Model file names
    private val DET_MODEL_NAME = "ch_ppocr_mobile_v2.0_det_slim_opt.nb"
    private val CLS_MODEL_NAME = "ch_ppocr_mobile_v2.0_cls_slim_opt.nb"
    private val REC_MODEL_NAME = "ch_ppocr_mobile_v2.0_rec_slim_opt.nb"
    
    // Native OCR interface - you'll need to implement JNI bindings
    private var nativeHandle: Long = 0
    
    // Native method bindings
    private external fun nativeInit(detModelPath: String, clsModelPath: String, recModelPath: String): Long
    private external fun nativeDetectText(handle: Long, bitmap: Bitmap): Array<FloatArray>?
    private external fun nativeRecognizeText(handle: Long, bitmap: Bitmap): String?
    private external fun nativeDispose(handle: Long)
    
    companion object {
        init {
            try {
                System.loadLibrary("paddle_ocr") // Load native library
            } catch (e: UnsatisfiedLinkError) {
                Log.e("OCRPipeline", "Failed to load native library", e)
            }
        }
    }
    
    /**
     * Initialize OCR pipeline with PaddleOCR models
     */
    fun initialize() {
        try {
            Log.d(TAG, "Initializing OCR Pipeline...")
            
            // Copy models from assets to internal storage if needed
            val detModelPath = copyAssetToFile(DET_MODEL_NAME)
            val clsModelPath = copyAssetToFile(CLS_MODEL_NAME)
            val recModelPath = copyAssetToFile(REC_MODEL_NAME)
            
            // Initialize native OCR (JNI)
            nativeHandle = nativeInit(detModelPath, clsModelPath, recModelPath)
            
            if (nativeHandle == 0L) {
                throw RuntimeException("Failed to initialize native OCR")
            }
            
            Log.d(TAG, "OCR Pipeline initialized successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize OCR Pipeline", e)
            throw e
        }
    }
    
    /**
     * Detect text regions in image using real implementation
     */
    fun detectText(bitmap: Bitmap): List<TextDetection> {
        if (nativeHandle == 0L) {
            Log.e(TAG, "OCR not initialized")
            return emptyList()
        }
        
        try {
            // Call native detection (det + cls inside JNI)
            val detectionResults = nativeDetectText(nativeHandle, bitmap)
            
            val detections = mutableListOf<TextDetection>()
            
            detectionResults?.forEach { result ->
                if (result.size >= 9) { // 8 coordinates + confidence
                    val x1 = result[0]
                    val y1 = result[1]
                    val x2 = result[2]
                    val y2 = result[3]
                    val x3 = result[4]
                    val y3 = result[5]
                    val x4 = result[6]
                    val y4 = result[7]
                    val confidence = result[8]
                    
                    // Calculate bounding rect
                    val left = minOf(x1, x2, x3, x4).toInt()
                    val right = maxOf(x1, x2, x3, x4).toInt()
                    val top = minOf(y1, y2, y3, y4).toInt()
                    val bottom = maxOf(y1, y2, y3, y4).toInt()
                    
                    val bounds = Rect(left, top, right, bottom)
                    
                    detections.add(
                        TextDetection(
                            text = "", // Will be filled by recognition
                            confidence = confidence,
                            bounds = bounds
                        )
                    )
                }
            }
            
            Log.d(TAG, "Detected ${detections.size} text regions using real implementation")
            return detections
        } catch (e: Exception) {
            Log.e(TAG, "Error detecting text", e)
            return emptyList()
        }
    }
    
    /**
     * Recognize text in specific region using real implementation
     */
    fun recognizeText(bitmap: Bitmap, region: Rect): String? {
        if (nativeHandle == 0L) {
            Log.e(TAG, "OCR not initialized")
            return null
        }
        
        try {
            // Crop bitmap to region
            val croppedBitmap = cropBitmap(bitmap, region)
            
            // Use actual PaddleOCR recognition
            // This would call native PaddleOCR recognition method
            val recognizedText = nativeRecognizeText(nativeHandle, croppedBitmap)
            
            Log.d(TAG, "Recognized text: $recognizedText")
            return recognizedText
            
        } catch (e: Exception) {
            Log.e(TAG, "Error recognizing text", e)
            return null
        }
    }
    
    /**
     * Copy asset file to internal storage
     */
    private fun copyAssetToFile(assetName: String): String {
        val outFile = File(context.filesDir, assetName)
        
        if (outFile.exists()) {
            return outFile.absolutePath
        }
        
        try {
            val inputStream: InputStream = context.assets.open(assetName)
            val outputStream = FileOutputStream(outFile)
            
            val buffer = ByteArray(1024)
            var read: Int
            while (inputStream.read(buffer).also { read = it } != -1) {
                outputStream.write(buffer, 0, read)
            }
            
            inputStream.close()
            outputStream.close()
            
            Log.d(TAG, "Copied asset $assetName to ${outFile.absolutePath}")
            return outFile.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "Failed to copy asset $assetName", e)
            throw e
        }
    }
    
    /**
     * Crop bitmap to specific region
     */
    private fun cropBitmap(bitmap: Bitmap, region: Rect): Bitmap {
        val x = maxOf(0, region.left)
        val y = maxOf(0, region.top)
        val width = minOf(bitmap.width - x, region.width())
        val height = minOf(bitmap.height - y, region.height())
        
        return Bitmap.createBitmap(bitmap, x, y, width, height)
    }
    
    /**
     * Release resources
     */
    fun dispose() {
        if (nativeHandle != 0L) {
            nativeDispose(nativeHandle)
            nativeHandle = 0
        }
        Log.d(TAG, "OCR Pipeline disposed")
    }
    
    /**
     * Main processing method that combines detection and recognition
     */
    fun processImage(bitmap: Bitmap): String? {
        try {
            Log.d(TAG, "Processing image for water meter reading...")
            
            // Step 1: Detect text regions
            val detections = detectText(bitmap)
            if (detections.isEmpty()) {
                Log.d(TAG, "No text regions detected")
                return null
            }
            
            // Step 2: Recognize text in each detected region
            val recognizedTexts = mutableListOf<String>()
            for (detection in detections) {
                val text = recognizeText(bitmap, detection.bounds)
                if (!text.isNullOrEmpty()) {
                    recognizedTexts.add(text)
                }
            }
            
            // Step 3: Extract and format meter reading
            return extractMeterReading(recognizedTexts)
            
        } catch (e: Exception) {
            Log.e(TAG, "Error processing image", e)
            return null
        }
    }
    
    /**
     * Extract meter reading from recognized texts
     */
    private fun extractMeterReading(recognizedTexts: List<String>): String? {
        if (recognizedTexts.isEmpty()) return null
        
        // Combine all recognized texts and extract digits
        val combinedText = recognizedTexts.joinToString("")
        val digitsOnly = combinedText.filter { it.isDigit() }
        
        // Validate meter reading format (4-7 digits typically)
        return when {
            digitsOnly.length in 4..7 -> {
                Log.d(TAG, "Extracted meter reading: $digitsOnly")
                digitsOnly
            }
            digitsOnly.length > 7 -> {
                // Take first 7 digits if too long
                val truncated = digitsOnly.take(7)
                Log.d(TAG, "Extracted meter reading (truncated): $truncated")
                truncated
            }
            else -> {
                Log.w(TAG, "Invalid meter reading length: ${digitsOnly.length}")
                null
            }
        }
    }
    
    /**
     * Detect text regions and return as list of coordinate arrays
     */
    fun detectTextRegions(bitmap: Bitmap): List<List<Double>> {
        val detections = detectText(bitmap)
        return detections.map { detection ->
            val rect = detection.bounds
            // Return as 4-point polygon coordinates
            listOf(
                rect.left.toDouble(), rect.top.toDouble(),      // top-left
                rect.right.toDouble(), rect.top.toDouble(),     // top-right
                rect.right.toDouble(), rect.bottom.toDouble(),  // bottom-right
                rect.left.toDouble(), rect.bottom.toDouble()    // bottom-left
            )
        }
    }
    
    /**
     * Recognize text in specific regions
     */
    fun recognizeTextInRegions(bitmap: Bitmap, regions: List<List<Double>>): List<String> {
        val results = mutableListOf<String>()
        
        for (regionCoords in regions) {
            if (regionCoords.size >= 8) {
                // Convert coordinates to Rect
                val minX = regionCoords.filterIndexed { index, _ -> index % 2 == 0 }.minOrNull()?.toInt() ?: 0
                val maxX = regionCoords.filterIndexed { index, _ -> index % 2 == 0 }.maxOrNull()?.toInt() ?: bitmap.width
                val minY = regionCoords.filterIndexed { index, _ -> index % 2 == 1 }.minOrNull()?.toInt() ?: 0
                val maxY = regionCoords.filterIndexed { index, _ -> index % 2 == 1 }.maxOrNull()?.toInt() ?: bitmap.height
                
                val rect = Rect(minX, minY, maxX, maxY)
                val text = recognizeText(bitmap, rect)
                
                if (!text.isNullOrEmpty()) {
                    results.add(text)
                }
            }
        }
        
        return results
    }
}
