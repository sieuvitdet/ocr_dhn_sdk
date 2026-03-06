import 'package:flutter/foundation.dart';
import 'package:water_meter_sdk/services/paddle_ocr_service.dart';

@immutable
class WaterMeterResult {
  final String reading;
  final double confidence;
  final Uint8List? imageBytes;
  final List<String>? debugInfo;
  final String? rawOcrText;
  final String? processedText;

  /// All OCR candidates from beam search, sorted by confidence (descending).
  /// The first candidate matches [reading]. Empty when using ML Kit engine.
  final List<OcrCandidate> candidates;

  const WaterMeterResult({
    required this.reading,
    required this.confidence,
    this.imageBytes,
    this.debugInfo,
    this.rawOcrText,
    this.processedText,
    this.candidates = const [],
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
      'rawOcrText': rawOcrText,
      'processedText': processedText,
      'candidates': candidates.map((c) => {'text': c.text, 'confidence': c.confidence}).toList(),
    };
  }

  factory WaterMeterResult.fromJson(Map<String, dynamic> json) {
    final rawCandidates = json['candidates'] as List?;
    return WaterMeterResult(
      reading: json['reading'] as String,
      confidence: json['confidence'] as double,
      imageBytes: json['imageBytes'] as Uint8List?,
      debugInfo: (json['debugInfo'] as List?)?.cast<String>(),
      rawOcrText: json['rawOcrText'] as String?,
      processedText: json['processedText'] as String?,
      candidates: rawCandidates
          ?.map((c) => OcrCandidate(c['text'] as String, (c['confidence'] as num).toDouble()))
          .toList() ?? [],
    );
  }

  @override
  String toString() {
    return 'WaterMeterResult(reading: $reading, confidence: $confidence, candidates: ${candidates.length}, rawOcrText: $rawOcrText)';
  }
} 