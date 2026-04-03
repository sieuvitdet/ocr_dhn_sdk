import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:ultralytics_yolo/yolo.dart';
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/models/detection_test_result.dart';
import 'package:water_meter_sdk/services/water_meter_ocr_service.dart';
import 'package:water_meter_sdk/services/paddle_ocr_service.dart';

/// OCR engine selection
enum OcrEngine { mlKit, paddleOcr }

class WaterMeterSdkUltralyticsYolo {
  static const _methodChannel = MethodChannel('water_meter_sdk');
  final WaterMeterOCRService _ocrService = WaterMeterOCRService();
  final PaddleOCRService _paddleOcrService = PaddleOCRService();
  /// Switch between OCR engines at runtime.
  OcrEngine ocrEngine = OcrEngine.paddleOcr;
  late YOLO yolo;
  bool _isInitialized = false;
  Future<void>? _initFuture;

  bool get isInitialized => _isInitialized;

  /// Model path based on platform
  String get modelPath {
    if (Platform.isAndroid) {
      return 'best_float32'; // android/app/src/main/assets/best_float32.tflite
    } else {
      return 'yolo11n-obb'; // ios/Runner/best.mlpackage
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
    // Initialize PaddleOCR engine (cross-platform ONNX)
    try {
      await _paddleOcrService.init();
    } catch (e) {
      print('PaddleOCR init failed, falling back to ML Kit: $e');
      ocrEngine = OcrEngine.mlKit;
    }

    if (Platform.isAndroid) {
      // Android uses native TFLite detection via method channel - no YOLO needed
      _isInitialized = true;
      return;
    }
    // iOS: initialize YOLO for Dart-side OBB detection
    yolo = YOLO(
      modelPath: modelPath,
      task: YOLOTask.obb,
    );
    await yolo.loadModel();
    _isInitialized = true;
  }

  /// Unified entry point: auto-routes Android → native TFLite, iOS → Dart YOLO
  Future<WaterMeterResult> processImage(Uint8List imageBytes, {bool isOnline = true}) async {
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

  /// Run OCR using the currently selected engine.
  /// Uses multi-orientation strategy: tries 0°/90°/270° and picks best.
  /// Public so callers (e.g. example app) can run local OCR on pre-cropped bytes.
  Future<WaterMeterResult> runLocalOcr(Uint8List imageBytes) async {
    if (ocrEngine == OcrEngine.paddleOcr && _paddleOcrService.isInitialized) {
      // Multi-orientation: try original + rotations, pick best result
      final result =
          await _paddleOcrService.recognizeMultiOrientation(imageBytes);
      final rawText = result.rawText;
      final candidates = result.candidates;
      final orientation = result.orientation;
      final correctedRaw = PaddleOCRService.correctRawText(rawText);
      final bestReading =
          candidates.isNotEmpty ? candidates.first.text : '';
      final bestConf =
          candidates.isNotEmpty ? candidates.first.confidence : 0.0;

      final debugInfo = <String>[
        'Engine: PaddleOCR (ONNX, multi-orientation, beam w=${PaddleOCRService.beamWidth})',
        'Orientation used: $orientation',
        'Raw (all chars): "$rawText"',
        'Raw corrected: "$correctedRaw"',
        'Best reading: "$bestReading" (conf: ${(bestConf * 100).toStringAsFixed(1)}%)',
      ];
      if (candidates.length > 1) {
        debugInfo.add('--- All candidates (${candidates.length}) ---');
        for (int i = 0; i < candidates.length; i++) {
          debugInfo.add('  #${i + 1}: ${candidates[i]}');
        }
      }

      return WaterMeterResult(
        reading: bestReading,
        confidence: bestConf,
        imageBytes: imageBytes,
        rawOcrText: rawText,
        processedText: bestReading,
        debugInfo: debugInfo,
        candidates: candidates,
      );
    } else {
      return await _ocrService.processImage(imageBytes);
    }
  }

  /// iOS path: YOLO OBB detection + crop + OCR
  Future<WaterMeterResult?> processWaterMeterImage(Uint8List imageBytes, {bool isOnline = false}) async {
    var croppedBytesAfter = await runOBBDetectionAndCrop(imageBytes);
    croppedBytesAfter = _ensureLandscape(croppedBytesAfter, null);
    if (isOnline) {
      final tempFile = await saveBytesToTempFile(croppedBytesAfter, 'cropped.jpg');
      final ocrApi = GetNumberOCR();
      final result = await ocrApi.ocrImage(tempFile, autoOrientation: true);
      try { tempFile.deleteSync(); } catch (_) {}
      return WaterMeterResult(
        imageBytes: croppedBytesAfter,
        reading: result?.text ?? '',
        confidence: result?.score ?? 0,
        rawOcrText: result?.rawText,
      );
    } else {
      return await runLocalOcr(croppedBytesAfter);
    }
  }

  Future<File> saveBytesToTempFile(Uint8List bytes, String filename) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$filename');
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Decode image bytes with EXIF orientation applied.
  static img.Image? decodeWithExif(Uint8List imageBytes) {
    final image = img.decodeImage(imageBytes);
    if (image == null) return null;
    return img.bakeOrientation(image);
  }

  Future<Uint8List> runOBBDetectionAndCrop(Uint8List imageBytes) async {

    Uint8List imageBytesAfter;

    final originalImageBytes = imageBytes;
    
    final originalImage = decodeWithExif(originalImageBytes);
    if (originalImage == null) {
      return imageBytes;
    }

    final resizedImage = img.copyResize(originalImage, width: 416, height: 416);
    final resizedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));
    
    final results = await yolo!.predict(resizedImageBytes);
    final obbList = results['obb'] as List<dynamic>;
    
    if (obbList.isNotEmpty) {
      final detections = <Map<String, dynamic>>[];
      
      for (final detection in obbList) {
        final boxes = detection as Map<dynamic, dynamic>;
        final points = boxes['points'] as List<dynamic>? ?? [];
        if (points.isNotEmpty) {
          double minX = double.infinity;
          double maxX = double.negativeInfinity;
          double minY = double.infinity;
          double maxY = double.negativeInfinity;
          
          for (final point in points) {
            final pointMap = point as Map<dynamic, dynamic>;
            final x = (pointMap['x'] as num).toDouble();
            final y = (pointMap['y'] as num).toDouble();
            
            minX = minX < x ? minX : x;
            maxX = maxX > x ? maxX : x;
            minY = minY < y ? minY : y;
            maxY = maxY > y ? maxY : y;
          }

          detections.add({
                'class': boxes['class'],
                'confidence': (boxes['confidence'] as num).toDouble(),
                'points': points,
              });
              print('  --- $boxes');

          if (points.isNotEmpty && points.length == 4 && (boxes['confidence'] as num).toDouble() > 0.2 && (boxes['confidence'] as num).toDouble() < 1) { 
            imageBytesAfter = cropImageFromOBB(resizedImageBytes, points);
            return imageBytesAfter;
          }
        }
        
        // Add to detections list for drawing
        detections.add({
          'class': boxes['class'],
          'confidence': (boxes['confidence'] as num).toDouble(),
          'points': points,
        });
        print('  ---');
      }
      
    } 
    return imageBytes;
  }

