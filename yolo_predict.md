# YOLO Flutter - Image Prediction Capabilities Summary

## Overview

The **Ultralytics YOLO Flutter Plugin** provides comprehensive machine learning inference capabilities for both iOS and Android platforms. This plugin enables real-time and single-image predictions using YOLO (You Only Look Once) models directly on mobile devices.

---

## Supported Platforms

| Platform | Framework | Model Format | GPU Acceleration |
|----------|-----------|--------------|------------------|
| **iOS** | Core ML (Vision framework) | `.mlmodel` / `.mlpackage` | ✅ Core ML GPU |
| **Android** | TensorFlow Lite | `.tflite` | ✅ TFLite GPU Delegate |

---

## Prediction Tasks

The plugin supports **5 distinct computer vision tasks**:

### 1. **Object Detection** (`YOLOTask.detect`)
- **Purpose**: Identifies objects and their locations with bounding boxes
- **Output**:
  - Bounding box coordinates (pixel & normalized)
  - Class labels
  - Confidence scores
- **Performance**: 25-30 FPS on modern devices
- **Use Cases**: Security systems, inventory management, retail analytics

**iOS Implementation**: `ObjectDetector.swift`
- Uses Vision framework's `VNRecognizedObjectObservation`
- Applies Non-Maximum Suppression (NMS) via Vision API
- Returns Box objects with `xywh` (absolute) and `xywhn` (normalized) coordinates

**Android Implementation**: `ObjectDetector.kt`
- Uses TensorFlow Lite interpreter with custom preprocessing
- Native JNI-based NMS post-processing
- Supports portrait/landscape camera rotation
- Output shape: `[1, 84, 8400]` (configurable based on model)

---

### 2. **Instance Segmentation** (`YOLOTask.segment`)
- **Purpose**: Provides pixel-level masks for detected objects
- **Output**:
  - All detection outputs (boxes, labels, confidence)
  - Pixel-level segmentation masks
- **Performance**: 15-25 FPS
- **Use Cases**: Photo editing, background removal, medical imaging

**iOS Implementation**: `Segmenter.swift`
- Extracts mask data from model output
- Converts mask coordinates to image space
- Provides binary masks for each detected object

**Android Implementation**: `Segmenter.kt`
- Processes mask tensors from TFLite output
- Handles mask resizing and alignment with bounding boxes

---

### 3. **Image Classification** (`YOLOTask.classify`)
- **Purpose**: Categorizes the main subject of an image
- **Output**:
  - Top-1 prediction (class label + confidence)
  - Top-5 predictions with confidence scores
- **Performance**: 30+ FPS
- **Use Cases**: Content moderation, image tagging, product recognition

**iOS Implementation**: `Classifier.swift`
- Handles both `VNCoreMLFeatureValueObservation` and `VNClassificationObservation`
- Extracts classification probabilities from model output
- Returns `Probs` structure with top1/top5 results

**Android Implementation**: `Classifier.kt`
- **Special Features**:
  - Supports both 3-channel (RGB) and 1-channel (grayscale) models
  - Custom preprocessing for grayscale images
  - Configurable normalization (max normalization or mean/std)
  - Color inversion support for specialized models (e.g., handwriting)
- Output shape: `[1, numClasses]`
- Classifier options available:
  ```dart
  {
    'enable1ChannelSupport': true,
    'enableColorInversion': true,
    'enableMaxNormalization': true,
    'expectedChannels': 1,
    'expectedClasses': 12,
    'inputMean': 127.5,
    'inputStd': 127.5
  }
  ```

---

### 4. **Pose Estimation** (`YOLOTask.pose`)
- **Purpose**: Detects human body keypoints and poses
- **Output**:
  - Bounding boxes around detected persons
  - Body keypoints (x, y coordinates)
  - Keypoint confidence scores
- **Performance**: 20-30 FPS
- **Use Cases**: Fitness apps, motion capture, sports analysis, AR applications

**iOS Implementation**: `PoseEstimater.swift`
- Detects human pose keypoints (shoulders, elbows, knees, etc.)
- Returns keypoint coordinates with individual confidence values
- Supports visualization of skeletal structure

