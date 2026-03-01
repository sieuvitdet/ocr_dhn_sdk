import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

/// Service detect dong ho nuoc bang YOLO26n OBB
/// - Android: best_float32.tflite
/// - iOS:     best.mlpackage (da export voi nms=True)
class WaterMeterDetector {
  YOLO? _yolo;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  /// Model path tu dong theo platform
  String get modelPath {
    if (Platform.isAndroid) {
      return 'best_float32'; // android/app/src/main/assets/best_float32.tflite
    } else {
      return 'best'; // ios/Runner/best.mlpackage
    }
  }

  Future<void> loadModel() async {
    if (_isLoaded) return;

    _yolo = YOLO(
      modelPath: modelPath,
      task: YOLOTask.obb,
    );
    await _yolo!.loadModel();
    _isLoaded = true;
  }

  void dispose() {
    _yolo = null;
    _isLoaded = false;
  }

  /// Predict tu image bytes (chup tu camera hoac gallery)
  /// Tra ve DetectResult gom raw data + parsed detections
  Future<DetectResult> detectFromBytes(
    Uint8List imageBytes, {
    double confidenceThreshold = 0.25,
    double iouThreshold = 0.4,
  }) async {
    if (!_isLoaded || _yolo == null) {
      throw StateError('Model chua load. Goi loadModel() truoc.');
    }

    final rawResults = await _yolo!.predict(
      imageBytes,
      confidenceThreshold: confidenceThreshold,
      iouThreshold: iouThreshold,
    );

    final rawSummary = _buildRawSummary(rawResults);
    final detections = _parseResults(rawResults);

    // Log tat ca ra console de copy
    debugPrint('========== DETECT RESULT ==========');
    debugPrint('THRESHOLD: conf=$confidenceThreshold iou=$iouThreshold');
    debugPrint('RAW KEYS: ${rawResults.keys.toList()}');
    debugPrint(rawSummary);
    debugPrint('DETECTIONS: ${detections.length}');
    for (var i = 0; i < detections.length; i++) {
      final d = detections[i];
      debugPrint('[$i] ${d.className} conf=${(d.confidence * 100).toStringAsFixed(1)}%');
      debugPrint('    center=(${d.cx.toStringAsFixed(4)}, ${d.cy.toStringAsFixed(4)})');
      for (var j = 0; j < d.points.length; j++) {
        debugPrint('    P$j=(${d.points[j].dx.toStringAsFixed(4)}, ${d.points[j].dy.toStringAsFixed(4)})');
      }
    }
    debugPrint('===================================');

    // Lay annotatedImage (thu vien YOLO da ve bbox san)
    final annotatedImageBytes = rawResults['annotatedImage'] as List<dynamic>?;
    Uint8List? annotatedImage;
    if (annotatedImageBytes != null) {
      annotatedImage = Uint8List.fromList(annotatedImageBytes.cast<int>());
    }

    // Lay imageSize tu native (kich thuoc bitmap native da decode)
    final nativeImgSize = rawResults['imageSize'] as Map<dynamic, dynamic>?;
    final nativeW = (nativeImgSize?['width'] as num?)?.toInt() ?? 0;
    final nativeH = (nativeImgSize?['height'] as num?)?.toInt() ?? 0;
    debugPrint('NATIVE imageSize: ${nativeW}x$nativeH');

    return DetectResult(
      detections: detections,
      imageByteSize: imageBytes.length,
      confidenceThreshold: confidenceThreshold,
      iouThreshold: iouThreshold,
      rawKeys: rawResults.keys.toList(),
      rawSummary: rawSummary,
      annotatedImage: annotatedImage,
      nativeImageWidth: nativeW,
      nativeImageHeight: nativeH,
    );
  }

  String _buildRawSummary(Map<String, dynamic> results) {
    final buf = StringBuffer();
    for (final key in results.keys) {
      final val = results[key];
      if (key == 'annotatedImage') {
        buf.writeln('[$key] = ${(val as List?)?.length ?? 0} bytes');
      } else if (val is List) {
        buf.writeln('[$key] length=${val.length}');
        for (var i = 0; i < val.length && i < 3; i++) {
          buf.writeln('  [$i] ${val[i]}');
        }
      } else {
        buf.writeln('[$key] = $val');
      }
    }
    return buf.toString();
  }

  List<OBBDetection> _parseResults(Map<String, dynamic> results) {
    // OBB task tra ve key 'obb', KHONG phai 'boxes'
    // 'boxes' luon empty voi OBB task tren Android
    final obbList = results['obb'] as List<dynamic>? ?? [];
    debugPrint('=== Parsing ${obbList.length} obb detections ===');
    return obbList.map((obb) {
      // points la list of map {x, y} (normalized 0..1)
      final rawPoints = obb['points'] as List<dynamic>? ?? [];
      final points = rawPoints
          .map((p) {
            if (p is Map) {
              return Offset(
                (p['x'] as num?)?.toDouble() ?? 0.0,
                (p['y'] as num?)?.toDouble() ?? 0.0,
              );
            }
            return Offset(
              (p[0] as num).toDouble(),
              (p[1] as num).toDouble(),
            );
          })
          .toList();

      // Tinh center, width, height tu 4 points
      double cx = 0, cy = 0;
      for (final p in points) {
        cx += p.dx;
        cy += p.dy;
      }
      if (points.isNotEmpty) {
        cx /= points.length;
        cy /= points.length;
      }

      // Raw OBB data from native (now included in response)
      final rawW = (obb['w'] as num?)?.toDouble() ?? 0.0;
      final rawH = (obb['h'] as num?)?.toDouble() ?? 0.0;
      final rawAngle = (obb['angle'] as num?)?.toDouble() ?? 0.0;
      final rawCx = (obb['cx'] as num?)?.toDouble() ?? cx;
      final rawCy = (obb['cy'] as num?)?.toDouble() ?? cy;

      return OBBDetection(
        className: obb['class'] as String? ?? 'unknown',
        confidence: (obb['confidence'] as num?)?.toDouble() ?? 0.0,
        angleDeg: rawAngle * 180 / 3.14159265, // radians to degrees
        points: points,
        cx: rawCx,
        cy: rawCy,
        width: rawW,
        height: rawH,
      );
    }).toList();
  }
}

/// Ket qua 1 OBB detection
class OBBDetection {
  final String className;
  final double confidence;
  final double angleDeg;
  final List<Offset> points; // 4 goc cua rotated box
  final double cx, cy; // tam
  final double width, height;

  const OBBDetection({
    required this.className,
    required this.confidence,
    required this.angleDeg,
    required this.points,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
  });

  @override
  String toString() =>
      'OBB($className ${(confidence * 100).toStringAsFixed(1)}% '
      'angle=${angleDeg.toStringAsFixed(1)} '
      'center=(${cx.toInt()},${cy.toInt()}) '
      '${width.toInt()}x${height.toInt()})';
}

/// Ket qua detect gom raw data + parsed detections
class DetectResult {
  final List<OBBDetection> detections;
  final int imageByteSize;
  final double confidenceThreshold;
  final double iouThreshold;
  final List<String> rawKeys;
  final String rawSummary;
  final Uint8List? annotatedImage; // Anh da ve bbox boi thu vien YOLO
  final int nativeImageWidth; // Kich thuoc bitmap native da xu ly
  final int nativeImageHeight;

  const DetectResult({
    required this.detections,
    required this.imageByteSize,
    required this.confidenceThreshold,
    required this.iouThreshold,
    required this.rawKeys,
    required this.rawSummary,
    this.annotatedImage,
    this.nativeImageWidth = 0,
    this.nativeImageHeight = 0,
  });
}
