# Water Meter SDK Flutter - Complete Architecture Scout Report

**Date:** 2026-03-01 | **Project:** ocr_dhn_sdk | **Branch:** 1.0.7

---

## Executive Summary

Water Meter SDK is a **Flutter federated plugin** that detects and reads water meter dials from images using:
1. **YOLO OBB (Oriented Bounding Box)** detection to locate the meter display
2. **OCR** (local Google ML Kit or remote API) to extract numeric readings

The project uses a **local fork of ultralytics_yolo** (in `packages/ultralytics_yolo/`) with custom Android/iOS implementations for YOLO inference.

---

## 1. Dependency Configuration & Package Overrides

### Root `pubspec.yaml`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/pubspec.yaml`

```yaml
dependencies:
  flutter:
  plugin_platform_interface: ^2.0.2
  google_mlkit_text_recognition: ^0.15.0
  image: ^4.1.7
  camera: ^0.10.5+9
  path_provider: ^2.1.2
  permission_handler: ^11.3.0
  tflite_flutter: ^0.11.0
  http: ^1.4.0
  vector_math: ^2.1.4
  fluttertoast: ^8.2.5
  ultralytics_yolo: ^0.2.0
  image_picker: ^1.0.7

dependency_overrides:
  ultralytics_yolo:
    path: packages/ultralytics_yolo  # ← LOCAL FORK OVERRIDE
```

**Key insight:** The `dependency_overrides` section forces Flutter to use the local forked version instead of the pub.dev package.

### Example App `pubspec.yaml`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/example/pubspec.yaml`

Depends on `water_meter_sdk` (parent plugin) via `path: ../`. Also lists `ultralytics_yolo: ^0.2.0` explicitly (inherits override from parent).

---

## 2. Plugin Architecture (Federated Pattern)

### Platform Interface Layer
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/lib/water_meter_sdk_platform_interface.dart`
- Abstract class defining `processImage()` method
- Used for both Android & iOS implementations

### Method Channel Implementation
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/lib/water_meter_sdk_method_channel.dart`
- Routes calls to native platform code via `water_meter_sdk` channel

### Active Main SDK Class
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/lib/water_meter_sdk_ultralytics_yolo.dart` (MAIN)

Previously used class (mostly commented out):
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/lib/water_meter_sdk.dart` (DEPRECATED)

---

## 3. Data Flow: Image → YOLO Detection → Crop → OCR

### Entry Point: `WaterMeterSdkUltralyticsYolo`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/lib/water_meter_sdk_ultralytics_yolo.dart`

#### Initialization
```dart
Future init() async {
  yolo = YOLO(
    modelPath: 'yolo11n-obb',  // No file extension (framework handles it)
    task: YOLOTask.obb,
  );
  await yolo.loadModel();
}
```

#### Main Processing Pipeline
```dart
Future<WaterMeterResult?> processWaterMeterImage(Uint8List imageBytes, {bool isOnline = false}) async {
  // Step 1: YOLO OBB detection + crop
  Uint8List croppedBytes = Platform.isAndroid 
    ? await runOBBDetectionAndCropAndroid(imageBytes)
    : await runOBBDetectionAndCropIOS(imageBytes);
  
  // Step 2: OCR (online or local)
  if (isOnline) {
    // Send to remote API: super-agent-api.meobeo.ai/water-clock-ocr
    return await GetNumberOCR().ocrImage(tempFile);
  } else {
    // Use local Google ML Kit
    return await _ocrService.processImage(croppedBytes);
  }
}
```

### Step 1: YOLO OBB Detection & Cropping

#### A. Image Resizing
Both platforms resize to **416x416** before YOLO inference.

#### B. Android Path: `runOBBDetectionAndCropAndroid()`
```dart
1. Decode image bytes → img.Image
2. Resize to 416x416
3. Call yolo.predict(resizedBytes)
4. Extract OBB list from results['obb']
5. Filter detections:
   - Must have 4 points (normalized [0..1])
   - Confidence must be 0.2 < conf < 1.0
6. Select highest confidence detection
7. Crop using cropImageFromOBB() (rotates & extracts region)
```