**Android Implementation**: `PoseEstimator.kt`
- Processes pose keypoint tensors
- Returns structured keypoint data with confidence scores

---

### 5. **Oriented Bounding Box Detection** (`YOLOTask.obb`)
- **Purpose**: Detects rotated/oriented bounding boxes for objects
- **Output**:
  - Rotated bounding box coordinates
  - Class labels and confidence scores
- **Performance**: 20-25 FPS
- **Use Cases**: Aerial imagery analysis, document scanning, rotated object detection

**iOS Implementation**: `ObbDetector.swift`
- Handles rotated bounding box detection
- Returns oriented box coordinates

**Android Implementation**: `ObbDetector.kt`
- Processes oriented bounding box predictions
- Handles rotation angles for detected objects

---

## Prediction Modes

### 1. **Single Image Prediction**

**API Usage**:
```dart
final yolo = YOLO(
  modelPath: 'assets/models/yolo11n.tflite',
  task: YOLOTask.detect,
  useGpu: true,
);

await yolo.loadModel();
final results = await yolo.predict(imageBytes);

// Access detection results
final boxes = results['boxes'] as List<dynamic>;
final detections = results['detections'] as List<dynamic>;
```

**Features**:
- Synchronous or asynchronous prediction
- Returns annotated image with visualizations
- Configurable thresholds:
  - `confidenceThreshold` (default: 0.25)
  - `iouThreshold` (default: 0.4)

**iOS Processing Pipeline**:
1. CIImage input
2. Vision request creation
3. Core ML inference
4. Result observation processing
5. Return YOLOResult with annotated image

**Android Processing Pipeline**:
1. Bitmap input → TensorImage
2. Image preprocessing (resize, normalize, cast)
3. TFLite inference
4. JNI-based post-processing (NMS)
5. Return YOLOResult with boxes

---

### 2. **Real-time Camera Inference**

**API Usage**:
```dart
YOLOView(
  modelPath: 'yolo11n',
  task: YOLOTask.detect,
  onResult: (results) {
    print('Found ${results.length} objects!');
    for (final result in results) {
      print('${result.className}: ${result.confidence}');
    }
  },
  onInferenceTime: (inferenceTime, fps) {
    print('Inference: ${inferenceTime}ms, FPS: $fps');
  },
)
```

**Features**:
- Real-time camera feed processing
- Automatic frame rotation handling (portrait/landscape)
- Front/back camera support with different rotation angles
- Performance metrics (FPS, inference time)
- Smoothed FPS calculation for stable UI

**iOS Camera Pipeline**:
1. CMSampleBuffer from AVFoundation
2. VideoCapture handles camera feed
3. Frame-by-frame inference via Vision
4. Results delivered via ResultsListener
5. Performance tracking via InferenceTimeListener

**Android Camera Pipeline**:
1. Bitmap frames from camera
2. Rotation handling:
   - Portrait back camera: 270° rotation
   - Portrait front camera: 90° rotation
   - Landscape: no rotation
3. Three separate ImageProcessors for different orientations
4. Optimized preprocessing with reused buffers
5. Smoothed timing metrics (t2, t4)

---

## Platform-Specific Implementation Details

### iOS Architecture

**Core Components**:
- **Predictor Protocol**: Defines interface for all predictors
- **BasePredictor**: Shared functionality (threshold management, timing)
- **Vision Framework**: Apple's native ML inference
- **ThresholdProvider**: Custom feature provider for confidence/IoU thresholds

**Key Features**:
- Native Core ML integration
- Automatic GPU optimization
- Vision framework handles NMS automatically for detection
- Efficient memory management
- Performance listeners for real-time metrics

**Model Loading**:
- Models bundled in `ios/Runner.xcworkspace`
- Supports both `.mlmodel` and `.mlpackage` formats
- Automatic label extraction from model metadata

---

### Android Architecture

**Core Components**:
- **Predictor Interface**: Defines common prediction methods
- **BasePredictor**: Abstract base class with shared functionality
- **TensorFlow Lite**: Google's mobile ML framework
- **JNI Native Library**: High-performance NMS implementation

