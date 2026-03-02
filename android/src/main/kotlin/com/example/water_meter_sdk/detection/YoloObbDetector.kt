package com.example.water_meter_sdk.detection

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.io.IOException
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * Full TFLite OBB detection pipeline implementing [ObbDetector].
 *
 * Pipeline stages:
 *   1. Letterbox [Bitmap] to 640×640 with gray padding ([BitmapPreprocessor.letterbox])
 *   2. Convert to float32 NHWC [ByteBuffer] ([BitmapPreprocessor.toByteBuffer])
 *   3. Run TFLite inference ([Interpreter.run])
 *   4. Parse raw output to [ObbDetection] list ([ObbPostProcessor.parse])
 *
 * @param context         Android context used to load the model asset.
 * @param modelAssetName  Filename of the TFLite model in app/assets/ (default: "best_float32.tflite").
 * @param confThreshold   Minimum confidence score for detections (default: 0.25).
 * @param numThreads      Number of CPU threads for TFLite inference (default: 4).
 */
class YoloObbDetector(
    context: Context,
    modelAssetName: String = "best_float32.tflite",
    private val confThreshold: Float = 0.25f,
    numThreads: Int = 4
) : ObbDetector {

    private val TAG = "YoloObbDetector"
    private val interpreter: Interpreter

    init {
        val opts = Interpreter.Options().apply {
            setNumThreads(numThreads)
        }
        val modelBuffer = loadModelFile(context, modelAssetName)
        interpreter = Interpreter(modelBuffer, opts)
        Log.i(TAG, "Loaded model '$modelAssetName' with $numThreads threads, confThreshold=$confThreshold")
        logTensorShapes()
    }

    /**
     * Run OBB detection on the given bitmap.
     *
     * @param bitmap Source image of any size. Letterboxing is applied internally.
     * @return Detections in original [bitmap] coordinate space, sorted by confidence descending.
     */
    override fun detect(bitmap: Bitmap): List<ObbDetection> {
        // Step 1: Letterbox to 640×640
        val (paddedBitmap, meta) = BitmapPreprocessor.letterbox(bitmap)

        // Step 2: Convert to float32 ByteBuffer; recycle intermediate bitmap immediately
        val inputBuffer = BitmapPreprocessor.toByteBuffer(paddedBitmap)
        paddedBitmap.recycle()

        // Step 3: Allocate output buffer — query shape at runtime to support variable maxDet
        // Expected shape: [1, maxDet, 7]
        val outputShape = interpreter.getOutputTensor(0).shape()
        val maxDet = outputShape[1]
        val output = Array(1) { Array(maxDet) { FloatArray(ObbPostProcessor.OUTPUT_FIELDS) } }

        Log.d(TAG, "Running inference on ${bitmap.width}x${bitmap.height} bitmap, maxDet=$maxDet")

        // Step 4: Run inference (synchronous)
        interpreter.run(inputBuffer, output)

        // Step 5: Parse and return detections in original image space
        return ObbPostProcessor.parse(output, meta, confThreshold)
    }

    /**
     * Release the TFLite interpreter and its native resources.
     */
    override fun close() {
        interpreter.close()
        Log.i(TAG, "Interpreter closed")
    }

    /**
     * Load a TFLite model from the app's assets directory using memory-mapped I/O.
     */
    @Throws(IOException::class)
    private fun loadModelFile(context: Context, assetName: String): MappedByteBuffer {
        val fd = context.assets.openFd(assetName)
        val stream = FileInputStream(fd.fileDescriptor)
        return stream.channel.map(FileChannel.MapMode.READ_ONLY, fd.startOffset, fd.declaredLength)
    }

    /** Log input/output tensor shapes for debugging model compatibility. */
    private fun logTensorShapes() {
        val inputShape = interpreter.getInputTensor(0).shape()
        val outputShape = interpreter.getOutputTensor(0).shape()
        Log.d(TAG, "Input tensor shape: ${inputShape.toList()}")
        Log.d(TAG, "Output tensor shape: ${outputShape.toList()}")
    }
}
