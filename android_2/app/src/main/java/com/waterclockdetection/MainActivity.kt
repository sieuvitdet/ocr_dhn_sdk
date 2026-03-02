package com.waterclockdetection

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import android.util.Log
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import com.waterclockdetection.databinding.ActivityMainBinding
import com.waterclockdetection.detection.ObbDetection
import com.waterclockdetection.detection.YoloObbDetector
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {

    private lateinit var binding: ActivityMainBinding
    private lateinit var detector: YoloObbDetector

    private var currentBitmap: Bitmap? = null
    private var currentFileName: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Initialize detector
        detector = YoloObbDetector(
            context = this,
            modelAssetName = "best_float32.tflite",
            confThreshold = 0.02f,
            numThreads = 4
        )

        setupImageList()

        binding.btnDetect.setOnClickListener {
            currentBitmap?.let { runDetection(it) }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        detector.close()
    }

    private fun setupImageList() {
        val imageFiles = assets.list("test_images")
            ?.filter { it.lowercase().endsWith(".jpg") || it.lowercase().endsWith(".jpeg") || it.lowercase().endsWith(".png") }
            ?.sortedBy { name ->
                // Sort numerically: "1.jpg" before "10.jpg"
                name.substringBefore('.').toIntOrNull() ?: Int.MAX_VALUE
            }
            ?: emptyList()

        lifecycleScope.launch {
            val items = withContext(Dispatchers.IO) {
                imageFiles.map { fileName ->
                    val stream = assets.open("test_images/$fileName")
                    val opts = BitmapFactory.Options().apply {
                        inSampleSize = 4  // Load smaller thumbnails
                    }
                    val thumb = BitmapFactory.decodeStream(stream, null, opts)!!
                    stream.close()
                    TestImageAdapter.TestImageItem(fileName, thumb)
                }
            }

            val adapter = TestImageAdapter(items) { item ->
                onImageSelected(item.fileName)
            }

            binding.imageRecyclerView.layoutManager = LinearLayoutManager(
                this@MainActivity, LinearLayoutManager.HORIZONTAL, false
            )
            binding.imageRecyclerView.adapter = adapter
        }
    }

    private fun onImageSelected(fileName: String) {
        currentFileName = fileName
        binding.statusText.text = "Selected: $fileName"
        binding.resultsText.text = ""
        binding.btnDetect.isEnabled = false

        // Clear previous overlay
        binding.overlayView.setDetections(emptyList(), 1, 1)
        binding.overlayView.invalidate()

        // Load full-size image
        lifecycleScope.launch {
            val bitmap = withContext(Dispatchers.IO) {
                assets.open("test_images/$fileName").use { stream ->
                    BitmapFactory.decodeStream(stream)
                }
            }

            if (bitmap != null) {
                currentBitmap = bitmap
                binding.imageView.setImageBitmap(bitmap)
                binding.statusText.text = "$fileName (${bitmap.width}x${bitmap.height}) — tap Detect"
                binding.btnDetect.isEnabled = true
            }
        }
    }

    private fun runDetection(bitmap: Bitmap) {
        binding.btnDetect.isEnabled = false
        binding.statusText.text = "Detecting..."
        binding.resultsText.text = ""

        // Clear previous overlay
        binding.overlayView.setDetections(emptyList(), 1, 1)
        binding.overlayView.invalidate()

        lifecycleScope.launch {
            val t0 = System.currentTimeMillis()
            val detections = withContext(Dispatchers.Default) {
                detector.detect(bitmap)
            }
            val inferenceMs = System.currentTimeMillis() - t0

            showResults(detections, inferenceMs, bitmap.width, bitmap.height)
            binding.btnDetect.isEnabled = true
        }
    }

    private fun showResults(
        detections: List<ObbDetection>,
        inferenceMs: Long,
        imgW: Int,
        imgH: Int
    ) {
        // Update overlay — must wait for layout
        binding.overlayView.post {
            binding.overlayView.setDetections(detections, imgW, imgH)
            binding.overlayView.invalidate()
        }

        binding.statusText.text = "$currentFileName | ${detections.size} detections | ${inferenceMs}ms"

        if (detections.isEmpty()) {
            binding.resultsText.text = "No detections"
        } else {
            val sb = StringBuilder()
            for (det in detections) {
                sb.appendLine(
                    "cls=${det.classId} " +
                    "conf=${"%.3f".format(det.confidence)} " +
                    "(${det.cx.toInt()},${det.cy.toInt()}) " +
                    "${det.width.toInt()}x${det.height.toInt()} " +
                    "angle=${"%.1f".format(det.angleDeg)}"
                )
            }
            binding.resultsText.text = sb.toString()
        }

        Log.i(TAG, "$currentFileName: ${detections.size} detections in ${inferenceMs}ms")
    }

    companion object {
        private const val TAG = "MainActivity"
    }
}
