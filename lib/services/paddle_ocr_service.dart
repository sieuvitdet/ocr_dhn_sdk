import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

/// A single OCR candidate from beam search decoding.
class OcrCandidate {
  final String text;
  final double confidence;

  const OcrCandidate(this.text, this.confidence);

  @override
  String toString() => '"$text" (${(confidence * 100).toStringAsFixed(1)}%)';
}

/// PaddleOCR v4 text recognition using ONNX Runtime.
///
/// Key implementation details matching the official PaddleOCR Python pipeline:
/// - Input channel order: **BGR** (not RGB) — model trained with OpenCV BGR
/// - Input shape: [1, 3, 48, W] where W <= imgW (default 320)
/// - Normalization: (pixel/255 - 0.5) / 0.5
/// - Padding: 0.0 (not normalized black) — model expects zero-padding
/// - Output: CTC beam search decode on [1, T, numClasses] logits
class PaddleOCRService {
  static const int _recHeight = 48;
  static const int _maxRecWidth = 320;

  /// Beam width for CTC beam search. Higher = more candidates, slower.
  static const int beamWidth = 6;

  final OnnxRuntime _ort = OnnxRuntime();
  OrtSession? _session;
  List<String> _charset = [];
  bool _initialized = false;

  bool get isInitialized => _initialized;

  Future<void> init({
    String modelAsset = 'packages/water_meter_sdk/assets/paddle_ocr_models/ppocrv5_mobile_rec.onnx',
    String dictAsset = 'packages/water_meter_sdk/assets/paddle_ocr_models/ppocrv5_dict.txt',
  }) async {
    if (_initialized) return;

    final options = OrtSessionOptions(
      intraOpNumThreads: 2,
      interOpNumThreads: 1,
      providers: [OrtProvider.CPU],
    );
    _session = await _ort.createSessionFromAsset(modelAsset, options: options);

    // Build charset: index 0 = CTC blank, then dict chars, then end token
    final dictString = await rootBundle.loadString(dictAsset);
    _charset = [''];  // Index 0 = CTC blank
    _charset.addAll(dictString.split('\n').where((s) => s.isNotEmpty));
    _charset.add(' '); // End token

    _initialized = true;
  }

  /// Run ONNX inference and return raw CTC output data.
  Future<(List<dynamic> flatData, int timeSteps, int numClasses, bool transposed)?> _runInference(Uint8List imageBytes) async {
    if (!_initialized || _session == null) {
      throw StateError('PaddleOCRService not initialized. Call init() first.');
    }

    final preprocessed = _preprocessImage(imageBytes);
    if (preprocessed == null) return null;

    final (Float32List inputData, int width) = preprocessed;

    final inputTensor = await OrtValue.fromList(
      inputData,
      [1, 3, _recHeight, width],
    );

    final outputs = await _session!.run({'x': inputTensor});

    final outputTensor = outputs.values.first;
    final shape = outputTensor.shape;
    final flatData = await outputTensor.asFlattenedList();

    await inputTensor.dispose();
    for (final t in outputs.values) { await t.dispose(); }

    if (shape.length != 3) return null;

    // Determine layout: [1, T, C] vs [1, C, T]
    int timeSteps;
    int numClasses;
    bool transposed = false;

    if (shape[2] == _charset.length || (shape[2] > shape[1] && shape[2] > 20)) {
      timeSteps = shape[1];
      numClasses = shape[2];
    } else {
      timeSteps = shape[2];
      numClasses = shape[1];
      transposed = true;
    }

    return (flatData, timeSteps, numClasses, transposed);
  }

  /// Recognize full text (all character classes) — greedy decode.
  Future<(String, double)> recognize(Uint8List imageBytes) async {
    final inference = await _runInference(imageBytes);
    if (inference == null) return ('', 0.0);
    final (flatData, timeSteps, numClasses, transposed) = inference;
    return _ctcGreedyDecode(flatData, timeSteps, numClasses, transposed);
  }

  /// Recognize digits only using beam search. Returns top candidate.
  Future<(String, double)> recognizeDigitsOnly(Uint8List imageBytes) async {
    final candidates = await recognizeDigitsTopK(imageBytes);
    if (candidates.isEmpty) return ('', 0.0);
    return (candidates.first.text, candidates.first.confidence);
  }

