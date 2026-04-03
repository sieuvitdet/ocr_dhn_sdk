import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../models/water_meter_result.dart';
import 'package:image/image.dart' as img;

class WaterMeterOCRService {
  final TextRecognizer _textRecognizer;

  WaterMeterOCRService() : _textRecognizer = TextRecognizer();

  /// Main entry point: preprocess image then run OCR.
  /// [imageBytes] is the cropped water meter region.
  Future<WaterMeterResult> processImage(Uint8List imageBytes) async {
    try {
      // Decode with EXIF orientation applied
      var image = img.decodeImage(imageBytes);
      if (image == null) {
        return WaterMeterResult(
          reading: '',
          confidence: 0.0,
          debugInfo: ['Failed to decode image'],
        );
      }

      // Apply EXIF orientation to avoid rotation/mirror issues
      image = img.bakeOrientation(image);

      final debugInfo = <String>[];
      debugInfo.add('Original size: ${image.width}x${image.height}');

      // --- Preprocessing pipeline ---
      final preprocessed = _preprocessForOCR(image, debugInfo);

      // Run OCR on preprocessed image
      final ocrResult = await _runOCR(preprocessed, debugInfo);
      final rawText = ocrResult['raw'] ?? '';
      final reading = _extractMeterReading(rawText);

      debugInfo.add('Raw OCR: $rawText');
      debugInfo.add('Extracted reading: $reading');

      // Create annotated image for debugging
      final annotated = await _createAnnotatedImage(image, imageBytes);

      return WaterMeterResult(
        reading: reading,
        confidence: _calculateConfidence(reading),
        imageBytes: annotated != null
            ? Uint8List.fromList(img.encodeJpg(annotated, quality: 95))
            : null,
        debugInfo: debugInfo,
        rawOcrText: rawText,
        processedText: reading,
      );
    } catch (e) {
      return WaterMeterResult(
        reading: '',
        confidence: 0.0,
        debugInfo: ['Error processing image: $e'],
      );
    }
  }

