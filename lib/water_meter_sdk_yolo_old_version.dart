import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:ultralytics_yolo/yolo.dart';
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:water_meter_sdk/models/detection_test_result.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/services/water_meter_ocr_service.dart';

class WaterMeterSdkYoloOldVersion {
  final WaterMeterOCRService _ocrService = WaterMeterOCRService();
  late YOLO yolo;

  String get modelPath {
    if (Platform.isAndroid) {
      return 'yolo11n-obb';
    } else {
      return 'yolo11n-obb';
    }
  }


  Future init() async {
      yolo = YOLO(
          modelPath: modelPath,
        task: YOLOTask.obb,
      );
      await yolo.loadModel();
  }

  Future<WaterMeterResult?> processWaterMeterImage(Uint8List imageBytes, {bool isOnline = false}) async {
    debugPrint('[OldVersion] processWaterMeterImage start, inputSize=${imageBytes.length} bytes, isOnline=$isOnline');
    final stopwatch = Stopwatch()..start();

    final croppedBytesAfter = await runOBBDetectionAndCrop(imageBytes);
    debugPrint('[OldVersion] OBB detect+crop done in ${stopwatch.elapsedMilliseconds}ms, croppedSize=${croppedBytesAfter.length} bytes');

    if (isOnline) {
      final tempFile = await saveBytesToTempFile(croppedBytesAfter, 'cropped.jpg');
      final ocrApi = GetNumberOCR();
      final result = await ocrApi.ocrImage(tempFile);
      debugPrint('[OldVersion] Online OCR result: "$result", total=${stopwatch.elapsedMilliseconds}ms');
      return WaterMeterResult(
        imageBytes: croppedBytesAfter,
        reading: result ?? '',
        confidence: 0,
      );
    } else {
      final ocrResult = await _ocrService.processImage(croppedBytesAfter);
      debugPrint('[OldVersion] Offline OCR reading="${ocrResult.reading}", confidence=${ocrResult.confidence}, total=${stopwatch.elapsedMilliseconds}ms');
      return ocrResult;
    }
  }

