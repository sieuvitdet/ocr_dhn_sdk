import 'dart:typed_data';

/// Enum for test scenarios
enum YoloScenario {
  /// Scenario 1: ultralytics_yolo from pub cache (default package)
  /// Android returns normalized coordinates
  pubCache,

  /// Scenario 2: ultralytics_yolo from /packages (local fork)
  /// Android modified .kt to return data like iOS (pixel coordinates)
  localFork,

  /// Scenario 0: YOLO Old Version (yolo11n-obb model)
  oldVersion,

  /// Scenario 3: Native OBB via TFLite method channel (android_2 pipeline)
  nativeObb,
}

/// Rich result from detection test including all debug data
class DetectionTestResult {
  final YoloScenario scenario;
  final DateTime timestamp;

  // OBB detection raw data
  final List<Map<String, dynamic>> obbDetections;
  final int totalDetections;

  // Images
  final Uint8List? inputImageWithBBox; // input image with bounding boxes drawn
  final Uint8List? croppedImage; // cropped OBB region

  // OCR
  final String ocrReading;
  final double ocrConfidence;
  final String? rawOcrText;
  final String? processedText;

  // Debug logs
  final List<String> logs;

  // Image metadata
  final int inputWidth;
  final int inputHeight;
  final int resizedWidth;
  final int resizedHeight;

  const DetectionTestResult({
    required this.scenario,
    required this.timestamp,
    required this.obbDetections,
    required this.totalDetections,
    this.inputImageWithBBox,
    this.croppedImage,
    required this.ocrReading,
    required this.ocrConfidence,
    this.rawOcrText,
    this.processedText,
    required this.logs,
    this.inputWidth = 0,
    this.inputHeight = 0,
    this.resizedWidth = 416,
    this.resizedHeight = 416,
  });

  /// Format all data as copyable log text
  String toLogText() {
    final buf = StringBuffer();
    buf.writeln('========== DETECTION TEST LOG ==========');
    buf.writeln('Timestamp: ${timestamp.toIso8601String()}');
    final scenarioLabel = switch (scenario) {
      YoloScenario.pubCache => '1 - Pub Cache (default)',
      YoloScenario.localFork => '2 - Local Fork (/packages)',
      YoloScenario.oldVersion => '0 - YOLO Old Version (yolo11n-obb)',
      YoloScenario.nativeObb => '3 - Native OBB (TFLite method channel)',
    };
    buf.writeln('Scenario: $scenarioLabel');
    buf.writeln('');
    buf.writeln('--- IMAGE INFO ---');
    buf.writeln('Input: ${inputWidth}x$inputHeight');
    buf.writeln('Resized: ${resizedWidth}x$resizedHeight');
    buf.writeln('');
    buf.writeln('--- OBB DETECTIONS ($totalDetections) ---');
    for (int i = 0; i < obbDetections.length; i++) {
      final det = obbDetections[i];
      buf.writeln('[$i] class=${det['class']} confidence=${det['confidence']}');
      final points = det['points'] as List<dynamic>?;
      if (points != null) {
        for (int j = 0; j < points.length; j++) {
          final p = points[j];
          if (p is Map) {
            buf.writeln('    P$j=(${p['x']}, ${p['y']})');
          }
        }
      }
    }
    buf.writeln('');
    buf.writeln('--- OCR RESULT ---');
    buf.writeln('Reading: $ocrReading');
    buf.writeln('Confidence: ${(ocrConfidence * 100).toStringAsFixed(1)}%');
    if (rawOcrText != null) buf.writeln('Raw OCR: $rawOcrText');
    if (processedText != null) buf.writeln('Processed: $processedText');
    buf.writeln('');
    buf.writeln('--- LOGS ---');
    for (final log in logs) {
      buf.writeln(log);
    }
    buf.writeln('========================================');
    return buf.toString();
  }
}