  /// Full preprocessing pipeline optimized for water meter digits.
  /// Water meters have white/light digits on dark rotating drums.
  img.Image _preprocessForOCR(img.Image source, List<String> debugInfo) {
    var result = img.Image.from(source);

    // 1. Upscale small images — ML Kit needs ~24px per character minimum.
    //    For 5 digits we want at least 800px width.
    const minWidth = 800;
    if (result.width < minWidth) {
      final scale = minWidth / result.width;
      result = img.copyResize(
        result,
        width: minWidth,
        height: (result.height * scale).round(),
        interpolation: img.Interpolation.cubic,
      );
      debugInfo.add('Upscaled to ${result.width}x${result.height}');
    }

    // 2. Convert to grayscale
    result = img.grayscale(result);
    debugInfo.add('Converted to grayscale');

    // 3. Invert: water meter has white digits on dark background.
    //    OCR engines expect dark text on light background.
    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final pixel = result.getPixel(x, y);
        final inverted = 255 - pixel.r.toInt();
        result.setPixel(x, y, img.ColorRgb8(inverted, inverted, inverted));
      }
    }
    debugInfo.add('Inverted (white-on-black → black-on-white)');

    // 4. Otsu binarization for clean black/white separation
    final threshold = _otsuThreshold(result);
    debugInfo.add('Otsu threshold: $threshold');
    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final lum = result.getPixel(x, y).r.toInt();
        final bw = lum > threshold ? 255 : 0;
        result.setPixel(x, y, img.ColorRgb8(bw, bw, bw));
      }
    }
    debugInfo.add('Applied Otsu binarization');

    // 5. Light morphological closing to fill small gaps in digits
    result = _morphClose(result, radius: 1);
    debugInfo.add('Applied morphological closing');

    // 6. Add white border padding — OCR works better when text doesn't touch edges
    const padding = 20;
    final padded = img.Image(
      width: result.width + padding * 2,
      height: result.height + padding * 2,
    );
    // Fill with white
    for (int y = 0; y < padded.height; y++) {
      for (int x = 0; x < padded.width; x++) {
        padded.setPixel(x, y, img.ColorRgb8(255, 255, 255));
      }
    }
    // Copy result into center
    img.compositeImage(padded, result, dstX: padding, dstY: padding);
    debugInfo.add('Added ${padding}px white border');

    return padded;
  }

  /// Compute Otsu's threshold from a grayscale image.
  int _otsuThreshold(img.Image gray) {
    // Build histogram
    final hist = List<int>.filled(256, 0);
    final total = gray.width * gray.height;
    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        hist[gray.getPixel(x, y).r.toInt()]++;
      }
    }

    double sumAll = 0;
    for (int i = 0; i < 256; i++) {
      sumAll += i * hist[i];
    }

    double sumB = 0;
    int wB = 0;
    double maxVariance = 0;
    int bestThreshold = 0;

    for (int t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;

      sumB += t * hist[t];
      final meanB = sumB / wB;
      final meanF = (sumAll - sumB) / wF;
      final variance = wB.toDouble() * wF.toDouble() * (meanB - meanF) * (meanB - meanF);

      if (variance > maxVariance) {
        maxVariance = variance;
        bestThreshold = t;
      }
    }
    return bestThreshold;
  }

  /// Simple morphological close (dilate then erode) with a square kernel.
  img.Image _morphClose(img.Image src, {int radius = 1}) {
    // Dilate: for each pixel, take the max in the neighborhood
    final dilated = img.Image.from(src);
    for (int y = radius; y < src.height - radius; y++) {
      for (int x = radius; x < src.width - radius; x++) {
        int maxVal = 0;
        for (int dy = -radius; dy <= radius; dy++) {
          for (int dx = -radius; dx <= radius; dx++) {
            maxVal = math.max(maxVal, src.getPixel(x + dx, y + dy).r.toInt());
          }
        }
        dilated.setPixel(x, y, img.ColorRgb8(maxVal, maxVal, maxVal));
      }
    }

    // Erode: for each pixel, take the min in the neighborhood
    final eroded = img.Image.from(dilated);
    for (int y = radius; y < dilated.height - radius; y++) {
      for (int x = radius; x < dilated.width - radius; x++) {
        int minVal = 255;
        for (int dy = -radius; dy <= radius; dy++) {
          for (int dx = -radius; dx <= radius; dx++) {
            minVal = math.min(minVal, dilated.getPixel(x + dx, y + dy).r.toInt());
          }
        }
        eroded.setPixel(x, y, img.ColorRgb8(minVal, minVal, minVal));
      }
    }

    return eroded;
  }

  /// Run Google ML Kit text recognition on a preprocessed image.
  Future<Map<String, String>> _runOCR(img.Image image, List<String> debugInfo) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/ocr_preprocessed.jpg';
      File(tempPath).writeAsBytesSync(img.encodeJpg(image, quality: 95));

      final inputImage = InputImage.fromFilePath(tempPath);
      final recognizedText = await _textRecognizer.processImage(inputImage);

      // Cleanup
      try { File(tempPath).deleteSync(); } catch (_) {}

      debugInfo.add('ML Kit raw text: ${recognizedText.text}');
      return {
        'raw': recognizedText.text,
      };
    } catch (e) {
      debugInfo.add('OCR error: $e');
      return {'raw': ''};
    }
  }

  /// Extract 4-5 digit meter reading from raw OCR text.
  String _extractMeterReading(String text) {
    if (text.isEmpty) return '';

    // Correct common OCR errors for digits
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
      // Skip lines with too many non-digit characters (likely not the meter)
      final digitsOnly = line.replaceAll(RegExp(r'[^0-9]'), '');
      if (digitsOnly.isEmpty) continue;

      // Extract contiguous digit sequences
      final matches = RegExp(r'\d+').allMatches(line);
      for (final m in matches) {
        candidates.add(m.group(0)!);
      }

      // Also try the full digits-only version of the line
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

    // Fallback: longest numeric string that looks like a reading
    candidates.sort((a, b) => b.length.compareTo(a.length));
    for (final c in candidates) {
      if (c.length >= 3 && c.length <= 7) return c;
    }

    return '';
  }

  double _calculateConfidence(String reading) {
    if (reading.isEmpty) return 0.0;
    if (reading.length == 5) return 0.85;
    if (reading.length == 4) return 0.7;
    if (reading.length == 6) return 0.6;
    return 0.3;
  }

  Future<img.Image?> _createAnnotatedImage(img.Image originalImage, Uint8List imageBytes) async {
    try {
      var annotatedImage = img.Image.from(originalImage);

      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/temp_ocr_annotate.jpg';
      File(tempPath).writeAsBytesSync(imageBytes);

      final inputImage = InputImage.fromFilePath(tempPath);
      final recognizedText = await _textRecognizer.processImage(inputImage);

      for (TextBlock block in recognizedText.blocks) {
        final boundingBox = block.boundingBox;
        _drawRectangle(
          annotatedImage,
          boundingBox.left.toInt(),
          boundingBox.top.toInt(),
          boundingBox.right.toInt(),
          boundingBox.bottom.toInt(),
          img.ColorRgb8(0, 0, 255),
          3,
        );
      }

      try { File(tempPath).deleteSync(); } catch (_) {}
      return annotatedImage;
    } catch (e) {
      return null;
    }
  }

  void _drawRectangle(img.Image image, int x1, int y1, int x2, int y2, img.Color color, int thickness) {
    for (int i = 0; i < thickness; i++) {
      for (int x = x1; x <= x2; x++) {
        if (x >= 0 && x < image.width) {
          if (y1 + i >= 0 && y1 + i < image.height) image.setPixel(x, y1 + i, color);
          if (y2 - i >= 0 && y2 - i < image.height) image.setPixel(x, y2 - i, color);
        }
      }
      for (int y = y1; y <= y2; y++) {
        if (y >= 0 && y < image.height) {
          if (x1 + i >= 0 && x1 + i < image.width) image.setPixel(x1 + i, y, color);
          if (x2 - i >= 0 && x2 - i < image.width) image.setPixel(x2 - i, y, color);
        }
      }
    }
  }

  Future<void> dispose() async {
    await _textRecognizer.close();
  }
}
