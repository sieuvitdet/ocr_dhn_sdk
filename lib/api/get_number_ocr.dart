import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

class OcrApiResult {
  final String text;
  final String rawText;
  final double score;
  const OcrApiResult({required this.text, this.rawText = '', required this.score});
}

class GetNumberOCR {
  final String apiUrl = 'https://ocr.meobeo.ai/ocr';

  /// Calls OCR API and returns the best reading (highest score) from results.
  /// [autoOrientation] sends auto_orientation field to let API auto-rotate image.
  Future<OcrApiResult?> ocrImage(File imageFile, {bool autoOrientation = true}) async {
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
      request.fields['auto_orientation'] = autoOrientation ? 'true' : 'false';

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

        debugPrint('[GetNumberOCR] best → raw: "$bestText", score: $bestScore');
        if (bestText.isEmpty) return null;

        final normalized = _extractMeterReading(bestText);
        debugPrint('[GetNumberOCR] normalized: "$normalized"');
        return OcrApiResult(
          text: normalized.isNotEmpty ? normalized : bestText,
          rawText: bestText,
          score: bestScore,
        );
      } else {
        debugPrint('[GetNumberOCR] non-200 response: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('[GetNumberOCR] exception: $e');
      return null;
    }
  }

  /// Correct common OCR character errors and extract digit reading.
  String _extractMeterReading(String text) {
    if (text.isEmpty) return '';

    String corrected = text
        // → 0
        .replaceAll('O', '0').replaceAll('o', '0').replaceAll('D', '0')
        .replaceAll('C', '0').replaceAll('c', '0').replaceAll('Q', '0')
        .replaceAll('U', '0').replaceAll('u', '0')
        .replaceAll('N', '0').replaceAll('n', '0')
        .replaceAll('V', '0').replaceAll('v', '0')
        .replaceAll('W', '0').replaceAll('w', '0')
        .replaceAll('M', '0').replaceAll('m', '0')
        // → 1
        .replaceAll('I', '1').replaceAll('l', '1').replaceAll('L', '1')
        .replaceAll('|', '1').replaceAll('J', '1').replaceAll('j', '1')
        .replaceAll('t', '1').replaceAll('f', '1').replaceAll('r', '1')
        .replaceAll('!', '1')
        // → 2
        .replaceAll('Z', '2').replaceAll('z', '2').replaceAll('R', '2')
        // → 3
        .replaceAll('E', '3').replaceAll('e', '3')
        // → 4
        .replaceAll('A', '4').replaceAll('a', '4').replaceAll('h', '4')
        .replaceAll('H', '4').replaceAll('K', '4').replaceAll('k', '4')
        // → 5
        .replaceAll('S', '5').replaceAll('s', '5')
        // → 6
        .replaceAll('G', '6').replaceAll('b', '6')
        // → 7
        .replaceAll('T', '7').replaceAll('F', '7')
        .replaceAll('Y', '7').replaceAll('y', '7')
        // → 8
        .replaceAll('B', '8').replaceAll('X', '8').replaceAll('x', '8')
        // → 9
        .replaceAll('P', '9').replaceAll('p', '9')
        .replaceAll('g', '9').replaceAll('q', '9');

    final lines = corrected.split('\n');
    final candidates = <String>[];

    for (final line in lines) {
      final digitsOnly = line.replaceAll(RegExp(r'[^0-9]'), '');
      if (digitsOnly.isEmpty) continue;

      final matches = RegExp(r'\d+').allMatches(line);
      for (final m in matches) {
        candidates.add(m.group(0)!);
      }

      if (digitsOnly.length >= 4 && digitsOnly.length <= 6) {
        candidates.add(digitsOnly);
      }
    }

    // Prioritize: 5-digit > 4-digit > 6-digit
    final fiveDigit = candidates.where((c) => c.length == 5).toList();
    if (fiveDigit.isNotEmpty) return fiveDigit.first;

    final fourDigit = candidates.where((c) => c.length == 4).toList();
    if (fourDigit.isNotEmpty) return fourDigit.first;

    final sixDigit = candidates.where((c) => c.length == 6).toList();
    if (sixDigit.isNotEmpty) return sixDigit.first;

    candidates.sort((a, b) => b.length.compareTo(a.length));
    for (final c in candidates) {
      if (c.length >= 3 && c.length <= 7) return c;
    }

    return '';
  }
}