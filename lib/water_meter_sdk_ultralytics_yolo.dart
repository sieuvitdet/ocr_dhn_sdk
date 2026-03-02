import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/models/detection_test_result.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:water_meter_sdk/services/water_meter_ocr_service.dart';


class WaterMeterSdkUltralyticsYolo {
  static const _methodChannel = MethodChannel('water_meter_sdk');
  final WaterMeterOCRService _ocrService = WaterMeterOCRService();
  YOLO? _yolo;
  bool _isInitialized = false;
  Future<void>? _initFuture;

  bool get isInitialized => _isInitialized;

  /// Model path based on platform
  String get modelPath {
    if (Platform.isAndroid) {
      return 'best_float32'; // android/app/src/main/assets/best_float32.tflite
    } else {
      return 'best'; // ios/Runner/best.mlpackage
    }
  }

  Future<void> init() async {
    if (_isInitialized) return;
    if (_initFuture != null) {
      await _initFuture;
      return;
    }
    _initFuture = _doInit();
    await _initFuture;
  }

  Future<void> _doInit() async {
    if (Platform.isAndroid) {
      // Android uses native TFLite detection via method channel - no YOLO needed
      _isInitialized = true;
      return;
    }
    // iOS: initialize YOLO for Dart-side OBB detection
    _yolo = YOLO(
      modelPath: modelPath,
      task: YOLOTask.obb,
    );
    await _yolo!.loadModel();
    _isInitialized = true;
  }

  /// Unified entry point: auto-routes Android → native TFLite, iOS → Dart YOLO
  Future<WaterMeterResult> processImage(Uint8List imageBytes, {bool isOnline = false}) async {
    if (!_isInitialized) {
      throw StateError('SDK not initialized. Call init() first.');
    }

    if (Platform.isAndroid) {
      final result = await processWithNativeObb(imageBytes, isOnline: isOnline);
      return _toWaterMeterResult(result);
    } else {
      final result = await processWaterMeterImage(imageBytes, isOnline: isOnline);
      return result ?? WaterMeterResult.empty();
    }
  }

  WaterMeterResult _toWaterMeterResult(DetectionTestResult result) {
    return WaterMeterResult(
      reading: result.ocrReading,
      confidence: result.ocrConfidence,
      imageBytes: result.croppedImage,
      rawOcrText: result.rawOcrText,
      processedText: result.processedText,
      debugInfo: result.logs,
    );
  }

  /// iOS path: YOLO OBB detection + crop + OCR
  Future<WaterMeterResult?> processWaterMeterImage(Uint8List imageBytes, {bool isOnline = false}) async {
    final croppedBytesAfter = await runOBBDetectionAndCrop(imageBytes);
    if (isOnline) {
      final tempFile = await saveBytesToTempFile(croppedBytesAfter, 'cropped.jpg');
      final ocrApi = GetNumberOCR();
      final result = await ocrApi.ocrImage(tempFile);
      return WaterMeterResult(
        imageBytes: croppedBytesAfter,
        reading: result ?? '',
        confidence: 0,
      );
    } else {
      return await _ocrService.processImage(croppedBytesAfter);
    }
  }

