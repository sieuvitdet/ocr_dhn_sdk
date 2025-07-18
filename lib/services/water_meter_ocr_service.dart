import 'dart:io';
import 'dart:typed_data';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../models/water_meter_result.dart';
import 'package:image/image.dart' as img;

class WaterMeterOCRService {
  final TextRecognizer _textRecognizer;
  
  WaterMeterOCRService() : _textRecognizer = TextRecognizer();

  Future<WaterMeterResult> processImage(Uint8List imageBytes, {String? imageFull}) async {
    try {
      // Decode the image from bytes
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
      img.Image? annotatedImage;
      
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

      // Find the best result and get annotated image
      String bestReading = _selectBestFromMultipleResults(allResults);
      
      // Create annotated image with bounding boxes
      annotatedImage = await _createAnnotatedImage(image, imageBytes);
      
      // Get the best raw and processed text (from the approach that gave the best reading)
      String? bestRawText;
      String? bestProcessedText;
      if (bestReading.isNotEmpty) {
        // Find which approach gave us the best reading
        for (int i = 0; i < allResults.length; i++) {
          if (allResults[i] == bestReading) {
            // Get the corresponding raw and processed text
            var ocrResult = await _getOcrResult(image, imageBytes, ['original', 'high_contrast', 'threshold', 'center_crop'][i]);
            if (ocrResult != null) {
              bestRawText = ocrResult['raw'];
              bestProcessedText = ocrResult['processed'];
            }
            break;
          }
        }
      }
      
      return WaterMeterResult(
        reading: bestReading,
        confidence: _calculateConfidence(bestReading),
        imageBytes: annotatedImage != null ? Uint8List.fromList(img.encodeJpg(annotatedImage, quality: 95)) : null,
        debugInfo: allResults,
        rawOcrText: bestRawText,
        processedText: bestProcessedText,
      );
    } catch (e) {
      return WaterMeterResult(
        reading: '',
        confidence: 0.0,
        debugInfo: ['Error processing image: $e'],
      );
    }
  }
  
  Future<img.Image?> _createAnnotatedImage(img.Image originalImage, Uint8List imageBytes) async {
    try {
      // Create a copy of the original image to draw on
      var annotatedImage = img.Image.from(originalImage);
      
      // Process with OCR to get text blocks
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/temp_ocr.jpg';
      File(tempPath).writeAsBytesSync(imageBytes);
      
      final inputImage = InputImage.fromFilePath(tempPath);
      final recognizedText = await _textRecognizer.processImage(inputImage);
      
      // Draw blue bounding boxes around each text block
      for (TextBlock block in recognizedText.blocks) {
        final boundingBox = block.boundingBox;
        if (boundingBox != null) {
          // Draw blue rectangle around the text block
          _drawRectangle(
            annotatedImage,
            boundingBox.left.toInt(),
            boundingBox.top.toInt(),
            boundingBox.right.toInt(),
            boundingBox.bottom.toInt(),
            img.ColorRgb8(0, 0, 255), // Blue color
            3, // Line thickness
          );
          
          // Optionally draw text label above the box
          final text = block.text;
          if (text.isNotEmpty) {
            _drawText(
              annotatedImage,
              text,
              boundingBox.left.toInt(),
              (boundingBox.top - 20).clamp(0, annotatedImage.height - 1).toInt(),
              img.ColorRgb8(255, 0, 0), // Red text
            );
          }
        }
      }
      
      // Clean up temp file
      try {
        File(tempPath).deleteSync();
      } catch (e) {
        // Ignore cleanup errors
      }
      
      return annotatedImage;
    } catch (e) {
      print('Error creating annotated image: $e');
      return null;
    }
  }
  
  void _drawRectangle(img.Image image, int x1, int y1, int x2, int y2, img.Color color, int thickness) {
    // Draw horizontal lines
    for (int i = 0; i < thickness; i++) {
      for (int x = x1; x <= x2; x++) {
        if (x >= 0 && x < image.width && y1 + i >= 0 && y1 + i < image.height) {
          image.setPixel(x, y1 + i, color);
        }
        if (x >= 0 && x < image.width && y2 - i >= 0 && y2 - i < image.height) {
          image.setPixel(x, y2 - i, color);
        }
      }
    }
    
    // Draw vertical lines
    for (int i = 0; i < thickness; i++) {
      for (int y = y1; y <= y2; y++) {
        if (x1 + i >= 0 && x1 + i < image.width && y >= 0 && y < image.height) {
          image.setPixel(x1 + i, y, color);
        }
        if (x2 - i >= 0 && x2 - i < image.width && y >= 0 && y < image.height) {
          image.setPixel(x2 - i, y, color);
        }
      }
    }
  }
  
  void _drawText(img.Image image, String text, int x, int y, img.Color color) {
    // Simple text drawing - you might want to use a proper font library
    // For now, we'll just draw a small rectangle to represent text
    final textWidth = text.length * 8; // Approximate width
    final textHeight = 12; // Approximate height
    
    // Draw background rectangle for text
    for (int dx = 0; dx < textWidth; dx++) {
      for (int dy = 0; dy < textHeight; dy++) {
        final px = x + dx;
        final py = y + dy;
        if (px >= 0 && px < image.width && py >= 0 && py < image.height) {
          image.setPixel(px, py, img.ColorRgb8(255, 255, 255)); // White background
        }
      }
    }
    
    // Draw text outline (simplified)
    for (int dx = 0; dx < textWidth; dx++) {
      for (int dy = 0; dy < textHeight; dy++) {
        if (dx == 0 || dx == textWidth - 1 || dy == 0 || dy == textHeight - 1) {
          final px = x + dx;
          final py = y + dy;
          if (px >= 0 && px < image.width && py >= 0 && py < image.height) {
            image.setPixel(px, py, color);
          }
        }
      }
    }
  }
  
