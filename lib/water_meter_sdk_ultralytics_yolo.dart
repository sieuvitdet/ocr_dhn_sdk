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
  late YOLO yolo;

  /// Model path based on platform
  String get modelPath {
    if (Platform.isAndroid) {
      return 'best_float32'; // android/app/src/main/assets/best_float32.tflite
    } else {
      return 'best'; // ios/Runner/best.mlpackage
    }
  }

  Future init() async {
    yolo = YOLO(
      modelPath: modelPath,
      task: YOLOTask.obb,
    );
    await yolo.loadModel();
  }

  /// Original processWaterMeterImage (backward compatible)
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

  /// Test scenario: detect + draw bbox + crop + OCR, return rich result with logs
  Future<DetectionTestResult> processWithScenario(
    Uint8List imageBytes,
    YoloScenario scenario, {
    bool isOnline = false,
  }) async {
    final logs = <String>[];
    final timestamp = DateTime.now();

    // Decode original image
    final originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) {
      return DetectionTestResult(
        scenario: scenario,
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

    // Resize to 416x416
    final resizedImage = img.copyResize(originalImage, width: 416, height: 416);
    final resizedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));
    logs.add('Resized to: 416x416');

    // Run YOLO prediction
    logs.add('Running YOLO predict...');
    final results = await yolo.predict(resizedImageBytes);
    final obbList = results['obb'] as List<dynamic>? ?? [];
    logs.add('Result keys: ${results.keys.toList()}');
    logs.add('Total OBB detections: ${obbList.length}');

    // Parse all detections
    final allDetections = <Map<String, dynamic>>[];
    for (int idx = 0; idx < obbList.length; idx++) {
      final detection = obbList[idx] as Map<dynamic, dynamic>;
      final points = detection['points'] as List<dynamic>? ?? [];
      final confidence = (detection['confidence'] as num?)?.toDouble() ?? 0.0;
      final className = detection['class']?.toString() ?? 'unknown';

      final det = <String, dynamic>{
        'class': className,
        'confidence': confidence,
        'points': points,
        'index': idx,
      };

      // Log raw detection
      logs.add('--- Detection #$idx ---');
      logs.add('  class=$className confidence=${confidence.toStringAsFixed(4)}');
      logs.add('  points_count=${points.length}');

      if (points.length == 4) {
        for (int j = 0; j < points.length; j++) {
          final p = points[j] as Map<dynamic, dynamic>;
          final x = (p['x'] as num).toDouble();
          final y = (p['y'] as num).toDouble();
          logs.add('  P$j=($x, $y)');
          det['P${j}_x'] = x;
          det['P${j}_y'] = y;
        }

        // Check coordinate format
        final isNormalized = points.every((p) {
          final m = p as Map;
          final x = (m['x'] as num).toDouble();
          final y = (m['y'] as num).toDouble();
          return x >= 0 && x <= 1.0 && y >= 0 && y <= 1.0;
        });
        det['isNormalized'] = isNormalized;
        logs.add('  isNormalized=$isNormalized');
      }

      allDetections.add(det);
    }

    // Draw bounding boxes on resized image (for visualization)
    final bboxImage = img.Image.from(resizedImage);
    _drawAllBoundingBoxes(bboxImage, obbList, scenario, logs);
    final bboxImageBytes = Uint8List.fromList(img.encodePng(bboxImage));

    // Crop based on scenario
    Uint8List? croppedBytes;
    if (obbList.isNotEmpty) {
      try {
        if (scenario == YoloScenario.pubCache) {
          // Scenario 1: pub cache - Android uses normalized coords
          logs.add('Scenario 1: Using Android (normalized) crop logic');
          croppedBytes = await _cropScenarioPubCache(resizedImageBytes, obbList, logs);
        } else {
          // Scenario 2: local fork - Android uses iOS-like logic
          logs.add('Scenario 2: Using iOS-like crop logic');
          croppedBytes = _cropScenarioLocalFork(resizedImageBytes, obbList, logs);
        }
      } catch (e) {
        logs.add('ERROR during crop: $e');
      }
    } else {
      logs.add('No OBB detections - skipping crop');
    }

    // OCR
    String ocrReading = '';
    double ocrConfidence = 0;
    String? rawOcrText;
    String? processedText;

    final bytesForOcr = croppedBytes ?? resizedImageBytes;
    logs.add('Running OCR on ${croppedBytes != null ? "cropped" : "resized"} image...');

    if (isOnline) {
      try {
        final tempFile = await saveBytesToTempFile(bytesForOcr, 'cropped_test.jpg');
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
        if (rawOcrText != null) logs.add('Raw OCR text: $rawOcrText');
        if (processedText != null) logs.add('Processed text: $processedText');
      } catch (e) {
        logs.add('Offline OCR error: $e');
      }
    }

    return DetectionTestResult(
      scenario: scenario,
      timestamp: timestamp,
      obbDetections: allDetections,
      totalDetections: obbList.length,
      inputImageWithBBox: bboxImageBytes,
      croppedImage: croppedBytes,
      ocrReading: ocrReading,
      ocrConfidence: ocrConfidence,
      rawOcrText: rawOcrText,
      processedText: processedText,
      logs: logs,
      inputWidth: inputW,
      inputHeight: inputH,
    );
  }

  /// Draw all OBB bounding boxes on the image
  void _drawAllBoundingBoxes(
    img.Image image,
    List<dynamic> obbList,
    YoloScenario scenario,
    List<String> logs,
  ) {
    final colors = [
      img.ColorRgb8(0, 255, 0),   // Green
      img.ColorRgb8(255, 0, 0),   // Red
      img.ColorRgb8(255, 255, 0), // Yellow
      img.ColorRgb8(0, 255, 255), // Cyan
    ];

    final pointColors = [
      img.ColorRgb8(255, 0, 0),   // P0: Red
      img.ColorRgb8(0, 255, 0),   // P1: Green
      img.ColorRgb8(0, 0, 255),   // P2: Blue
      img.ColorRgb8(255, 255, 0), // P3: Yellow
    ];

    for (int idx = 0; idx < obbList.length; idx++) {
      final detection = obbList[idx] as Map<dynamic, dynamic>;
      final points = detection['points'] as List<dynamic>? ?? [];
      final confidence = (detection['confidence'] as num?)?.toDouble() ?? 0.0;

      if (points.length != 4) continue;

      // Determine pixel points based on coordinate format
      final rawPoints = points.map((p) {
        final m = p as Map<dynamic, dynamic>;
        return {
          'x': (m['x'] as num).toDouble(),
          'y': (m['y'] as num).toDouble(),
        };
      }).toList();

      final isNormalized = rawPoints.every(
        (p) => p['x']! >= 0 && p['x']! <= 1.0 && p['y']! >= 0 && p['y']! <= 1.0,
      );

      List<Map<String, double>> pixelPoints;
      if (isNormalized) {
        pixelPoints = rawPoints.map((p) => {
          'x': p['x']! * image.width,
          'y': p['y']! * image.height,
        }).toList();
      } else {
        pixelPoints = rawPoints;
      }

      final color = colors[idx % colors.length];
      logs.add('Drawing bbox #$idx conf=${confidence.toStringAsFixed(3)} normalized=$isNormalized');

      // Draw 4 edges
      for (int i = 0; i < 4; i++) {
        final p1 = pixelPoints[i];
        final p2 = pixelPoints[(i + 1) % 4];
        img.drawLine(
          image,
          x1: p1['x']!.round(),
          y1: p1['y']!.round(),
          x2: p2['x']!.round(),
          y2: p2['y']!.round(),
          color: color,
          thickness: 3,
        );
      }

      // Draw corner points
      for (int i = 0; i < 4; i++) {
        final p = pixelPoints[i];
        img.drawCircle(
          image,
          x: p['x']!.round(),
          y: p['y']!.round(),
          radius: 5,
          color: img.ColorRgb8(255, 255, 255),
        );
        img.drawCircle(
          image,
          x: p['x']!.round(),
          y: p['y']!.round(),
          radius: 3,
          color: pointColors[i],
        );
      }
    }
  }

  /// Scenario 1 (pub cache): Android normalized coords crop
  Future<Uint8List?> _cropScenarioPubCache(
    Uint8List resizedImageBytes,
    List<dynamic> obbList,
    List<String> logs,
  ) async {
    final validDetections = <Map<String, dynamic>>[];
    for (final detection in obbList) {
      final boxes = detection as Map<dynamic, dynamic>;
      final points = boxes['points'] as List<dynamic>? ?? [];
      final confidence = (boxes['confidence'] as num).toDouble();

      if (points.length != 4) continue;
      if (confidence <= 0.2 || confidence >= 1.0) continue;

      final isNormalized = points.every((p) {
        final m = p as Map;
        final x = (m['x'] as num).toDouble();
        final y = (m['y'] as num).toDouble();
        return x >= 0 && x <= 1.0 && y >= 0 && y <= 1.0;
      });

      if (isNormalized) {
        validDetections.add({'points': points, 'confidence': confidence});
        logs.add('  Valid detection: conf=${confidence.toStringAsFixed(4)} normalized=true');
      }
    }

    if (validDetections.isEmpty) {
      logs.add('  No valid detections for pub cache crop');
      return null;
    }

    validDetections.sort((a, b) => (b['confidence'] as double).compareTo(a['confidence'] as double));
    final best = validDetections.first;
    logs.add('  Best detection: conf=${(best['confidence'] as double).toStringAsFixed(4)}');
    return cropImageFromOBB(resizedImageBytes, best['points'] as List<dynamic>);
  }

  /// Scenario 2 (local fork): iOS-like crop
  Uint8List? _cropScenarioLocalFork(
    Uint8List resizedImageBytes,
    List<dynamic> obbList,
    List<String> logs,
  ) {
    for (final detection in obbList) {
      final boxes = detection as Map<dynamic, dynamic>;
      final points = boxes['points'] as List<dynamic>? ?? [];
      final confidence = (boxes['confidence'] as num?)?.toDouble() ?? 0.0;

      if (points.length != 4) continue;
      if (confidence <= 0.2 || confidence >= 1.0) continue;

      logs.add('  Using iOS-like crop for conf=${confidence.toStringAsFixed(4)}');
      return cropImageFromOBB(resizedImageBytes, points);
    }
    logs.add('  No valid detections for local fork crop');
    return null;
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

    final results = await yolo.predict(resizedImageBytes);
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

  /// Scenario 3: Native OBB detection via TFLite method channel (android_2 pipeline)
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
    await yolo.dispose();
    await _ocrService.dispose();
  }
}