  Uint8List cropImageFromOBB(Uint8List imageBytes, List<dynamic> points) {
    final image = decodeWithExif(imageBytes);
    if (image == null) throw Exception('Failed to decode image for cropping');

    // Parse OBB corner points (normalized 0..1 → pixel coords)
    final pixelPoints = <Map<String, double>>[];
    for (final point in points) {
      final pointMap = point as Map<dynamic, dynamic>;
      pixelPoints.add({
        'x': (pointMap['x'] as num).toDouble(),
        'y': (pointMap['y'] as num).toDouble(),
      });
    }

    // Compute OBB rotation angle from corner points
    final angleDeg = _computeAngleFromPoints(
      pixelPoints,
      image.width.toDouble(),
      image.height.toDouble(),
    );

    // Rotate the full image to deskew (make the OBB axis-aligned)
    img.Image deskewed;
    if (angleDeg.abs() > 2.0) {
      deskewed = img.copyRotate(image, angle: -angleDeg, interpolation: img.Interpolation.linear);
    } else {
      deskewed = image;
    }

    // After rotation, recompute axis-aligned bounding box
    // Rotate corner points by -angleDeg around image center to find new positions
    final radians = -angleDeg * math.pi / 180.0;
    final cosA = math.cos(radians);
    final sinA = math.sin(radians);
    final ocx = image.width / 2.0;
    final ocy = image.height / 2.0;
    // The rotated canvas may be larger; compute its center
    final dcx = deskewed.width / 2.0;
    final dcy = deskewed.height / 2.0;

    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (final pt in pixelPoints) {
      final px = pt['x']! * image.width;
      final py = pt['y']! * image.height;
      // Rotate around original image center, then translate to deskewed center
      final rx = cosA * (px - ocx) - sinA * (py - ocy) + dcx;
      final ry = sinA * (px - ocx) + cosA * (py - ocy) + dcy;
      minX = math.min(minX, rx);
      maxX = math.max(maxX, rx);
      minY = math.min(minY, ry);
      maxY = math.max(maxY, ry);
    }

    // Add padding
    const padding = 15;
    minX = math.max(0, minX - padding);
    minY = math.max(0, minY - padding);
    maxX = math.min(deskewed.width.toDouble(), maxX + padding);
    maxY = math.min(deskewed.height.toDouble(), maxY + padding);

    final cropW = (maxX - minX).round().clamp(1, deskewed.width);
    final cropH = (maxY - minY).round().clamp(1, deskewed.height);

    final croppedImage = img.copyCrop(
      deskewed,
      x: minX.round().clamp(0, deskewed.width - 1),
      y: minY.round().clamp(0, deskewed.height - 1),
      width: cropW,
      height: cropH,
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
    Uint8List? croppedImageBytes = nativeResult['croppedImage'] as Uint8List?;

    // Deskew the native-cropped image using angle computed from corner points.
    // Using _computeAngleFromPoints (same as iOS) ensures the LONGER edge
    // (digit strip) is aligned horizontally. The native angleDeg can refer
    // to the short side when OBB h > w, causing digits to end up vertical.
    if (croppedImageBytes != null && allDetections.isNotEmpty) {
      final bestDet = allDetections.first;
      final nativeAngle = (bestDet['angleDeg'] as num?)?.toDouble() ?? 0.0;

      final pointsList = bestDet['points'] as List<dynamic>;
      final detPoints = pointsList.map((p) {
        final m = p as Map<String, dynamic>;
        return <String, double>{
          'x': (m['x'] as num).toDouble(),
          'y': (m['y'] as num).toDouble(),
        };
      }).toList();
      // imgW/imgH=1.0 since points are in consistent coords (angle is scale-invariant)
      final angleDeg = _computeAngleFromPoints(detPoints, 1.0, 1.0);

      logs.add('Native angleDeg=${nativeAngle.toStringAsFixed(1)}°, '
          'corner-based=${angleDeg.toStringAsFixed(1)}°');

      if (angleDeg.abs() > 2.0) {
        logs.add('Deskewing cropped image by ${angleDeg.toStringAsFixed(1)}°');
        final croppedImg = img.decodeImage(croppedImageBytes);
        if (croppedImg != null) {
          croppedImageBytes = _rotateAndCrop(croppedImg, angleDeg);
        }
      }
    }

    // Ensure cropped image is landscape (digits horizontal)
    if (croppedImageBytes != null) {
      croppedImageBytes = _ensureLandscape(croppedImageBytes, logs);
    }

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
        final apiResult = await ocrApi.ocrImage(tempFile, autoOrientation: true);
        ocrReading = apiResult?.text ?? '';
        ocrConfidence = apiResult?.score ?? 0;
        rawOcrText = apiResult?.text;
        logs.add('Online OCR result: $ocrReading (conf: ${(ocrConfidence * 100).toStringAsFixed(1)}%)');
      } catch (e) {
        logs.add('Online OCR error: $e');
      }
    } else {
      try {
        logs.add('OCR engine: ${ocrEngine.name}');
        final ocrResult = await runLocalOcr(bytesForOcr);
        ocrReading = ocrResult.reading;
        ocrConfidence = ocrResult.confidence;
        rawOcrText = ocrResult.rawOcrText;
        processedText = ocrResult.processedText;
        if (ocrResult.debugInfo != null) logs.addAll(ocrResult.debugInfo!);
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

  /// Run OBB detection + offline OCR on a single image.
  /// Returns a map with: originalImage, croppedImage, ocrResult, logs.
  Future<Map<String, dynamic>> testSingleImageOffline(Uint8List imageBytes, {String? imageName}) async {
    if (!_isInitialized) {
      throw StateError('SDK not initialized. Call init() first.');
    }

    final logs = <String>[];
    final name = imageName ?? 'unknown';
    logs.add('=== Testing: $name ===');

    // Decode with EXIF
    final decoded = decodeWithExif(imageBytes);
    if (decoded == null) {
      logs.add('ERROR: Failed to decode image');
      return {
        'imageName': name,
        'originalImage': imageBytes,
        'croppedImage': null,
        'ocrResult': WaterMeterResult.empty(),
        'logs': logs,
      };
    }
    logs.add('Decoded: ${decoded.width}x${decoded.height}');

    Uint8List croppedBytes;
    if (Platform.isAndroid) {
      // Use native OBB
      final result = await processWithNativeObb(imageBytes, isOnline: false);
      croppedBytes = result.croppedImage ?? imageBytes;
      logs.addAll(result.logs);

      return {
        'imageName': name,
        'originalImage': imageBytes,
        'croppedImage': croppedBytes,
        'annotatedImage': result.inputImageWithBBox,
        'ocrResult': WaterMeterResult(
          reading: result.ocrReading,
          confidence: result.ocrConfidence,
          imageBytes: croppedBytes,
          rawOcrText: result.rawOcrText,
          processedText: result.processedText,
          debugInfo: logs,
        ),
        'logs': logs,
      };
    } else {
      // iOS: use Dart YOLO OBB
      croppedBytes = await runOBBDetectionAndCrop(imageBytes);
      final isCropped = croppedBytes != imageBytes;
      logs.add(isCropped ? 'OBB detected and cropped' : 'No OBB detection, using original');

      // Run local OCR on cropped image using selected engine
      logs.add('OCR engine: ${ocrEngine.name}');
      final ocrResult = await runLocalOcr(croppedBytes);
      logs.add('OCR reading: ${ocrResult.reading}');
      logs.add('OCR confidence: ${(ocrResult.confidence * 100).toStringAsFixed(1)}%');
      if (ocrResult.debugInfo != null) logs.addAll(ocrResult.debugInfo!);

      return {
        'imageName': name,
        'originalImage': imageBytes,
        'croppedImage': croppedBytes,
        'ocrResult': ocrResult,
        'logs': logs,
      };
    }
  }

  /// Run OBB + offline OCR on all images in [assetPaths].
  /// Each path should be a Flutter asset path like 'assets/test_images/sample.jpg'.
  /// Returns a list of result maps (see [testSingleImageOffline]).
  Future<List<Map<String, dynamic>>> testBatchOffline(List<String> assetPaths) async {
    final results = <Map<String, dynamic>>[];

    for (final path in assetPaths) {
      try {
        final data = await rootBundle.load(path);
        final bytes = data.buffer.asUint8List();
        final name = path.split('/').last;
        final result = await testSingleImageOffline(bytes, imageName: name);
        results.add(result);
      } catch (e) {
        results.add({
          'imageName': path.split('/').last,
          'originalImage': null,
          'croppedImage': null,
          'ocrResult': WaterMeterResult(
            reading: '',
            confidence: 0,
            debugInfo: ['Error loading asset $path: $e'],
          ),
          'logs': ['Error loading asset $path: $e'],
        });
      }
    }

    return results;
  }

  /// Ensure cropped water meter image has digits in horizontal orientation.
  /// Water meter digit strips are always wider than tall (landscape).
  /// If the cropped image is portrait, rotate 90° CW to make it landscape.
  static Uint8List _ensureLandscape(Uint8List imageBytes, List<String>? logs) {
    final decoded = decodeWithExif(imageBytes);
    if (decoded == null) return imageBytes;

    // Already landscape or square — no rotation needed
    if (decoded.width >= decoded.height) {
      return imageBytes;
    }

    // Portrait image: digits are vertical, rotate 90° CW
    logs?.add('Auto-rotating portrait image (${decoded.width}x${decoded.height}) → landscape');
    final rotated = img.copyRotate(decoded, angle: 90);
    return Uint8List.fromList(img.encodePng(rotated));
  }

  /// Compute rotation angle (degrees) from 4 OBB corner points.
  /// Points are in normalized [0..1] coordinates; [imgW]/[imgH] convert to pixels.
  /// Returns the angle of the longer edge (the "width" edge of a water meter).
  static double _computeAngleFromPoints(
    List<Map<String, double>> pts,
    double imgW,
    double imgH,
  ) {
    // Convert normalised → pixel
    final px = pts.map((p) => p['x']! * imgW).toList();
    final py = pts.map((p) => p['y']! * imgH).toList();

    // Edge 0→1
    final dx01 = px[1] - px[0];
    final dy01 = py[1] - py[0];
    final len01 = math.sqrt(dx01 * dx01 + dy01 * dy01);

    // Edge 1→2
    final dx12 = px[2] - px[1];
    final dy12 = py[2] - py[1];
    final len12 = math.sqrt(dx12 * dx12 + dy12 * dy12);

    // The longer edge is the "width" edge (meters are wider than tall)
    double angle;
    if (len01 >= len12) {
      angle = math.atan2(dy01, dx01);
    } else {
      angle = math.atan2(dy12, dx12);
    }

    // Convert to degrees
    var degrees = angle * 180.0 / math.pi;

    // Normalize to [-90°, 90°] — water meters are roughly horizontal,
    // so angles near ±180° mean the edge vector points "backwards".
    // Without this, deskewing would flip the image 180°.
    if (degrees > 90) {
      degrees -= 180;
    } else if (degrees < -90) {
      degrees += 180;
    }

    return degrees;
  }

  /// Rotate [image] by -[angleDeg] to deskew, then center-crop to remove
  /// black corners introduced by rotation.  Returns PNG bytes.
  /// If |angleDeg| <= 2° the image is returned unchanged.
  static Uint8List _rotateAndCrop(img.Image image, double angleDeg) {
    if (angleDeg.abs() <= 2.0) {
      return Uint8List.fromList(img.encodePng(image));
    }

    // Rotate by negative angle to make text horizontal
    // Use linear interpolation for better quality at large angles (45-60°)
    final rotated = img.copyRotate(image, angle: -angleDeg, interpolation: img.Interpolation.linear);

    // After rotation the canvas grows; compute the largest axis-aligned
    // rectangle inscribed in the original rectangle after rotation.
    final radians = angleDeg.abs() * math.pi / 180.0;
    final cosA = math.cos(radians);
    final sinA = math.sin(radians);

    final origW = image.width.toDouble();
    final origH = image.height.toDouble();

    // Inscribed rectangle dimensions inside rotated original rect
    double newW, newH;
    if (sinA == 0) {
      newW = origW;
      newH = origH;
    } else {
      newW = (origW * cosA - origH * sinA).abs();
      newH = (origH * cosA - origW * sinA).abs();
      // Clamp to ensure we don't exceed the original dimensions
      newW = math.min(newW, origW);
      newH = math.min(newH, origH);
      // Fallback: if computed rect is too small, use 80% of rotated canvas
      if (newW < origW * 0.5 || newH < origH * 0.5) {
        newW = rotated.width * 0.85;
        newH = rotated.height * 0.85;
      }
    }

    final cropX = ((rotated.width - newW) / 2).round();
    final cropY = ((rotated.height - newH) / 2).round();
    final cropW = newW.round().clamp(1, rotated.width - cropX);
    final cropH = newH.round().clamp(1, rotated.height - cropY);

    final cropped = img.copyCrop(
      rotated,
      x: cropX,
      y: cropY,
      width: cropW,
      height: cropH,
    );

    return Uint8List.fromList(img.encodePng(cropped));
  }

  /// Save cropped+EXIF-processed image to a directory.
  /// Returns the saved file path.
  static Future<String> saveProcessedImage(
    Uint8List imageBytes,
    String filename, {
    String? directory,
  }) async {
    final dir = directory ?? (await getTemporaryDirectory()).path;
    final saveDir = Directory('$dir/cropped_test_images');
    if (!saveDir.existsSync()) {
      saveDir.createSync(recursive: true);
    }

    // Apply EXIF orientation and re-encode clean
    final decoded = decodeWithExif(imageBytes);
    final Uint8List cleanBytes;
    if (decoded != null) {
      if (filename.toLowerCase().endsWith('.png')) {
        cleanBytes = Uint8List.fromList(img.encodePng(decoded));
      } else {
        cleanBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 95));
      }
    } else {
      cleanBytes = imageBytes;
    }

    final filePath = '${saveDir.path}/$filename';
    File(filePath).writeAsBytesSync(cleanBytes);
    return filePath;
  }