#### C. iOS Path: `runOBBDetectionAndCropIOS()`
```dart
1. Similar to Android but uses raw pixel coordinates from YOLO
2. Does NOT filter by confidence range (accepts all valid detections)
3. Takes first valid detection with 4 points
```

#### D. OBB Cropping: `cropImageFromOBB()`
- Converts normalized OBB points [0..1] to pixel coordinates
- Calculates rotation angle from OBB edges
- Rotates entire image to align OBB horizontally
- Extracts axis-aligned crop region
- Returns cropped image bytes

**Key:** Supports rotated meter displays in image.

### Step 2: OCR Processing

#### Local OCR: `WaterMeterOCRService`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/lib/services/water_meter_ocr_service.dart`

Uses Google ML Kit Text Recognition:
- Supports preprocessing (contrast adjustment, grayscale, threshold, etc.)
- Extracts number candidates from OCR text
- Prioritizes 5-digit readings, then 4-digit
- Applies error correction: O→0, I→1, S→5, Z→2, B→8
- Confidence calculation based on reading length & format

#### Remote OCR: `GetNumberOCR`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/lib/api/get_number_ocr.dart`

- Endpoint: `https://super-agent-api.meobeo.ai/water-clock-ocr`
- Expects response: `{ "status_code": 0, "data": { "success": true, "result": "12345" } }`

---

## 4. YOLO Model Loading & Inference

### Dart API: `YOLO` Class
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/packages/ultralytics_yolo/lib/yolo.dart`

```dart
final yolo = YOLO(
  modelPath: 'yolo11n-obb',  // asset or file path (no .tflite)
  task: YOLOTask.obb,
  useGpu: true,
);
await yolo.loadModel();
final results = await yolo.predict(imageBytes);
```

### Model Path Resolution
- `yolo11n-obb` → Looks in assets or app storage
- Can also use absolute paths or `internal://` scheme
- Platform automatically appends `.tflite` (Android) or `.mlpackage` (iOS)

### Inference Layer: `YOLOInference`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/packages/ultralytics_yolo/lib/core/yolo_inference.dart`

- Calls native channel method `predictSingleImage`
- Processes result to extract OBB data
- For OBB task: Returns `results['obb']` as list of OBB detections

### Model Loading: `YOLOModelManager`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/packages/ultralytics_yolo/lib/core/yolo_model_manager.dart`

- Calls native channel method `loadModel`
- Handles GPU/CPU delegate selection
- Initializes model on target platform

---

## 5. Android Native Implementation

### Plugin Entry Point
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/packages/ultralytics_yolo/android/src/main/kotlin/com/ultralytics/yolo/YOLOPlugin.kt`

Handles method channels:
- `loadModel` → Creates ObbDetector instance
- `predictSingleImage` → Runs inference & serializes OBB results

### OBB Detection Engine: `ObbDetector`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/packages/ultralytics_yolo/android/src/main/kotlin/com/ultralytics/yolo/ObbDetector.kt`

#### Key Features:
1. **TensorFlow Lite Interpreter** with optional GPU delegate
2. **Image Preprocessing:** Resizes to model input size (416x416), normalizes [0..1]
3. **Output Post-Processing:**
   - Detects coordinate format (pixel vs normalized)
   - Auto-normalizes pixel coordinates if needed
   - Applies confidence thresholding
   - Runs Non-Maximum Suppression (NMS) on OBB polygons

#### OBB Structure (Android)
```kotlin
data class OBB(
    val cx: Float,        // Center X (normalized)
    val cy: Float,        // Center Y (normalized)
    val w: Float,         // Width (normalized)
    val h: Float,         // Height (normalized)
    val angle: Float      // Rotation angle (radians)
)

fun toPolygon(): List<PointF>  // Returns 4 corner points
```