  /// Test scenario: detect + draw bbox + crop + OCR, return rich result with logs
  Future<DetectionTestResult> processWithScenario(
    Uint8List imageBytes, {
    bool isOnline = false,
  }) async {
    final logs = <String>[];
    final timestamp = DateTime.now();

    // Decode original image
    final originalImage = img.decodeImage(imageBytes);
    if (originalImage == null) {
      return DetectionTestResult(
        scenario: YoloScenario.oldVersion,
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
    logs.add('Running YOLO predict (yolo11n-obb)...');
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

    // Draw bounding boxes on resized image
    final bboxImage = img.Image.from(resizedImage);
    _drawAllBoundingBoxes(bboxImage, obbList, logs);
    final bboxImageBytes = Uint8List.fromList(img.encodePng(bboxImage));

    // Crop: use first valid detection (same logic as runOBBDetectionAndCrop)
    Uint8List? croppedBytes;
    for (final detection in obbList) {
      final boxes = detection as Map<dynamic, dynamic>;
      final points = boxes['points'] as List<dynamic>? ?? [];
      final confidence = (boxes['confidence'] as num?)?.toDouble() ?? 0.0;

      if (points.length == 4 && confidence > 0.2 && confidence < 1) {
        logs.add('Cropping detection conf=${confidence.toStringAsFixed(4)}');
        try {
          croppedBytes = cropImageFromOBB(resizedImageBytes, points);
        } catch (e) {
          logs.add('ERROR during crop: $e');
        }
        break;
      }
    }

    if (croppedBytes == null) {
      logs.add('No valid detection for cropping');
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
        final tempFile = await saveBytesToTempFile(bytesForOcr, 'cropped_old_version.jpg');
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
      scenario: YoloScenario.oldVersion,
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
    List<String> logs,
  ) {
    final colors = [
      img.ColorRgb8(0, 255, 0),
      img.ColorRgb8(255, 0, 0),
      img.ColorRgb8(255, 255, 0),
      img.ColorRgb8(0, 255, 255),
    ];

    final pointColors = [
      img.ColorRgb8(255, 0, 0),
      img.ColorRgb8(0, 255, 0),
      img.ColorRgb8(0, 0, 255),
      img.ColorRgb8(255, 255, 0),
    ];

    for (int idx = 0; idx < obbList.length; idx++) {
      final detection = obbList[idx] as Map<dynamic, dynamic>;
      final points = detection['points'] as List<dynamic>? ?? [];
      final confidence = (detection['confidence'] as num?)?.toDouble() ?? 0.0;

      if (points.length != 4) continue;

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

  Future<File> saveBytesToTempFile(Uint8List bytes, String filename) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$filename');
    await file.writeAsBytes(bytes);
    return file;
  }



  Future<Uint8List> runOBBDetectionAndCrop(Uint8List imageBytes) async {

    Uint8List imageBytesAfter;

    final originalImageBytes = imageBytes;

    final originalImage = img.decodeImage(originalImageBytes);
    if (originalImage == null) {
      debugPrint('[OldVersion] runOBBDetectionAndCrop: Failed to decode image');
      return imageBytes;
    }

    debugPrint('[OldVersion] Original image: ${originalImage.width}x${originalImage.height}');
    final resizedImage = img.copyResize(originalImage, width: 416, height: 416);
    final resizedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));
    debugPrint('[OldVersion] Resized to 416x416, running YOLO predict...');

    final results = await yolo.predict(resizedImageBytes);
    final obbList = results['obb'] as List<dynamic>;
    debugPrint('[OldVersion] YOLO result keys: ${results.keys.toList()}, OBB detections: ${obbList.length}');

    if (obbList.isNotEmpty) {
      final detections = <Map<String, dynamic>>[];

      for (int i = 0; i < obbList.length; i++) {
        final detection = obbList[i];
        final boxes = detection as Map<dynamic, dynamic>;
        final points = boxes['points'] as List<dynamic>? ?? [];
        final confidence = (boxes['confidence'] as num).toDouble();
        final className = boxes['class'];
        debugPrint('[OldVersion] Detection #$i: class=$className, confidence=${confidence.toStringAsFixed(4)}, points=${points.length}');

        if (points.isNotEmpty) {
          for (int j = 0; j < points.length; j++) {
            final p = points[j] as Map<dynamic, dynamic>;
            debugPrint('[OldVersion]   P$j: x=${p['x']}, y=${p['y']}');
          }

          detections.add({
                'class': className,
                'confidence': confidence,
                'points': points,
              });

          if (points.length == 4 && confidence > 0.2 && confidence < 1) {
            debugPrint('[OldVersion] Cropping detection #$i (conf=${confidence.toStringAsFixed(4)})');
            imageBytesAfter = cropImageFromOBB(resizedImageBytes, points);
            debugPrint('[OldVersion] Cropped image size: ${imageBytesAfter.length} bytes');
            return imageBytesAfter;
          } else {
            debugPrint('[OldVersion] Skipping detection #$i: points=${points.length}, conf=$confidence (need 4 points & 0.2<conf<1)');
          }
        }
      }

    } else {
      debugPrint('[OldVersion] No OBB detections found');
    }
    debugPrint('[OldVersion] No valid detection for cropping, returning original image');
    return imageBytes;
  }

  Uint8List cropImageFromOBB(Uint8List imageBytes, List<dynamic> points) {
    final image = img.decodeImage(imageBytes);
    if (image == null) throw Exception('Failed to decode image for cropping');

    // Calculate bounding box from OBB points
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

    // Add some padding
    final padding = Platform.isIOS ? 15 : 0;
    minX = math.max(0, minX - padding);
    minY = math.max(0, minY - padding);
    maxX = math.min(image.width.toDouble(), maxX + padding);
    maxY = math.min(image.height.toDouble(), maxY + padding);

    // Crop the image
    final croppedImage = img.copyCrop(
      image,
      x: minX.round(),
      y: minY.round(),
      width: (maxX - minX).round(),
      height: (maxY - minY).round(),
    );

    return Uint8List.fromList(img.encodePng(croppedImage));
  }

  Future<void> dispose() async {
    await yolo.dispose();
    await _ocrService.dispose();
  }
}
