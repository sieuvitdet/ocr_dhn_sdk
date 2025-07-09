package com.example.water_meter_sdk

import android.content.Context
import android.graphics.BitmapFactory
import androidx.annotation.NonNull
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

/** WaterMeterSdkPlugin */
class WaterMeterSdkPlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel
  private lateinit var context: Context
  private lateinit var textRecognizer: TextRecognizer

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

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