#### OBB Result
```kotlin
data class OBBResult(
    val box: OBB,
    val confidence: Float,
    val cls: String,
    val index: Int
)
```

#### Serialization to Flutter
```kotlin
response["obb"] = yoloResult.obb.map { obb ->
  val poly = obb.box.toPolygon()
  val clampedPoints = poly.map {
    mapOf(
      "x" to it.x.coerceIn(0f, 1f),
      "y" to it.y.coerceIn(0f, 1f)
    )
  }
  mapOf(
    "points" to clampedPoints,
    "class" to obb.cls,
    "confidence" to obb.confidence,
    "cx" to obb.box.cx,
    "cy" to obb.box.cy,
    "w" to obb.box.w,
    "h" to obb.box.h,
    "angle" to obb.box.angle  // radians
  )
}
```

### Asset Models (Android)
**Location:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/example/android/app/src/main/assets/`

Available models:
- `best_float32.tflite` - Main YOLO OBB detection model (example app)
- `yolo11n-obb.tflite` - Fallback YOLO OBB model (plugin library)

---

## 6. iOS Native Implementation

### Plugin Entry Point
**File:** `ios/Classes/WaterMeterSdkPlugin.swift`
- Implements method channel for processImage
- Uses Apple Vision framework for text recognition

### Model Handling
**Location:** `ios/Runner/best.mlpackage/`
- Core ML compiled YOLO OBB model for iOS
- Exported with NMS=True for iOS integration

---

## 7. Key Data Models

### Result Model: `WaterMeterResult`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/lib/models/water_meter_result.dart`

```dart
class WaterMeterResult {
  final String reading;              // "12345"
  final double confidence;           // 0.0-1.0
  final Uint8List? imageBytes;       // Annotated image
  final List<String>? debugInfo;     // Processing notes
  final String? rawOcrText;          // Raw text from OCR
  final String? processedText;       // Corrected text
}
```

### Detection Models: `OBBDetection` & `DetectResult`
**File:** `/Volumes/DucsM1/ocr_dhn_sdk_flutter/ocr_dhn_sdk/example/lib/water_meter_detector.dart`

```dart
class OBBDetection {
  final String className;
  final double confidence;
  final double angleDeg;            // Converted from radians
  final List<Offset> points;        // 4 normalized corners
  final double cx, cy;              // Center
  final double width, height;
}

class DetectResult {
  final List<OBBDetection> detections;
  final int imageByteSize;
  final double confidenceThreshold;
  final double iouThreshold;
  final List<String> rawKeys;
  final String rawSummary;
  final Uint8List? annotatedImage;
  final int nativeImageWidth;       // Actual bitmap size from native
  final int nativeImageHeight;
}
```

---

## 8. Example Application Flow

### Initialization (main.dart)
```dart
void initState() {
  _yoloService = WaterMeterSdkUltralyticsYolo();
  _detector = WaterMeterDetector();
  
  _yoloService.init();      // Load YOLO model
  _detector.loadModel();     // Load detection model
}
```

### Image Detection
```dart
// Method 1: Simple cropping via WaterMeterSdkUltralyticsYolo
final result = await _yoloService.processWaterMeterImage(imageBytes, isOnline: false);
// Returns: WaterMeterResult with reading + confidence

// Method 2: Detailed detection via WaterMeterDetector
final detectResult = await _detector.detectFromBytes(imageBytes);
// Returns: DetectResult with individual OBB detections + debug info
```

---

## 9. File Structure

### Plugin Core
```
lib/
├── water_meter_sdk_ultralytics_yolo.dart  [MAIN: YOLO detection + crop + OCR]
├── water_meter_sdk.dart                    [deprecated]
├── water_meter_sdk_platform_interface.dart
├── water_meter_sdk_method_channel.dart
├── models/
│   └── water_meter_result.dart            [Result model]
├── services/
│   ├── water_meter_ocr_service.dart       [Local OCR via Google ML Kit]
│   └── water_meter_ocr_service_tf_lite.dart [Experimental TFLite OCR]
└── api/
    └── get_number_ocr.dart                 [Remote OCR API client]
```