  /// Recognize digits only using beam search. Returns top-K candidates.
  Future<List<OcrCandidate>> recognizeDigitsTopK(Uint8List imageBytes) async {
    final inference = await _runInference(imageBytes);
    if (inference == null) return [];
    final (flatData, timeSteps, numClasses, transposed) = inference;

    final digitIndices = _buildDigitIndices();

    return _ctcBeamSearchDecode(
      flatData, timeSteps, numClasses, transposed,
      allowedIndices: digitIndices,
      beamWidth: beamWidth,
    );
  }

  /// Recognize water meter reading with top-K candidates.
  Future<List<OcrCandidate>> recognizeWaterMeterTopK(Uint8List imageBytes) async {
    final candidates = await recognizeDigitsTopK(imageBytes);
    // Filter: keep candidates with 3-7 digit length (typical meter format)
    return candidates
        .map((c) => OcrCandidate(c.text.trim(), c.confidence))
        .where((c) => c.text.isNotEmpty && c.text.length >= 3 && c.text.length <= 7)
        .toList();
  }

  /// Recognize water meter reading: returns best candidate.
  Future<(String, double)> recognizeWaterMeter(Uint8List imageBytes) async {
    final candidates = await recognizeWaterMeterTopK(imageBytes);
    if (candidates.isEmpty) {
      // Fallback to raw digits-only
      return await recognizeDigitsOnly(imageBytes);
    }
    return (candidates.first.text, candidates.first.confidence);
  }

  /// Try multiple orientations and return the best water meter reading.
  /// Handles vertical digit images (e.g., EXIF-rotated photos with 90° tilt).
  Future<({String rawText, List<OcrCandidate> candidates, String orientation})>
      recognizeMultiOrientation(Uint8List imageBytes) async {
    // Primary attempt
    final (rawText, _) = await recognize(imageBytes);
    final candidates = await recognizeWaterMeterTopK(imageBytes);

    // Check if image is portrait (digits might be vertical)
    final decoded = _decodeAndBake(imageBytes);
    final isPortrait =
        decoded != null && decoded.height > decoded.width * 1.3;

    // Return early if result is good AND image is landscape
    if (_isGoodResult(candidates) && !isPortrait) {
      return (
        rawText: rawText,
        candidates: candidates,
        orientation: 'original',
      );
    }

    if (decoded == null) {
      return (
        rawText: rawText,
        candidates: candidates,
        orientation: 'original',
      );
    }

    var bestRaw = rawText;
    var bestCandidates = candidates;
    var bestOrientation = 'original';
    var bestScore = _scoreCandidates(candidates);

    // Try 90° and 270° rotations
    for (final angle in [90, 270]) {
      final rotated = img.copyRotate(decoded, angle: angle);
      final bytes = Uint8List.fromList(
        img.encodeJpg(rotated, quality: 95),
      );
      final (rt, _) = await recognize(bytes);
      final cands = await recognizeWaterMeterTopK(bytes);
      final score = _scoreCandidates(cands);

      if (score > bestScore) {
        bestScore = score;
        bestRaw = rt;
        bestCandidates = cands;
        bestOrientation = '$angle°';
      }
    }

    return (
      rawText: bestRaw,
      candidates: bestCandidates,
      orientation: bestOrientation,
    );
  }

