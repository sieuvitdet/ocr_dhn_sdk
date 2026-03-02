# Water Meter SDK - Integration Guide

## Installation

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  water_meter_sdk:
    path: ../path/to/water_meter_sdk
```

Then run:

```bash
flutter pub get
```

## Model Setup

### Android

Place `best_float32.tflite` in your app's assets directory:

```
android/app/src/main/assets/best_float32.tflite
```

The native TFLite pipeline handles OBB detection on Android automatically.

### iOS

Add `best.mlpackage` to your Xcode project under the Runner target:

1. Open `ios/Runner.xcworkspace` in Xcode
2. Drag `best.mlpackage` into the Runner group
3. Ensure "Copy items if needed" is checked
4. Ensure the Runner target is selected under "Add to targets"

## Usage

### Initialize

Create an instance and call `init()` once at startup:

```dart
import 'package:water_meter_sdk/water_meter_sdk_ultralytics_yolo.dart';

final sdk = WaterMeterSdkUltralyticsYolo();
await sdk.init();
```

The `init()` method is safe to call multiple times — it uses a singleton guard internally:
- If already initialized, returns immediately
- If initialization is in progress (concurrent call), awaits the existing future
- On Android, skips YOLO model loading (native TFLite handles detection)
- On iOS, loads the YOLO model for Dart-side OBB detection

You can check initialization status with `sdk.isInitialized`.

### Process an Image

```dart
import 'dart:typed_data';

final Uint8List imageBytes = await file.readAsBytes();
final result = await sdk.processImage(imageBytes, isOnline: false);

print('Reading: ${result.reading}');
print('Confidence: ${result.confidence}');
```

Parameters:
- `imageBytes` — Raw image bytes (JPEG/PNG)
- `isOnline` (optional, default `false`) — When `true`, sends the cropped image to a remote OCR API. When `false`, uses local OCR via Google ML Kit.

The returned `WaterMeterResult` contains:
- `reading` — The extracted meter number (String)
- `confidence` — OCR confidence score (double, 0.0–1.0)
- `imageBytes` — The cropped/annotated image (Uint8List?)
- `rawOcrText` — Raw OCR output before post-processing
- `processedText` — OCR output after error correction

### Dispose

Call `dispose()` when the SDK is no longer needed:

```dart
await sdk.dispose();
```

## Platform Differences

| Aspect | Android | iOS |
|--------|---------|-----|
| OBB Detection | Native TFLite via method channel | Dart-side YOLO (ultralytics_yolo) |
| Model File | `best_float32.tflite` in assets | `best.mlpackage` in Runner |
| YOLO Init | Skipped (not needed) | Loads model into memory |
| Image Resize | 640x640 (native) | 416x416 (Dart) |
| OCR | Google ML Kit / Remote API | Google ML Kit / Remote API |

## Common Pitfalls

### Missing model files
If you see errors about model loading, verify:
- Android: `best_float32.tflite` exists in `android/app/src/main/assets/`
- iOS: `best.mlpackage` is included in the Runner target in Xcode

### Calling processImage before init
`processImage()` throws a `StateError` if called before `init()` completes. Always await initialization:

```dart
await sdk.init();
// Now safe to call
final result = await sdk.processImage(bytes);
```

### Multiple SDK instances
While you can create multiple instances, each will hold its own YOLO model on iOS. Prefer using a single instance throughout your app's lifecycle to conserve memory.