  Future<String> _processWithSettings(img.Image processedImage, Uint8List originalBytes, String suffix) async {
    try {
      // Save preprocessed image
      final tempDir = await getTemporaryDirectory();
      final preprocessedPath = '${tempDir.path}/preprocessed_$suffix.jpg';
      File(preprocessedPath).writeAsBytesSync(img.encodeJpg(processedImage, quality: 95));

      // Process with OCR
      final inputImage = InputImage.fromFilePath(preprocessedPath);
      final recognizedText = await _textRecognizer.processImage(inputImage);
      
      print('OCR Result for $suffix:\n${recognizedText.text}\n---');
      
      // Extract reading
      return _extractMeterReading(recognizedText.text);
    } catch (e) {
      print('Error in $suffix processing: $e');
      return '';
    }
  }
  
  Future<Map<String, String>?> _getOcrResult(img.Image image, Uint8List imageBytes, String suffix) async {
    try {
      img.Image processedImage;
      
      // Apply the same preprocessing as in _processWithSettings
      switch (suffix) {
        case 'original':
          processedImage = image;
          break;
        case 'high_contrast':
          processedImage = img.copyResize(image, width: 800, height: 600);
          processedImage = img.contrast(processedImage, contrast: 200);
          processedImage = img.adjustColor(processedImage, brightness: 1.3);
          break;
        case 'threshold':
          processedImage = img.grayscale(image);
          // Apply threshold
          for (int y = 0; y < processedImage.height; y++) {
            for (int x = 0; x < processedImage.width; x++) {
              var pixel = processedImage.getPixel(x, y);
              var r = pixel.r.toInt();
              var g = pixel.g.toInt(); 
              var b = pixel.b.toInt();
              var luminance = (0.299 * r + 0.587 * g + 0.114 * b).round();
              if (luminance > 128) {
                processedImage.setPixel(x, y, img.ColorRgb8(255, 255, 255));
              } else {
                processedImage.setPixel(x, y, img.ColorRgb8(0, 0, 0));
              }
            }
          }
          break;
        case 'center_crop':
          final centerX = image.width ~/ 2;
          final centerY = image.height ~/ 2;
          final cropSize = (image.width < image.height ? image.width : image.height) * 0.6 ~/ 1;
          processedImage = img.copyCrop(
            image,
            x: centerX - cropSize ~/ 2,
            y: centerY - cropSize ~/ 2,
            width: cropSize,
            height: cropSize,
          );
          processedImage = img.contrast(processedImage, contrast: 180);
          break;
        default:
          processedImage = image;
      }
      
      // Save and process
      final tempDir = await getTemporaryDirectory();
      final preprocessedPath = '${tempDir.path}/temp_$suffix.jpg';
      File(preprocessedPath).writeAsBytesSync(img.encodeJpg(processedImage, quality: 95));

      final inputImage = InputImage.fromFilePath(preprocessedPath);
      final recognizedText = await _textRecognizer.processImage(inputImage);
      
      // Clean up
      try {
        File(preprocessedPath).deleteSync();
      } catch (e) {
        // Ignore cleanup errors
      }
      
      return {
        'raw': recognizedText.text,
        'processed': _extractMeterReading(recognizedText.text),
      };
    } catch (e) {
      print('Error getting OCR result for $suffix: $e');
      return null;
    }
  }
  
  String _selectBestFromMultipleResults(List<String> results) {
  final validResults = results.where((r) => r.isNotEmpty).toList();
  if (validResults.isEmpty) return '';

  // Ưu tiên 5 số
  final RegExp fiveDigits = RegExp(r'^\d{5}$');
  final fiveDigitResults = validResults.where((r) => fiveDigits.hasMatch(r)).toList();
  if (fiveDigitResults.isNotEmpty) {
    return fiveDigitResults.first;
  }

  // Nếu không có, ưu tiên 4 số
  final RegExp fourDigits = RegExp(r'^\d{4}$');
  final fourDigitResults = validResults.where((r) => fourDigits.hasMatch(r)).toList();
  if (fourDigitResults.isNotEmpty) {
    return fourDigitResults.first;
  }

  // Nếu không có, dùng logic cũ
  if (validResults.length == 1) return validResults.first;

  Map<String, double> scores = {};
  for (final result in validResults) {
    double score = 0.0;
    if (result.length >= 6) {
      score += 50.0;
    } else if (result.length >= 4) {
      score += 30.0;
    } else if (result.length >= 3) {
      score += 10.0;
    }
    final numValue = int.tryParse(result) ?? 0;
    if (numValue > 0 && numValue <= 9999999) {
      score += 25.0;
    }
    if (!result.startsWith('20') && !result.contains('2024')) {
      score += 15.0;
    }
    scores[result] = score;
  }
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
    
    final lines = correctedText.split('\n');
    List<String> candidates = [];
    for (String line in lines) {
      final lineLower = line.toLowerCase();
      // Skip lines with letters unless they contain 'm3' or 'm³'
      if (RegExp(r'[a-zA-Z]').hasMatch(line) && !lineLower.contains('m3') && !lineLower.contains('m³')) {
        continue;
      }
      // Extract all numbers from this line
      final matches = RegExp(r'\d+').allMatches(line);
      for (final m in matches) {
        candidates.add(m.group(0)!);
      }
    }
    // Prioritize 5-digit, then 4-digit numbers
    final fiveDigits = candidates.where((c) => c.length == 5).toList();
    if (fiveDigits.isNotEmpty) return fiveDigits.first;
    final fourDigits = candidates.where((c) => c.length == 4).toList();
    if (fourDigits.isNotEmpty) return fourDigits.first;
    // If not found, return empty
    return '';
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