**Key Features**:
- TFLite GPU Delegate support
- Custom preprocessing pipeline with ImageProcessor
- Optimized memory usage (reused buffers)
- Multi-threaded inference
- Native C++ post-processing via JNI

**Model Loading**:
- Models in `android/app/src/main/assets`
- Supports `.tflite` format
- Label extraction from:
  1. Appended ZIP metadata (primary)
  2. FlatBuffers metadata (fallback)
  3. Constructor parameters (fallback)

**Preprocessing Optimizations**:
```kotlin
// Three separate processors for efficiency
- imageProcessorCameraPortrait (270° rotation)
- imageProcessorCameraPortraitFront (90° rotation)
- imageProcessorCameraLandscape (no rotation)
- imageProcessorSingleImage (no rotation)
```

**Grayscale Model Support** (Android Classification):
- Automatic detection of 1-channel models
- Custom preprocessing pipeline
- Color inversion for handwriting models
- Flexible normalization strategies

---

## Performance Characteristics

### Inference Speed

| Task | iOS FPS | Android FPS | Notes |
|------|---------|-------------|-------|
| Detection | 25-30 | 25-30 | Depends on model size (n/s/m/l) |
| Classification | 30+ | 30+ | Fastest task type |
| Segmentation | 15-25 | 15-25 | More computationally intensive |
| Pose | 20-30 | 20-30 | Single or multi-person |
| OBB | 20-25 | 20-25 | Similar to detection |

### Optimization Features

**Both Platforms**:
- GPU acceleration enabled by default
- Configurable confidence/IoU thresholds
- Adaptive FPS control
- Result caching and buffering

**iOS Specific**:
- Core ML automatic optimization
- Metal GPU backend
- Native CPU acceleration

**Android Specific**:
- GPU Delegate with fallback to CPU
- Configurable thread count (default: CPU cores)
- ByteBuffer reuse to reduce GC pressure
- JNI-optimized post-processing

---

## Output Data Structures

### YOLOResult (Dart)
```dart
class YOLOResult {
  final int classIndex;           // Class ID
  final String className;         // Human-readable label
  final double confidence;        // 0.0-1.0
  final Rect boundingBox;         // Pixel coordinates
  final Rect normalizedBox;       // Normalized 0-1 coordinates
  final List<List<double>>? mask; // Segmentation mask
  final List<Point>? keypoints;   // Pose keypoints
  final List<double>? keypointConfidences; // Keypoint confidence
}
```

### Platform Native Results

**iOS (YOLOResult.swift)**:
```swift
struct YOLOResult {
  let orig_shape: CGSize
  let boxes: [Box]?
  let probs: Probs?
  let masks: [[[Double]]]?
  let keypoints: [[Double]]?
  let speed: Double
  let fps: Double
  let names: [String]
  var originalImage: UIImage?
  var annotatedImage: UIImage?
}
```

**Android (YOLOResult.kt)**:
```kotlin
data class YOLOResult(
  val origShape: Size,
  val boxes: List<Box>? = null,
  val probs: Probs? = null,
  val masks: List<List<List<Double>>>? = null,
  val keypoints: List<List<Double>>? = null,
  val speed: Double,
  val fps: Double,
  val names: List<String>
)
```

---

## Model Compatibility

### Supported Model Formats

| Platform | Format | Extensions | Framework |
|----------|--------|-----------|-----------|
| iOS | Core ML | `.mlmodel`, `.mlpackage` | Vision + Core ML |
| Android | TensorFlow Lite | `.tflite` | TFLite |

### Model Requirements

**iOS**:
- Minimum iOS version: 13.0+
- Core ML compatible models
- Models must include metadata with class labels

**Android**:
- Minimum API level: 21 (Android 5.0)
- TFLite format with standard YOLO output shapes
- Optional metadata for automatic label extraction

### Model Size Variants

- **Nano (n)**: ~6MB, fastest inference, lower accuracy
- **Small (s)**: ~10MB, balanced performance
- **Medium (m)**: ~20MB, higher accuracy
- **Large (l)**: ~40MB+, highest accuracy, slower

---

## Advanced Features