### YOLO Package (Local Fork)
```
packages/ultralytics_yolo/
├── lib/
│   ├── yolo.dart                           [Main YOLO class]
│   ├── core/
│   │   ├── yolo_inference.dart             [Inference wrapper]
│   │   └── yolo_model_manager.dart         [Model loading]
│   └── models/
│       ├── yolo_task.dart                  [Task enum]
│       └── yolo_result.dart
├── android/src/main/kotlin/com/ultralytics/yolo/
│   ├── YOLOPlugin.kt                       [Method channel handler]
│   ├── ObbDetector.kt                      [OBB detection engine]
│   ├── OBB.kt                              [OBB data structure]
│   ├── YOLOResult.kt                       [Result container]
│   └── [Other detector classes]
└── ios/Classes/
    └── WaterMeterSdkPlugin.swift
```

### Example App
```
example/
├── lib/
│   ├── main.dart                           [UI + flow control]
│   ├── water_meter_detector.dart           [Detector wrapper]
│   └── camera_obb_page.dart
├── android/app/src/main/assets/
│   ├── best_float32.tflite                 [YOLO OBB model]
│   └── yolo11n-obb.tflite
└── ios/Runner/
    └── best.mlpackage/                     [iOS Core ML model]
```

---

## 10. Key Technical Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| **Image Input Size** | 416x416 | YOLO model input |
| **Confidence Threshold (Android)** | 0.2 - 1.0 | Valid detection range (filtered) |
| **Confidence Threshold (iOS)** | 0.2 - 1.0 | Valid detection range (referenced in code) |
| **Default Confidence (iOS logic)** | 0.3 | Initial filtering |
| **IOU Threshold** | 0.4 | NMS overlapping box suppression |
| **OCR Digit Priority** | 5-digit > 4-digit | Water meter typical format |
| **OBB Angle** | Radians (converted to degrees in Dart) | Rotation angle |

---

## 11. Processing Differences: Android vs iOS

### Image Coordinate Handling
| Step | Android | iOS |
|------|---------|-----|
| YOLO Output | Normalized [0..1] after auto-detection | Raw pixel → normalized [0..1] |
| Confidence Filter | 0.2 < conf < 1.0 (strict) | 0.2 < conf < 1.0 (comment only) |
| Detection Selection | Highest confidence | First valid (4 points) |

### Crop Source
- **Android:** Cropped from 416x416 resized image (not upscaled back to original)
- **iOS:** Same approach (crop from 416x416 resized)

---

## 12. Unresolved Questions / Notes

1. **iOS Implementation Details:** `ios/Classes/WaterMeterSdkPlugin.swift` not fully examined - may have additional preprocessing
2. **GPU Delegate Fallback:** How does error handling work if GPU delegate fails on Android?
3. **Label Loading:** ObbDetector tries to load labels from ZIP or FlatBuffers metadata - current model doesn't have embedded labels?
4. **TFLite OCR Service:** Why is `water_meter_ocr_service_tf_lite.dart` commented out? Was it replaced?
5. **Annotation Image Format:** Both Android & iOS return annotated images - format/compression strategy?

---

## Summary of Data Flow

```
Image Bytes
    ↓
[YOLO Inference] (416x416 resize)
    ↓
[OBB Detection & Filtering]
    ├─ Android: Filter 0.2 < conf < 1.0, pick highest
    └─ iOS: Pick first valid with 4 points
    ↓
[OBB Cropping] (rotate + crop)
    ↓
Cropped Image Bytes
    ↓
[OCR Processing]
    ├─ Online: Send to super-agent-api.meobeo.ai
    └─ Offline: Google ML Kit Text Recognition
    ↓
[OCR Result Processing]
    ├─ Extract 5-digit or 4-digit candidates
    ├─ Apply error corrections (O→0, I→1, etc.)
    └─ Calculate confidence
    ↓
WaterMeterResult { reading, confidence, imageBytes, debugInfo }
```

