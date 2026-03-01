# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**water_meter_sdk** is a Flutter plugin for reading water meter dials from images. It uses YOLO OBB (Oriented Bounding Box) detection to locate the meter display, then applies OCR to extract the numeric reading. Supports both Android and iOS.

## Common Commands

```bash
# Get dependencies (run from project root)
flutter pub get

# Get dependencies for example app
cd example && flutter pub get

# Run the example app
cd example && flutter run

# Analyze code
flutter analyze

# Run unit tests
flutter test

# Run a single test
flutter test test/water_meter_sdk_test.dart

# Run integration tests (requires device/emulator)
cd example && flutter test integration_test/

# Build iOS (from example/)
cd example && flutter build ios

# Build Android (from example/)
cd example && flutter build apk
```

## Architecture

### Plugin Structure (Flutter federated plugin pattern)

- `lib/water_meter_sdk_platform_interface.dart` - Abstract platform interface with `processImage()` method
- `lib/water_meter_sdk_method_channel.dart` - Method channel implementation calling native OCR via `water_meter_sdk` channel
- `lib/water_meter_sdk.dart` - Previously the main SDK class (currently commented out, replaced by ultralytics_yolo approach)
- `lib/water_meter_sdk_ultralytics_yolo.dart` - **Active main SDK class** (`WaterMeterSdkUltralyticsYolo`): the primary processing pipeline

### Processing Pipeline (WaterMeterSdkUltralyticsYolo)

1. **YOLO OBB Detection**: Resizes image to 416x416, runs `yolo11n-obb` model to detect water meter region with oriented bounding boxes
2. **Crop**: Extracts the detected region using OBB points (handles rotation). Platform-specific logic:
   - iOS: Uses raw pixel coordinates from YOLO predictions
   - Android: Uses normalized [0..1] coordinates, filters by confidence (0.2 < conf < 1.0), selects highest confidence
3. **OCR**: Two modes controlled by `isOnline` parameter:
   - `isOnline: true` - Sends cropped image to remote API (`super-agent-api.meobeo.ai/water-clock-ocr`)
   - `isOnline: false` - Uses local OCR via `WaterMeterOCRService` (Google ML Kit Text Recognition)

### Key Files

- `lib/services/water_meter_ocr_service.dart` - Local OCR using Google ML Kit. Extracts 4-5 digit numbers, applies OCR error correction (O->0, I->1, S->5, etc.)
- `lib/services/water_meter_ocr_service_tf_lite.dart` - Alternative TFLite-based detection service (mostly commented out, experimental)
- `lib/api/get_number_ocr.dart` - Remote OCR API client
- `lib/models/water_meter_result.dart` - Result model with reading, confidence, debug info

### Native Platform Code

- **Android** (`android/src/main/kotlin/com/example/water_meter_sdk/`):
  - `WaterMeterSdkPlugin.kt` - Method channel handler, uses ML Kit for text recognition
  - `OCRPipeline.kt` - PaddleOCR-based pipeline (JNI, uses `.nb` model files in assets)
  - `WaterMeterProcessor.kt` - Additional processing logic
- **iOS** (`ios/Classes/`):
  - `WaterMeterSdkPlugin.swift` - Method channel handler, uses Apple Vision framework (`VNRecognizeTextRequest`)

### Local Dependency Override

`packages/ultralytics_yolo/` is a local fork of the `ultralytics_yolo` package, overridden in `pubspec.yaml` via `dependency_overrides`. This fork handles YOLO model loading and inference on both platforms with platform views.

### ML Models

- `assets/ocr_model.onnx` - ONNX OCR model bundled with the plugin
- `android/src/main/assets/model.onnx` - Android-specific ONNX model
- `android/src/main/assets/ch_ppocr_mobile_v2.0_*.nb` - PaddleOCR models (det, cls, rec)
- `ios/Classes/Models/` - Same PaddleOCR + ONNX models for iOS
- Example app uses `best_float32.tflite` (Android) and `best.mlpackage` (iOS) for YOLO OBB

## Key Technical Details

- Images are resized to **416x416** before YOLO inference
- Confidence threshold: **0.3** default, readings filtered to **0.2 < confidence < 1.0**
- OCR prioritizes **5-digit** readings, then **4-digit** (typical water meter format)
- The `WaterMeterResult` model carries `reading`, `confidence`, `imageBytes` (annotated), `rawOcrText`, and `processedText`
- Project language is mixed Vietnamese/English in comments and variable names
