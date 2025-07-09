import 'package:flutter/foundation.dart';

@immutable
class WaterMeterResult {
  final String reading;
  final double confidence;
  final String? imagePath;
  final List<String>? debugInfo;

  const WaterMeterResult({
    required this.reading,
    required this.confidence,
    this.imagePath,
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
      'imagePath': imagePath,
      'debugInfo': debugInfo,
    };
  }

  factory WaterMeterResult.fromJson(Map<String, dynamic> json) {
    return WaterMeterResult(
      reading: json['reading'] as String,
      confidence: json['confidence'] as double,
      imagePath: json['imagePath'] as String?,
      debugInfo: (json['debugInfo'] as List?)?.cast<String>(),
    );
  }

  @override
  String toString() {
    return 'WaterMeterResult(reading: $reading, confidence: $confidence, imagePath: $imagePath)';
  }
} 