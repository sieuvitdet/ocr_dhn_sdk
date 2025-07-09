#include <jni.h>
#include <android/log.h>
#include <android/bitmap.h>
#include <string>
#include <vector>
#include "onnxruntime_cxx_api.h"

#define TAG "PaddleOCR_JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

extern "C" {

// ONNX Runtime global environment
static Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "WaterOCR");

// Native handle structure with ONNX sessions
struct OCRHandle {
    Ort::Session* detSession;
    Ort::Session* clsSession;
    Ort::Session* recSession;
};

JNIEXPORT jlong JNICALL
Java_com_example_flutter_1water_1meter_1ocr_OCRPipeline_nativeInit(
    JNIEnv *envJ, jobject thiz, jstring detModelPath, jstring clsModelPath, jstring recModelPath) {
    const char *detPath = envJ->GetStringUTFChars(detModelPath, nullptr);
    const char *clsPath = envJ->GetStringUTFChars(clsModelPath, nullptr);
    const char *recPath = envJ->GetStringUTFChars(recModelPath, nullptr);
    LOGI("Initializing OCR with models: det=%s, cls=%s, rec=%s", detPath, clsPath, recPath);
    
    try {
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(1);
        OCRHandle* handle = new OCRHandle();
        handle->detSession = new Ort::Session(::env, detPath, options);
        handle->clsSession = new Ort::Session(::env, clsPath, options);
        handle->recSession = new Ort::Session(::env, recPath, options);
        
        envJ->ReleaseStringUTFChars(detModelPath, detPath);
        envJ->ReleaseStringUTFChars(clsModelPath, clsPath);
        envJ->ReleaseStringUTFChars(recModelPath, recPath);
        
        LOGI("OCR initialized successfully via ONNX Runtime");
        return reinterpret_cast<jlong>(handle);
    } catch (const std::exception& e) {
        LOGE("Failed to initialize OCR: %s", e.what());
        envJ->ReleaseStringUTFChars(detModelPath, detPath);
        envJ->ReleaseStringUTFChars(clsModelPath, clsPath);
        envJ->ReleaseStringUTFChars(recModelPath, recPath);
        return 0;
    }
}

JNIEXPORT jobjectArray JNICALL
Java_com_example_flutter_1water_1meter_1ocr_OCRPipeline_nativeDetectText(
    JNIEnv *envJ, jobject thiz, jlong handle, jobject bitmap) {
    if (!handle) return nullptr;
    auto* h = reinterpret_cast<OCRHandle*>(handle);
    
    try {
        // Convert Android Bitmap to float tensor
        AndroidBitmapInfo info;
        void* pixels;
        AndroidBitmap_getInfo(envJ, bitmap, &info);
        AndroidBitmap_lockPixels(envJ, bitmap, &pixels);
        int width = info.width, height = info.height;
        
        // Convert RGBA bitmap to RGB CHW float32 tensor
        std::vector<float> inputTensor(3 * height * width);
        uint32_t* rgbaPixels = static_cast<uint32_t*>(pixels);
        
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                uint32_t pixel = rgbaPixels[y * width + x];
                uint8_t r = (pixel >> 16) & 0xFF;
                uint8_t g = (pixel >> 8) & 0xFF;
                uint8_t b = pixel & 0xFF;
                
                // Normalize to [0,1] and arrange in CHW format
                int idx = y * width + x;
                inputTensor[0 * height * width + idx] = r / 255.0f;
                inputTensor[1 * height * width + idx] = g / 255.0f;
                inputTensor[2 * height * width + idx] = b / 255.0f;
            }
        }
        AndroidBitmap_unlockPixels(envJ, bitmap);
        
        // Create ONNX tensor
        std::array<int64_t, 4> dims = {1, 3, height, width};
        Ort::Value input = Ort::Value::CreateTensor<float>(env.GetAllocatorWithDefaultOptions(), inputTensor.data(), inputTensor.size(), dims.data(), dims.size());
        
        // Run detection session
        const char* inputName = h->detSession->GetInputName(0, env.GetAllocatorWithDefaultOptions());
        auto output = h->detSession->Run(Ort::RunOptions{nullptr}, &inputName, &input, 1, h->detSession->GetOutputNames(nullptr), h->detSession->GetOutputCount());
        
        // Parse detection output tensor into bounding boxes
        float* outputData = output[0].GetTensorMutableData<float>();
        auto outputShape = output[0].GetTensorTypeAndShapeInfo().GetShape();
        
        std::vector<std::vector<float>> dets;
        // Assuming output shape is [1, N, 9] where N is number of detections
        if (outputShape.size() >= 3) {
            int numDets = outputShape[1];
            int featDim = outputShape[2];
            
            for (int i = 0; i < numDets; i++) {
                std::vector<float> detection;
                for (int j = 0; j < featDim; j++) {
                    detection.push_back(outputData[i * featDim + j]);
                }
                // Filter by confidence threshold
                if (detection.size() > 8 && detection[8] > 0.5f) {
                    dets.push_back(detection);
                }
            }
        }
        
        // Convert to Java float[][] array
        jclass floatArrayClass = envJ->FindClass("[F");
        jobjectArray outer = envJ->NewObjectArray(dets.size(), floatArrayClass, nullptr);
        for (size_t i = 0; i < dets.size(); ++i) {
            jfloatArray inner = envJ->NewFloatArray(dets[i].size());
            envJ->SetFloatArrayRegion(inner, 0, dets[i].size(), dets[i].data());
            envJ->SetObjectArrayElement(outer, i, inner);
        }
        return outer;
    } catch (const std::exception& e) {
        LOGE("Error in nativeDetectText: %s", e.what());
        return nullptr;
    }
}