  Future<File> saveBytesToTempFile(Uint8List bytes, String filename) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$filename');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<Uint8List> runOBBDetectionAndCrop(Uint8List imageBytes) async {
    final originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) return imageBytes;

    final resizedImage = img.copyResize(originalImage, width: 416, height: 416);
    final resizedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));

    final results = await _yolo!.predict(resizedImageBytes);
    final obbList = results['obb'] as List<dynamic>;

    if (obbList.isNotEmpty) {
      for (final detection in obbList) {
        final boxes = detection as Map<dynamic, dynamic>;
        final points = boxes['points'] as List<dynamic>? ?? [];

        if (points.isNotEmpty && points.length == 4
            && (boxes['confidence'] as num).toDouble() > 0.2
            && (boxes['confidence'] as num).toDouble() < 1) {
          return cropImageFromOBB(resizedImageBytes, points);
        }
      }
    }
    return imageBytes;
  }

  Uint8List cropImageFromOBB(Uint8List imageBytes, List<dynamic> points) {
    final image = img.decodeImage(imageBytes);
    if (image == null) throw Exception('Failed to decode image for cropping');

    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (final point in points) {
      final pointMap = point as Map<dynamic, dynamic>;
      final x = (pointMap['x'] as num).toDouble() * image.width;
      final y = (pointMap['y'] as num).toDouble() * image.height;

      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
    }

    final padding = Platform.isIOS ? 15 : 0;
    minX = math.max(0, minX - padding);
    minY = math.max(0, minY - padding);
    maxX = math.min(image.width.toDouble(), maxX + padding);
    maxY = math.min(image.height.toDouble(), maxY + padding);

    final croppedImage = img.copyCrop(
      image,
      x: minX.round(),
      y: minY.round(),
      width: (maxX - minX).round(),
      height: (maxY - minY).round(),
    );

    return Uint8List.fromList(img.encodePng(croppedImage));
  }

  /// Android path: Native OBB detection via TFLite method channel
  Future<DetectionTestResult> processWithNativeObb(
    Uint8List imageBytes, {
    bool isOnline = false,
  }) async {
    final logs = <String>[];
    final timestamp = DateTime.now();

    // Decode to get dimensions
    final originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) {
      return DetectionTestResult(
        scenario: YoloScenario.nativeObb,
        timestamp: timestamp,
        obbDetections: [],
        totalDetections: 0,
        ocrReading: '',
        ocrConfidence: 0,
        logs: ['ERROR: Failed to decode input image'],
      );
    }

    final inputW = originalImage.width;
    final inputH = originalImage.height;
    logs.add('Input image: ${inputW}x$inputH');

    // Call native detectObb
    logs.add('Calling native detectObb via method channel...');
    final Map<dynamic, dynamic> nativeResult;
    try {
      final result = await _methodChannel.invokeMethod('detectObb', {
        'imageBytes': imageBytes,
      });
      nativeResult = result as Map<dynamic, dynamic>;
    } catch (e) {
      logs.add('ERROR calling detectObb: $e');
      return DetectionTestResult(
        scenario: YoloScenario.nativeObb,
        timestamp: timestamp,
        obbDetections: [],
        totalDetections: 0,
        ocrReading: '',
        ocrConfidence: 0,
        logs: logs,
        inputWidth: inputW,
        inputHeight: inputH,
      );
    }

    // Parse native logs
    final nativeLogs = (nativeResult['logs'] as List<dynamic>?)?.cast<String>() ?? [];
    logs.addAll(nativeLogs.map((l) => '[native] $l'));

    // Parse detections
    final rawDetections = (nativeResult['detections'] as List<dynamic>?) ?? [];
    logs.add('Native detections: ${rawDetections.length}');

    final allDetections = <Map<String, dynamic>>[];
    for (int idx = 0; idx < rawDetections.length; idx++) {
      final det = rawDetections[idx] as Map<dynamic, dynamic>;
      final confidence = (det['confidence'] as num).toDouble();
      final cx = (det['cx'] as num).toDouble();
      final cy = (det['cy'] as num).toDouble();
      final w = (det['width'] as num).toDouble();
      final h = (det['height'] as num).toDouble();
      final angleDeg = (det['angleDeg'] as num).toDouble();
      final classId = (det['classId'] as num).toInt();
      final corners = (det['corners'] as List<dynamic>).cast<num>().map((e) => e.toDouble()).toList();

      final detMap = <String, dynamic>{
        'class': 'class_$classId',
        'confidence': confidence,
        'index': idx,
        'cx': cx,
        'cy': cy,
        'width': w,
        'height': h,
        'angleDeg': angleDeg,
        'points': [
          {'x': corners[0], 'y': corners[1]},
          {'x': corners[2], 'y': corners[3]},
          {'x': corners[4], 'y': corners[5]},
          {'x': corners[6], 'y': corners[7]},
        ],
      };

      // Store corner points for display
      for (int j = 0; j < 4; j++) {
        detMap['P${j}_x'] = corners[j * 2];
        detMap['P${j}_y'] = corners[j * 2 + 1];
      }

      logs.add('--- Detection #$idx ---');
      logs.add('  class=$classId confidence=${confidence.toStringAsFixed(4)}');
      logs.add('  cx=${cx.toStringAsFixed(1)} cy=${cy.toStringAsFixed(1)} '
          'w=${w.toStringAsFixed(1)} h=${h.toStringAsFixed(1)} angle=${angleDeg.toStringAsFixed(1)}');
      for (int j = 0; j < 4; j++) {
        logs.add('  P$j=(${corners[j * 2].toStringAsFixed(1)}, ${corners[j * 2 + 1].toStringAsFixed(1)})');
      }

      allDetections.add(detMap);
    }

    // Get annotated and cropped images from native
    final annotatedImageBytes = nativeResult['annotatedImage'] as Uint8List?;
    final croppedImageBytes = nativeResult['croppedImage'] as Uint8List?;

    // OCR on cropped image
    String ocrReading = '';
    double ocrConfidence = 0;
    String? rawOcrText;
    String? processedText;

    final bytesForOcr = croppedImageBytes ?? imageBytes;
    logs.add('Running OCR on ${croppedImageBytes != null ? "cropped" : "original"} image...');

    if (isOnline) {
      try {
        final tempFile = await saveBytesToTempFile(bytesForOcr, 'native_obb_cropped.jpg');
        final ocrApi = GetNumberOCR();
        final result = await ocrApi.ocrImage(tempFile);
        ocrReading = result ?? '';
        rawOcrText = result;
        logs.add('Online OCR result: $ocrReading');
      } catch (e) {
        logs.add('Online OCR error: $e');
      }
    } else {
      try {
        final ocrResult = await _ocrService.processImage(bytesForOcr);
        ocrReading = ocrResult.reading;
        ocrConfidence = ocrResult.confidence;
        rawOcrText = ocrResult.rawOcrText;
        processedText = ocrResult.processedText;
        logs.add('Offline OCR reading: $ocrReading');
        logs.add('Offline OCR confidence: ${(ocrConfidence * 100).toStringAsFixed(1)}%');
      } catch (e) {
        logs.add('Offline OCR error: $e');
      }
    }

    return DetectionTestResult(
      scenario: YoloScenario.nativeObb,
      timestamp: timestamp,
      obbDetections: allDetections,
      totalDetections: rawDetections.length,
      inputImageWithBBox: annotatedImageBytes,
      croppedImage: croppedImageBytes,
      ocrReading: ocrReading,
      ocrConfidence: ocrConfidence,
      rawOcrText: rawOcrText,
      processedText: processedText,
      logs: logs,
      inputWidth: inputW,
      inputHeight: inputH,
      resizedWidth: 640,
      resizedHeight: 640,
    );
  }

  Future<void> dispose() async {
    if (Platform.isIOS && _yolo != null) {
      await _yolo!.dispose();
    }
    await _ocrService.dispose();
  }
}
