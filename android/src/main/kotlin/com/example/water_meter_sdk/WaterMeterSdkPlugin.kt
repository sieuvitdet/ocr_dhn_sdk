package com.example.water_meter_sdk

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.Log
import androidx.annotation.NonNull
import com.example.water_meter_sdk.detection.ObbDetection
import com.example.water_meter_sdk.detection.YoloObbDetector
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.io.File

/** WaterMeterSdkPlugin */
class WaterMeterSdkPlugin: FlutterPlugin, MethodCallHandler {
  private val TAG = "WaterMeterSdkPlugin"

  private lateinit var channel : MethodChannel
  private lateinit var context: Context
  private lateinit var textRecognizer: TextRecognizer
  private var obbDetector: YoloObbDetector? = null

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "water_meter_sdk")
    context = flutterPluginBinding.applicationContext
    textRecognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
      "getPlatformVersion" -> {
        result.success("Android ${android.os.Build.VERSION.RELEASE}")
      }
      "processImage" -> {
        val imagePath = call.argument<String>("imagePath")
        if (imagePath == null) {
          result.error("INVALID_ARGUMENTS", "Missing imagePath", null)
          return
        }
        processImage(imagePath, result)
      }
      "detectObb" -> {
        val imageBytes = call.argument<ByteArray>("imageBytes")
        if (imageBytes == null) {
          result.error("INVALID_ARGUMENTS", "Missing imageBytes", null)
          return
        }
        detectObb(imageBytes, result)
      }
      else -> {
        result.notImplemented()
      }
    }
  }

  private fun processImage(imagePath: String, result: Result) {
    try {
      val file = File(imagePath)
      if (!file.exists()) {
        result.error("FILE_NOT_FOUND", "Image file not found", null)
        return
      }

      val bitmap = BitmapFactory.decodeFile(imagePath)
      val image = InputImage.fromBitmap(bitmap, 0)

      textRecognizer.process(image)
        .addOnSuccessListener { visionText ->
          // Process the text
          val allText = StringBuilder()
          var totalConfidence = 0f
          var blockCount = 0

          for (block in visionText.textBlocks) {
            allText.append(block.text).append(" ")
            blockCount++
            // Confidence is not directly available in ML Kit for Android
            // We'll use a default high confidence for detected text
            totalConfidence += 0.95f
          }

          // Extract numbers from the text
          val numbers = allText.toString().replace(Regex("[^0-9]"), "")
          
          val avgConfidence = if (blockCount > 0) totalConfidence / blockCount else 0f

          val resultMap = hashMapOf(
            "reading" to numbers,
            "confidence" to avgConfidence,
            "debugInfo" to allText.toString()
          )

          result.success(resultMap)
        }
        .addOnFailureListener { e ->
          result.error("PROCESSING_ERROR", e.localizedMessage, null)
        }

    } catch (e: Exception) {
      result.error("PROCESSING_ERROR", e.localizedMessage, null)
    }
  }

  private fun detectObb(imageBytes: ByteArray, result: Result) {
    val logs = mutableListOf<String>()
    try {
      // Decode bitmap from bytes
      val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
      if (bitmap == null) {
        result.error("DECODE_ERROR", "Failed to decode image bytes", null)
        return
      }
      logs.add("Decoded bitmap: ${bitmap.width}x${bitmap.height}")

      // Initialize detector lazily (singleton)
      if (obbDetector == null) {
        logs.add("Initializing YoloObbDetector...")
        obbDetector = YoloObbDetector(context)
        logs.add("YoloObbDetector initialized")
      }

      // Run detection
      logs.add("Running OBB detection...")
      val detections = obbDetector!!.detect(bitmap)
      logs.add("Found ${detections.size} detections")

      // Draw bounding boxes on a copy
      val annotated = bitmap.copy(Bitmap.Config.ARGB_8888, true)
      val canvas = Canvas(annotated)
      val boxPaint = Paint().apply {
        style = Paint.Style.STROKE
        strokeWidth = 3f
        color = Color.GREEN
      }
      val cornerPaint = Paint().apply {
        style = Paint.Style.FILL
        color = Color.RED
      }

      for (det in detections) {
        val corners = det.corners()
        val path = Path()
        path.moveTo(corners[0], corners[1])
        path.lineTo(corners[2], corners[3])
        path.lineTo(corners[4], corners[5])
        path.lineTo(corners[6], corners[7])
        path.close()
        canvas.drawPath(path, boxPaint)

        // Draw corner circles
        for (i in 0 until 4) {
          canvas.drawCircle(corners[i * 2], corners[i * 2 + 1], 5f, cornerPaint)
        }
      }

      // Compress annotated image to PNG bytes
      val annotatedStream = ByteArrayOutputStream()
      annotated.compress(Bitmap.CompressFormat.PNG, 100, annotatedStream)
      val annotatedPngBytes = annotatedStream.toByteArray()
      annotated.recycle()

      // Crop the highest-confidence detection (axis-aligned bounding rect)
      var croppedPngBytes: ByteArray? = null
      if (detections.isNotEmpty()) {
        val best = detections[0]
        val corners = best.corners()

        var minX = Float.MAX_VALUE
        var maxX = Float.MIN_VALUE
        var minY = Float.MAX_VALUE
        var maxY = Float.MIN_VALUE
        for (i in 0 until 4) {
          val x = corners[i * 2]
          val y = corners[i * 2 + 1]
          if (x < minX) minX = x
          if (x > maxX) maxX = x
          if (y < minY) minY = y
          if (y > maxY) maxY = y
        }

        // Clamp to bitmap bounds
        val cropLeft = maxOf(0, minX.toInt())
        val cropTop = maxOf(0, minY.toInt())
        val cropRight = minOf(bitmap.width, maxX.toInt() + 1)
        val cropBottom = minOf(bitmap.height, maxY.toInt() + 1)
        val cropW = cropRight - cropLeft
        val cropH = cropBottom - cropTop

        if (cropW > 0 && cropH > 0) {
          val cropped = Bitmap.createBitmap(bitmap, cropLeft, cropTop, cropW, cropH)
          val croppedStream = ByteArrayOutputStream()
          cropped.compress(Bitmap.CompressFormat.PNG, 100, croppedStream)
          croppedPngBytes = croppedStream.toByteArray()
          cropped.recycle()
          logs.add("Cropped best detection: ${cropW}x${cropH} at ($cropLeft,$cropTop)")
        }
      }

      // Build detection maps for Flutter
      val detectionMaps = detections.map { det ->
        val corners = det.corners()
        hashMapOf<String, Any>(
          "classId" to det.classId,
          "confidence" to det.confidence.toDouble(),
          "cx" to det.cx.toDouble(),
          "cy" to det.cy.toDouble(),
          "width" to det.width.toDouble(),
          "height" to det.height.toDouble(),
          "angleDeg" to det.angleDeg.toDouble(),
          "corners" to corners.map { it.toDouble() }
        )
      }

      val origWidth = bitmap.width
      val origHeight = bitmap.height
      bitmap.recycle()

      val resultMap = hashMapOf<String, Any?>(
        "detections" to detectionMaps,
        "annotatedImage" to annotatedPngBytes,
        "croppedImage" to croppedPngBytes,
        "origWidth" to origWidth,
        "origHeight" to origHeight,
        "logs" to logs
      )

      result.success(resultMap)
    } catch (e: Exception) {
      Log.e(TAG, "detectObb error", e)
      logs.add("ERROR: ${e.message}")
      result.error("DETECT_OBB_ERROR", e.message, logs)
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    obbDetector?.close()
    obbDetector = null
  }
}
