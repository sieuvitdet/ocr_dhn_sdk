import 'package:flutter/foundation.dart';

@immutable
class WaterMeterResult {
  final String reading;
  final double confidence;
  final Uint8List? imageBytes;
  final List<String>? debugInfo;

  const WaterMeterResult({
    required this.reading,
    required this.confidence,
    this.imageBytes,
    this.debugInfo,
  });

  factory WaterMeterResult.empty() {
    return const WaterMeterResult(
      reading: '',
      confidence: 0.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'reading': reading,
      'confidence': confidence,
      'imageBytes': imageBytes,
      'debugInfo': debugInfo,
    };
  }

  factory WaterMeterResult.fromJson(Map<String, dynamic> json) {
    return WaterMeterResult(
      reading: json['reading'] as String,
      confidence: json['confidence'] as double,
      imageBytes: json['imageBytes'] as Uint8List?,
      debugInfo: (json['debugInfo'] as List?)?.cast<String>(),
    );
  }

  @override
  String toString() {
    return 'WaterMeterResult(reading: $reading, confidence: $confidence, imageBytes: $imageBytes)';
  }
} 