  /// Save all cropped images from batch test results to documents directory.
  /// Returns the directory path where images were saved.
  static Future<String> saveBatchCroppedImages(
    List<Map<String, dynamic>> results,
  ) async {
    final docDir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${docDir.path}/cropped_test_images');
    if (saveDir.existsSync()) {
      saveDir.deleteSync(recursive: true);
    }
    saveDir.createSync(recursive: true);

    for (final result in results) {
      final name = result['imageName'] as String? ?? 'unknown';
      final croppedBytes = result['croppedImage'] as Uint8List?;
      if (croppedBytes == null) continue;

      final baseName = name.replaceAll(RegExp(r'\.[^.]+$'), '');
      final filename = '${baseName}_cropped.jpg';

      // Decode, apply EXIF, save clean JPEG
      final decoded = decodeWithExif(croppedBytes);
      if (decoded != null) {
        final clean = Uint8List.fromList(img.encodeJpg(decoded, quality: 95));
        File('${saveDir.path}/$filename').writeAsBytesSync(clean);
      } else {
        File('${saveDir.path}/$filename').writeAsBytesSync(croppedBytes);
      }
    }

    return saveDir.path;
  }

  Future<void> dispose() async {
    if (Platform.isIOS && yolo != null) {
      await yolo!.dispose();
    }
    await _ocrService.dispose();
    await _paddleOcrService.dispose();
  }
}
