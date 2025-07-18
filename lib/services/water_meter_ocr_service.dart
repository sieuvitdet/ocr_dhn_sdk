import 'dart:io';
import 'dart:typed_data';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../models/water_meter_result.dart';
import 'package:image/image.dart' as img;

class WaterMeterOCRService {
  final TextRecognizer _textRecognizer;
  
  WaterMeterOCRService() : _textRecognizer = TextRecognizer();

  Future<WaterMeterResult> processImage(Uint8List imageBytes,{String? imageFull} ) async {
    try {
      // Read and preprocess the image
      var image = img.decodeImage(imageBytes);
      
      if (image == null) {
        return WaterMeterResult(
          reading: '',
          confidence: 0.0,
          debugInfo: ['Failed to decode image'],
        );
      }

      // Try multiple preprocessing approaches
      List<String> allResults = [];
      
      // Approach 1: Original image
      var result1 = await _processWithSettings(image, imageBytes, 'original');
      allResults.add(result1);
      
      // Approach 2: High contrast + crop center
      var image2 = img.copyResize(image, width: 800, height: 600);
      image2 = img.contrast(image2, contrast: 200);
      image2 = img.adjustColor(image2, brightness: 1.3);
      var result2 = await _processWithSettings(image2, imageBytes, 'high_contrast');
      allResults.add(result2);
      
      // Approach 3: Grayscale + threshold
      var image3 = img.grayscale(image);
      // Apply threshold to make text more distinct
      for (int y = 0; y < image3.height; y++) {
        for (int x = 0; x < image3.width; x++) {
          var pixel = image3.getPixel(x, y);
          var r = pixel.r.toInt();
          var g = pixel.g.toInt(); 
          var b = pixel.b.toInt();
          var luminance = (0.299 * r + 0.587 * g + 0.114 * b).round();
          if (luminance > 128) {
            image3.setPixel(x, y, img.ColorRgb8(255, 255, 255)); // White
          } else {
            image3.setPixel(x, y, img.ColorRgb8(0, 0, 0)); // Black
          }
        }
      }
      var result3 = await _processWithSettings(image3, imageBytes, 'threshold');
      allResults.add(result3);
      
      // Approach 4: Focus on center area only
      final centerX = image.width ~/ 2;
      final centerY = image.height ~/ 2;
      final cropSize = (image.width < image.height ? image.width : image.height) * 0.6 ~/ 1;
      
      var image4 = img.copyCrop(
        image,
        x: centerX - cropSize ~/ 2,
        y: centerY - cropSize ~/ 2,
        width: cropSize,
        height: cropSize,
      );
      image4 = img.contrast(image4, contrast: 180);
      var result4 = await _processWithSettings(image4, imageBytes, 'center_crop');
      allResults.add(result4);

      // Find the best result
      String bestReading = _selectBestFromMultipleResults(allResults);
      
      return WaterMeterResult(
        reading: bestReading,
        confidence: _calculateConfidence(bestReading),
        imageBytes: imageBytes,
        debugInfo: allResults,
      );
    } catch (e) {
      return WaterMeterResult(
        reading: '',
        confidence: 0.0,
        debugInfo: ['Error processing image: $e'],
      );
    }
  }
  
  Future<String> _processWithSettings(img.Image processedImage, Uint8List originalBytes, String suffix) async {
    try {
      // Save preprocessed image
      final tempDir = await getTemporaryDirectory();
      final preprocessedPath = '${tempDir.path}/preprocessed_$suffix.jpg';
      File(preprocessedPath).writeAsBytesSync(originalBytes);

      // Process with OCR
      final inputImage = InputImage.fromFilePath(preprocessedPath);
      final recognizedText = await _textRecognizer.processImage(inputImage);
      
      // Extract reading
      return _extractMeterReading(recognizedText.text);
    } catch (e) {
      return '';
    }
  }
  
  String _selectBestFromMultipleResults(List<String> results) {
    // Remove empty results
    final validResults = results.where((r) => r.isNotEmpty).toList();
    
    if (validResults.isEmpty) return '';
    if (validResults.length == 1) return validResults.first;
    
    // Score each result
    Map<String, double> scores = {};
    
    for (final result in validResults) {
      double score = 0.0;
      
      // Prefer longer readings (more complete OCR)
      if (result.length >= 6) {
        score += 50.0;
      } else if (result.length >= 4) {
        score += 30.0;
      } else if (result.length >= 3) {
        score += 10.0;
      }
      
      // Prefer readings with reasonable values
      final numValue = int.tryParse(result) ?? 0;
      if (numValue > 0 && numValue <= 9999999) {
        score += 25.0;
      }
      
      // Prefer readings that don't look like years or model numbers
      if (!result.startsWith('20') && !result.contains('2024')) {
        score += 15.0;
      }
      
      scores[result] = score;
    }
    
    // Return the highest scoring result
    final sortedEntries = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    print('Multiple OCR results scores: $scores');
    return sortedEntries.first.key;
  }