JNIEXPORT jstring JNICALL
Java_com_example_flutter_1water_1meter_1ocr_OCRPipeline_nativeRecognizeText(
    JNIEnv *envJ, jobject thiz, jlong handle, jobject bitmap) {
    if (!handle) return nullptr;
    auto* h = reinterpret_cast<OCRHandle*>(handle);
    
    try {
        // Convert bitmap to tensor for recognition
        AndroidBitmapInfo info;
        void* pixels;
        AndroidBitmap_getInfo(envJ, bitmap, &info);
        AndroidBitmap_lockPixels(envJ, bitmap, &pixels);
        int width = info.width, height = info.height;
        
        // Convert to CHW float32 tensor (same as detection)
        std::vector<float> inputTensor(3 * height * width);
        uint32_t* rgbaPixels = static_cast<uint32_t*>(pixels);
        
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                uint32_t pixel = rgbaPixels[y * width + x];
                uint8_t r = (pixel >> 16) & 0xFF;
                uint8_t g = (pixel >> 8) & 0xFF;
                uint8_t b = pixel & 0xFF;
                
                int idx = y * width + x;
                inputTensor[0 * height * width + idx] = r / 255.0f;
                inputTensor[1 * height * width + idx] = g / 255.0f;
                inputTensor[2 * height * width + idx] = b / 255.0f;
            }
        }
        AndroidBitmap_unlockPixels(envJ, bitmap);
        
        // Create ONNX tensor and run recognition
        std::array<int64_t, 4> dims = {1, 3, height, width};
        Ort::Value input = Ort::Value::CreateTensor<float>(env.GetAllocatorWithDefaultOptions(), inputTensor.data(), inputTensor.size(), dims.data(), dims.size());
        
        const char* inputName = h->recSession->GetInputName(0, env.GetAllocatorWithDefaultOptions());
        auto output = h->recSession->Run(Ort::RunOptions{nullptr}, &inputName, &input, 1, h->recSession->GetOutputNames(nullptr), h->recSession->GetOutputCount());
        
        // Decode recognition output (CTC or attention-based)
        // For now, return placeholder - implement CTC decoding based on your model
        std::string result = "123456"; // Mock water meter reading
        return envJ->NewStringUTF(result.c_str());
    } catch (const std::exception& e) {
        LOGE("Error in nativeRecognizeText: %s", e.what());
        return nullptr;
    }
}

JNIEXPORT void JNICALL
Java_com_example_flutter_1water_1meter_1ocr_OCRPipeline_nativeDispose(
    JNIEnv *envJ, jobject thiz, jlong handle) {
    if (!handle) return;
    auto* h = reinterpret_cast<OCRHandle*>(handle);
    delete h->detSession;
    delete h->clsSession;
    delete h->recSession;
    delete h;
    LOGI("OCR resources disposed via ONNX Runtime");
}

} // extern "C"
