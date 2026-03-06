import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

class OcrApiResult {
  final String text;
  final double score;
  const OcrApiResult({required this.text, required this.score});
}

class GetNumberOCR {
  final String apiUrl = 'https://ocr.meobeo.ai/ocr';

  /// Calls OCR API and returns the best reading (highest score) from results.
  Future<OcrApiResult?> ocrImage(File imageFile) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse(apiUrl));
      final ext = imageFile.path.split('.').last.toLowerCase();
      final mimeSubtype = ext == 'png' ? 'png' : 'jpeg';
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          imageFile.path,
          contentType: MediaType('image', mimeSubtype),
        ),
      );

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      debugPrint('[GetNumberOCR] status: ${response.statusCode}');
      debugPrint('[GetNumberOCR] body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final resultList = data['result'] as List<dynamic>?;
        if (resultList == null || resultList.isEmpty) {
          debugPrint('[GetNumberOCR] result list is null or empty');
          return null;
        }

        // Collect all (text, score) pairs across result entries
        String bestText = '';
        double bestScore = -1;

        for (final entry in resultList) {
          final texts = (entry['rec_texts'] as List<dynamic>?) ?? [];
          final scores = (entry['rec_scores'] as List<dynamic>?) ?? [];
          debugPrint('[GetNumberOCR] rec_texts: $texts | rec_scores: $scores');

          for (int i = 0; i < texts.length; i++) {
            final score = i < scores.length ? (scores[i] as num).toDouble() : 0.0;
            if (score > bestScore) {
              bestScore = score;
              bestText = texts[i] as String;
            }
          }
        }

        debugPrint('[GetNumberOCR] best → text: "$bestText", score: $bestScore');
        if (bestText.isEmpty) return null;
        return OcrApiResult(text: bestText, score: bestScore);
      } else {
        debugPrint('[GetNumberOCR] non-200 response: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[GetNumberOCR] exception: $e');
      return null;
    }
  }
}