### 1. **Dynamic Model Switching**
```dart
// Switch model without recreating view
await yolo.switchModel('new_model_path', YOLOTask.segment);
```

### 2. **Custom Classifier Options**
```dart
final yolo = YOLO.withClassifierOptions(
  modelPath: 'assets/handwriting_model.tflite',
  task: YOLOTask.classify,
  classifierOptions: {
    'enable1ChannelSupport': true,
    'enableColorInversion': true,
    'enableMaxNormalization': true,
    'expectedChannels': 1,
    'expectedClasses': 12,
  },
);
```

### 3. **Multi-Instance Support**
```dart
// Create multiple YOLO instances
final yolo1 = YOLO(
  modelPath: 'model1.tflite',
  task: YOLOTask.detect,
  useMultiInstance: true,
);

final yolo2 = YOLO(
  modelPath: 'model2.tflite',
  task: YOLOTask.segment,
  useMultiInstance: true,
);
```

### 4. **Performance Metrics**
- Real-time FPS calculation
- Smoothed inference time (exponential moving average)
- Preprocessing, inference, and post-processing timing breakdowns (Android)

### 5. **Frame Capture**
- Capture annotated frames from camera feed
- Save detection overlays for sharing
- Generate annotated images for single predictions

---

## Prediction Workflow Comparison

### iOS Prediction Workflow

```
Input Image/Frame
       ↓
CIImage/CMSampleBuffer
       ↓
VNImageRequestHandler
       ↓
Vision CoreML Request
       ↓
Core ML Inference (GPU/ANE)
       ↓
VNObservation Results
       ↓
Process Observations
       ↓
YOLOResult (with annotated image)
```

### Android Prediction Workflow

```
Input Bitmap
       ↓
TensorImage Loading
       ↓
ImageProcessor (Rot90 → Resize → Normalize → Cast)
       ↓
ByteBuffer Preparation
       ↓
TFLite Inference (GPU Delegate)
       ↓
Raw Output [1][C][W]
       ↓
JNI Native Post-processing (NMS)
       ↓
Box List Creation
       ↓
YOLOResult (with timing metrics)
```

---

## Error Handling

### iOS
```swift
enum PredictorError: Error {
  case invalidTask
  case noLabelsFound
  case invalidUrl
  case modelFileNotFound
}
```

### Android
- Exception handling in interpreter initialization
- GPU delegate fallback to CPU
- Model file validation
- Label loading fallback chain

### Flutter
```dart
try {
  final results = await yolo.predict(imageBytes);
} catch (e) {
  final error = YOLOErrorHandler.handleError(e, context);
  // Handle ModelNotLoadedException, InferenceException, etc.
}
```

---

## Limitations and Considerations

### Performance
- **GPU Stability**: GPU acceleration may cause crashes on some devices; use `useGpu: false` as fallback
- **Memory Usage**: Large models and high-resolution images require significant memory
- **Battery Impact**: Real-time inference consumes substantial battery power

### Model Constraints
- **iOS**: Requires Core ML compatible models (export from Ultralytics with `format='coreml'`)
- **Android**: Requires TFLite models (export with `format='tflite'`)
- **Input Size**: Models have fixed input sizes (e.g., 320×320, 640×640)

### Platform Differences
- **Rotation Handling**: Different rotation angles for portrait/landscape on Android
- **NMS Implementation**: iOS uses Vision framework NMS; Android uses custom JNI implementation
- **Model Formats**: Cannot share models between platforms directly

---

## Conclusion

The YOLO Flutter plugin provides **production-ready** computer vision capabilities for both iOS and Android platforms with:

✅ **5 AI Tasks**: Detection, Segmentation, Classification, Pose, OBB
✅ **Dual Modes**: Single image and real-time camera inference
✅ **Cross-platform**: Native iOS (Core ML) and Android (TFLite) implementations
✅ **High Performance**: Up to 30 FPS on modern devices with GPU acceleration
✅ **Flexible Configuration**: Custom thresholds, multi-instance support, dynamic model switching
✅ **Production Features**: Error handling, performance metrics, annotated output

Both platforms share a unified Flutter API while leveraging platform-specific optimizations for optimal performance.