  String _extractMeterReading(String text) {
    if (text.isEmpty) return '';
    
    // Print raw OCR for debugging
    print('RAW OCR TEXT:\n$text\n');
    
    // Correct common OCR errors
    String correctedText = text
        .replaceAll('O', '0')
        .replaceAll('o', '0')
        .replaceAll('D', '0')
        .replaceAll('I', '1')
        .replaceAll('l', '1')
        .replaceAll('S', '5')
        .replaceAll('s', '5')
        .replaceAll('Z', '2')
        .replaceAll('B', '8');
    
    // Find all numbers in the corrected text
    final RegExp numberPattern = RegExp(r'\d+');
    final matches = numberPattern.allMatches(correctedText);
    
    if (matches.isEmpty) return '';
    
    List<String> candidates = matches.map((m) => m.group(0)!).toList();
    print('Found number candidates: $candidates');
    
    // Score each candidate
    Map<String, double> candidateScores = {};
    
    for (String candidate in candidates) {
      double score = 0.0;
      
      // **1. Length scoring - Vietnamese water meters typically 4-7 digits**
      if (candidate.length == 6 || candidate.length == 7) {
        score += 100.0; // Excellent for ELSTER type (0002541)
      } else if (candidate.length == 5) {
        score += 80.0;  // Good
      } else if (candidate.length == 4) {
        score += 60.0;  // Decent
      } else if (candidate.length == 3) {
        score += 20.0;  // Poor but possible
      } else if (candidate.length >= 8) {
        score -= 30.0;  // Too long, likely serial number
      }
      
      // **2. Position scoring - look for numbers near "m³"**
      final candidateIndex = correctedText.indexOf(candidate);
      final textAround = correctedText.substring(
        (candidateIndex - 20).clamp(0, correctedText.length),
        (candidateIndex + candidate.length + 20).clamp(0, correctedText.length)
      ).toLowerCase();
      
      if (textAround.contains('m³') || textAround.contains('m3')) {
        score += 50.0;
      }
      
      // **3. Check if it's in a box/frame context**
      if (textAround.contains('□') || textAround.contains('■') || 
          textAround.contains('[') || textAround.contains(']')) {
        score += 40.0; // Numbers in boxes are likely readings
      }
      
      // **4. Avoid serial numbers and model numbers**
      if (candidate.contains('-') || candidate.contains('.')) {
        score -= 80.0;
      }
      
      // Check if surrounded by letters (model numbers)
      final beforeChar = candidateIndex > 0 ? correctedText[candidateIndex - 1] : ' ';
      final afterChar = candidateIndex + candidate.length < correctedText.length 
          ? correctedText[candidateIndex + candidate.length] : ' ';
      
      if (RegExp(r'[a-zA-Z]').hasMatch(beforeChar) || RegExp(r'[a-zA-Z]').hasMatch(afterChar)) {
        score -= 30.0; // Likely part of model number
      }
      
      // **5. Technical specifications detection**
      final technicalPatterns = ['mm', 'bar', 'pn', 'dn', 'kg', 'mpa', 'cert', 'no'];
      for (String pattern in technicalPatterns) {
        if (textAround.contains(pattern)) {
          score -= 40.0;
          break;
        }
      }
      
      // **6. Year detection**
      final numValue = int.tryParse(candidate) ?? 0;
      if (numValue >= 2000 && numValue <= 2030) {
        score -= 60.0; // Likely a year
      }
      
      // **7. Brand/manufacturer detection**
      final brandPatterns = ['elster', 'asahi', 'sanwa', 'itron', 'sensus'];
      for (String brand in brandPatterns) {
        if (textAround.contains(brand)) {
          // If near brand name, could be reading - slight bonus
          score += 10.0;
          break;
        }
      }
      
      // **8. Reasonable value range**
      if (numValue > 0 && numValue <= 9999999) {
        score += 15.0;
      } else if (numValue == 0 && candidate.length > 3) {
        score += 5.0; // Could be initial reading like 0002541
      }
      
      // **9. Isolated number bonus**
      final lines = correctedText.split('\n');
      for (String line in lines) {
        if (line.trim() == candidate) {
          score += 30.0; // Number on its own line
          break;
        }
      }
      
      // **10. Check for leading zeros pattern (common in meters)**
      if (candidate.startsWith('000') && candidate.length >= 6) {
        score += 35.0; // Like 0002541
      }
      
      candidateScores[candidate] = score;
      print('Candidate: $candidate, Score: $score');
    }
    
    if (candidateScores.isEmpty) return '';
    
    // Sort by score and return the best candidate
    final sortedCandidates = candidateScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    final bestCandidate = sortedCandidates.first;
    print('Best candidate: ${bestCandidate.key} with score: ${bestCandidate.value}');
    
    return bestCandidate.key;
  }

  double _calculateConfidence(String reading) {
    if (reading.isEmpty) return 0.0;
    
    // Higher confidence for readings starting with zeros
    if (reading.startsWith('000')) {
      return 0.9;
    }
    
    // Basic confidence calculation
    if (reading.length >= 5 && reading.length <= 7) {
      return 0.7;
    }
    
    return 0.3;
  }

  Future<void> dispose() async {
    await _textRecognizer.close();
  }
} 