  img.Image? _decodeAndBake(Uint8List imageBytes) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) return null;
    return img.bakeOrientation(decoded);
  }

  bool _isGoodResult(List<OcrCandidate> candidates) {
    if (candidates.isEmpty) return false;
    final best = candidates.first;
    return best.text.length >= 3 &&
        best.text.length <= 6 &&
        best.confidence > 0.75;
  }

  double _scoreCandidates(List<OcrCandidate> candidates) {
    if (candidates.isEmpty) return 0.0;
    final best = candidates.first;
    double score = best.confidence;
    // Strongly prefer 4-5 digit readings (typical water meter)
    if (best.text.length == 4 || best.text.length == 5) {
      score += 0.4;
    } else if (best.text.length == 3 || best.text.length == 6) {
      score += 0.15;
    }
    return score;
  }

  /// Map common OCR letter→digit confusions in raw text.
  /// Best-effort correction for debugging display.
  static String correctRawText(String text) {
    if (text.isEmpty) return text;
    return text
        .replaceAll('O', '0').replaceAll('o', '0')
        .replaceAll('D', '0')
        .replaceAll('I', '1').replaceAll('l', '1').replaceAll('|', '1')
        .replaceAll('S', '5').replaceAll('s', '5')
        .replaceAll('Z', '2').replaceAll('z', '2')
        .replaceAll('B', '8').replaceAll('b', '6')
        .replaceAll('G', '6').replaceAll('g', '9')
        .replaceAll('T', '7')
        .replaceAll('q', '9')
        .replaceAll('C', '0').replaceAll('c', '0')
        .replaceAll('E', '8').replaceAll('e', '8')
        .replaceAll('U', '0').replaceAll('u', '0')
        .replaceAll(RegExp(r'[^0-9]'), '');
  }

  /// Build set of allowed digit class indices in the charset.
  Set<int> _buildDigitIndices() {
    final digitIndices = <int>{0}; // Always include blank (0)
    for (int i = 1; i < _charset.length; i++) {
      if (_charset[i].length == 1 && '0123456789'.contains(_charset[i])) {
        digitIndices.add(i);
      }
    }
    return digitIndices;
  }

  /// Preprocess image with enhancement for water meter digits, then
  /// build the PaddleOCR-compatible tensor.
  ///
  /// Pipeline:
  /// 1. Decode with EXIF orientation
  /// 2. Enhance contrast (CLAHE-like adaptive)
  /// 3. Resize to height=48, proportional width (capped)
  /// 4. BGR channel order, normalize, zero-pad
  (Float32List, int)? _preprocessImage(Uint8List imageBytes) {
    var decoded = img.decodeImage(imageBytes);
    if (decoded == null) return null;
    decoded = img.bakeOrientation(decoded);

    // --- Enhancement for water meter digits ---
    // decoded = _enhanceForOcr(decoded);
    // decoded = _sharpenImage(decoded);

    // Calculate target width (proportional, capped)
    final double ratio = decoded.width / decoded.height;
    int resizedW = (ratio * _recHeight).ceil();
    if (resizedW > _maxRecWidth) resizedW = _maxRecWidth;
    if (resizedW < 10) resizedW = 10;

    final int imgW = math.max(resizedW, _maxRecWidth);

    final resized = img.copyResize(
      decoded,
      width: resizedW,
      height: _recHeight,
      interpolation: img.Interpolation.cubic,
    );

    // Build CHW Float32 tensor in BGR order with zero-padding
    final int totalElements = 3 * _recHeight * imgW;
    final data = Float32List(totalElements);

    for (int c = 0; c < 3; c++) {
      for (int h = 0; h < _recHeight; h++) {
        for (int w = 0; w < imgW; w++) {
          final idx = c * _recHeight * imgW + h * imgW + w;
          if (w < resizedW) {
            final pixel = resized.getPixel(w, h);
            // BGR order: channel 0=Blue, 1=Green, 2=Red
            double val;
            switch (c) {
              case 0: val = pixel.b / 255.0;
              case 1: val = pixel.g / 255.0;
              default: val = pixel.r / 255.0;
            }
            data[idx] = (val - 0.5) / 0.5;
          } else {
            data[idx] = 0.0;
          }
        }
      }
    }

    return (data, imgW);
  }

  /// Enhance image contrast for better digit recognition on water meters.
  /// Applies adaptive contrast stretching without full binarization
  /// (PaddleOCR was trained on color/grayscale, not binary images).
  img.Image _enhanceForOcr(img.Image source) {
    // Convert to grayscale to analyze contrast
    final gray = img.grayscale(img.Image.from(source));
    final stats = _imageStats(gray);

    // Enhance if image has low-to-moderate contrast (relaxed threshold)
    if (stats.stdDev >= 70) return source;

    // Apply contrast stretching: map [minVal, maxVal] → [0, 255]
    final range = stats.maxVal - stats.minVal;
    if (range < 20) return source; // Too flat, enhancement would amplify noise

    final result = img.Image.from(source);
    final scale = 255.0 / range;

    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final pixel = result.getPixel(x, y);
        final r = ((pixel.r.toInt() - stats.minVal) * scale).clamp(0, 255).toInt();
        final g = ((pixel.g.toInt() - stats.minVal) * scale).clamp(0, 255).toInt();
        final b = ((pixel.b.toInt() - stats.minVal) * scale).clamp(0, 255).toInt();
        result.setPixel(x, y, img.ColorRgb8(r, g, b));
      }
    }

    return result;
  }

  /// Sharpen image with unsharp mask to enhance digit edges.
  img.Image _sharpenImage(img.Image source) {
    final blurred = img.gaussianBlur(source, radius: 2);
    final result = img.Image.from(source);
    const strength = 0.7;

    for (int y = 0; y < source.height; y++) {
      for (int x = 0; x < source.width; x++) {
        final orig = source.getPixel(x, y);
        final blur = blurred.getPixel(x, y);
        final r = (orig.r + strength * (orig.r - blur.r))
            .round().clamp(0, 255);
        final g = (orig.g + strength * (orig.g - blur.g))
            .round().clamp(0, 255);
        final b = (orig.b + strength * (orig.b - blur.b))
            .round().clamp(0, 255);
        result.setPixel(x, y, img.ColorRgb8(r, g, b));
      }
    }
    return result;
  }



  /// Compute basic image statistics (min, max, mean, std dev) from grayscale.
  ({int minVal, int maxVal, double mean, double stdDev}) _imageStats(img.Image gray) {
    int minVal = 255, maxVal = 0;
    double sum = 0;
    final total = gray.width * gray.height;

    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        final v = gray.getPixel(x, y).r.toInt();
        if (v < minVal) minVal = v;
        if (v > maxVal) maxVal = v;
        sum += v;
      }
    }

    final mean = sum / total;
    double varSum = 0;
    for (int y = 0; y < gray.height; y++) {
      for (int x = 0; x < gray.width; x++) {
        final diff = gray.getPixel(x, y).r.toInt() - mean;
        varSum += diff * diff;
      }
    }

    return (
      minVal: minVal,
      maxVal: maxVal,
      mean: mean,
      stdDev: math.sqrt(varSum / total),
    );
  }

  /// CTC greedy decode: argmax per timestep, collapse repeats, remove blanks.
  (String, double) _ctcGreedyDecode(
    List<dynamic> flat,
    int timeSteps,
    int numClasses,
    bool transposed, {
    Set<int>? allowedIndices,
  }) {
    final buf = StringBuffer();
    int lastIdx = 0;
    double totalConf = 0.0;
    int charCount = 0;

    for (int t = 0; t < timeSteps; t++) {
      int bestIdx = 0;
      double bestProb = -1.0;

      for (int c = 0; c < numClasses; c++) {
        if (allowedIndices != null && !allowedIndices.contains(c)) continue;

        final int flatIdx = transposed
            ? c * timeSteps + t
            : t * numClasses + c;
        final prob = (flat[flatIdx] as num).toDouble();
        if (prob > bestProb) {
          bestProb = prob;
          bestIdx = c;
        }
      }

      if (bestIdx != 0 && bestIdx != lastIdx) {
        if (bestIdx < _charset.length) {
          buf.write(_charset[bestIdx]);
          totalConf += bestProb;
          charCount++;
        }
      }
      lastIdx = bestIdx;
    }

    final avgConf = charCount > 0 ? totalConf / charCount : 0.0;
    return (buf.toString(), avgConf);
  }

  /// CTC beam search decode: maintains top-K hypotheses at each timestep.
  ///
  /// Returns top-K decoded candidates sorted by confidence (descending).
  /// Uses log-probabilities internally for numerical stability.
  List<OcrCandidate> _ctcBeamSearchDecode(
    List<dynamic> flat,
    int timeSteps,
    int numClasses,
    bool transposed, {
    Set<int>? allowedIndices,
    int beamWidth = 6,
  }) {
    // Apply softmax per timestep to get probabilities from logits
    final probs = _softmaxPerTimestep(flat, timeSteps, numClasses, transposed, allowedIndices);

    // Each beam: (prefix as list of char indices, last emitted index, log probability)
    // prefix stores the actual decoded characters (after CTC collapse)
    var beams = <_Beam>[_Beam(prefix: [], lastIdx: 0, logProb: 0.0)];

    for (int t = 0; t < timeSteps; t++) {
      final nextBeams = <String, _Beam>{}; // key = prefix string for dedup

      for (final beam in beams) {
        // For each allowed class at this timestep
        final classes = allowedIndices ?? List.generate(numClasses, (i) => i).toSet();
        for (final c in classes) {
          if (c >= numClasses) continue;
          final logP = probs[t][c];
          final newLogProb = beam.logProb + logP;

          List<int> newPrefix;
          int newLastIdx;

          if (c == 0) {
            // Blank: keep prefix unchanged, reset lastIdx to allow repeats
            newPrefix = beam.prefix;
            newLastIdx = 0;
          } else if (c == beam.lastIdx) {
            // Repeated char: CTC collapses it, keep prefix unchanged
            newPrefix = beam.prefix;
            newLastIdx = c;
          } else {
            // New character: extend prefix
            newPrefix = [...beam.prefix, c];
            newLastIdx = c;
          }

          final key = '${newPrefix.join(",")}_$newLastIdx';
          final existing = nextBeams[key];
          if (existing == null || newLogProb > existing.logProb) {
            nextBeams[key] = _Beam(
              prefix: newPrefix,
              lastIdx: newLastIdx,
              logProb: newLogProb,
            );
          }
        }
      }

      // Keep top beamWidth beams
      final sorted = nextBeams.values.toList()
        ..sort((a, b) => b.logProb.compareTo(a.logProb));
      beams = sorted.take(beamWidth).toList();
    }

    // Deduplicate beams with same text (different lastIdx but same prefix)
    final seen = <String, _Beam>{};
    for (final beam in beams) {
      final text = beam.prefix.map((i) => i < _charset.length ? _charset[i] : '').join();
      final existing = seen[text];
      if (existing == null || beam.logProb > existing.logProb) {
        seen[text] = beam;
      }
    }

    // Convert to candidates with normalized confidence
    final candidates = seen.entries.map((e) {
      final text = e.key;
      final beam = e.value;
      // Normalize log prob by sequence length to get per-char avg confidence
      final charCount = beam.prefix.length;
      final avgLogProb = charCount > 0 ? beam.logProb / charCount : beam.logProb;
      // Convert log-prob to [0,1] confidence (sigmoid-like normalization)
      final confidence = 1.0 / (1.0 + math.exp(-avgLogProb));
      return OcrCandidate(text, confidence);
    }).toList();

    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    return candidates;
  }

  /// Compute softmax probabilities per timestep, returning log-probabilities.
  /// Only considers [allowedIndices] if provided.
  List<List<double>> _softmaxPerTimestep(
    List<dynamic> flat,
    int timeSteps,
    int numClasses,
    bool transposed,
    Set<int>? allowedIndices,
  ) {
    final result = <List<double>>[];

    for (int t = 0; t < timeSteps; t++) {
      // Collect logits for this timestep
      double maxLogit = double.negativeInfinity;
      final logits = List<double>.filled(numClasses, double.negativeInfinity);

      for (int c = 0; c < numClasses; c++) {
        if (allowedIndices != null && !allowedIndices.contains(c)) continue;
        final int flatIdx = transposed
            ? c * timeSteps + t
            : t * numClasses + c;
        logits[c] = (flat[flatIdx] as num).toDouble();
        if (logits[c] > maxLogit) maxLogit = logits[c];
      }

      // Softmax → log-softmax for numerical stability
      double sumExp = 0.0;
      for (int c = 0; c < numClasses; c++) {
        if (allowedIndices != null && !allowedIndices.contains(c)) continue;
        sumExp += math.exp(logits[c] - maxLogit);
      }
      final logSumExp = maxLogit + math.log(sumExp);

      final logProbs = List<double>.filled(numClasses, -100.0); // -inf for masked
      for (int c = 0; c < numClasses; c++) {
        if (allowedIndices != null && !allowedIndices.contains(c)) continue;
        logProbs[c] = logits[c] - logSumExp;
      }

      result.add(logProbs);
    }

    return result;
  }

  Future<void> dispose() async {
    await _session?.close();
    _session = null;
    _initialized = false;
  }
}

/// Internal beam state for CTC beam search.
class _Beam {
  final List<int> prefix;
  final int lastIdx;
  final double logProb;

  const _Beam({
    required this.prefix,
    required this.lastIdx,
    required this.logProb,
  });
}
