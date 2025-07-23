import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class WaterMeterOcrServiceTfLite {
  late Interpreter _interpreter;
  late List<int> _inputShape;
  late List<int> _outputShape;
  
  // Cache for preprocessing
  static const int _modelInputSize = 416;
  static const double _normalizeValue = 255.0;
  
  // Detection parameters
  static const double _defaultConfidenceThreshold = 0.3;
  static const double _defaultNmsThreshold = 0.45;
  
  bool _isModelLoaded = false;

  Future<void> loadModel() async {
    try {
      final modelPath = 'assets/models/water_model_detect.tflite';
      
      // Load with options for better performance
      final options = InterpreterOptions()
        ..threads = 4; 
      
      _interpreter = await Interpreter.fromAsset(modelPath, options: options);
      
      // Get tensor info
      _inputShape = _interpreter.getInputTensor(0).shape;
      _outputShape = _interpreter.getOutputTensor(0).shape;
      
      _isModelLoaded = true;
      
      print("✅ Model loaded successfully");
      print("📊 Input shape: $_inputShape");
      print("📊 Output shape: $_outputShape");
    } catch (e) {
      print("❌ Error loading model: $e");
      throw Exception("Failed to load water detection model: $e");
    }
  }

  Future<DetectionResult?> detect(
    Uint8List imageFile, {
    double confidenceThreshold = _defaultConfidenceThreshold,
    double nmsThreshold = _defaultNmsThreshold,
    bool returnProcessedImage = true,
  }) async {
    if (!_isModelLoaded) {
      throw Exception("Model not loaded. Call loadModel() first.");
    }

    try {
      final rawImage = img.decodeImage(imageFile);
      if (rawImage == null) {
        print("❌ Failed to decode image");
        return null;
      }

      // Store original dimensions
      final originalWidth = rawImage.width;
      final originalHeight = rawImage.height;

      // Preprocess image
      final inputTensor = _preprocessImage(rawImage);

      // Run inference
      final detections = await _runInference(inputTensor);

      // Process detections
      final boxes = _processDetections(
        detections,
        originalWidth,
        originalHeight,
        confidenceThreshold,
      );

      // Apply NMS
      final filteredBoxes = _nonMaxSuppression(boxes, nmsThreshold);

      // Không vẽ bounding box nữa, processedImage là ảnh gốc
      img.Image? processedImage;
      if (returnProcessedImage) {
        processedImage = rawImage;
      }

      return DetectionResult(
        boxes: filteredBoxes,
        processedImage: processedImage,
        inferenceTime: 0, // You can add timing if needed
      );
    } catch (e) {
      print("❌ Detection error: $e");
      return null;
    }
  }

  Float32List _preprocessImage(img.Image image) {
    // Resize image to model input size
    final resized = img.copyResize(
      image,
      width: _modelInputSize,
      height: _modelInputSize,
      interpolation: img.Interpolation.linear,
    );

    // Convert to Float32List in correct format
    final buffer = Float32List(_modelInputSize * _modelInputSize * 3);
    var bufferIndex = 0;

    // Convert to RGB and normalize
    for (var y = 0; y < _modelInputSize; y++) {
      for (var x = 0; x < _modelInputSize; x++) {
        final pixel = resized.getPixel(x, y);
        buffer[bufferIndex++] = pixel.r / _normalizeValue;
        buffer[bufferIndex++] = pixel.g / _normalizeValue;
        buffer[bufferIndex++] = pixel.b / _normalizeValue;
      }
    }

    return buffer;
  }

  Future<List<List<double>>> _runInference(Float32List inputTensor) async {
    // Reshape input
    final input = inputTensor.reshape([1, _modelInputSize, _modelInputSize, 3]);
    
    // Allocate output buffer
    final output = List.generate(
      1,
      (i) => List.generate(
        _outputShape[1],
        (j) => List.filled(_outputShape[2], 0.0),
      ),
    );

    // Run inference
    _interpreter.run(input, output);

    return output[0];
  }

  List<BoundingBox> _processDetections(
    List<List<double>> output,
    int imageWidth,
    int imageHeight,
    double confidenceThreshold,
  ) {
    final boxes = <BoundingBox>[];
    
    // Extract detection data
    final xCenters = output[0];
    final yCenters = output[1];
    final widths = output[2];
    final heights = output[3];
    final confidences = output[4];

    for (int i = 0; i < confidences.length; i++) {
      if (confidences[i] > confidenceThreshold) {
        // Convert from normalized coordinates
        final xCenter = xCenters[i] * imageWidth;
        final yCenter = yCenters[i] * imageHeight;
        final width = widths[i] * imageWidth;
        final height = heights[i] * imageHeight;

        // Calculate bounding box
        final x1 = (xCenter - width / 2).clamp(0, imageWidth.toDouble());
        final y1 = (yCenter - height / 2).clamp(0, imageHeight.toDouble());
        final x2 = (xCenter + width / 2).clamp(0, imageWidth.toDouble());
        final y2 = (yCenter + height / 2).clamp(0, imageHeight.toDouble());

        boxes.add(BoundingBox(
          x1: x1.toInt(),
          y1: y1.toInt(),
          x2: x2.toInt(),
          y2: y2.toInt(),
          confidence: confidences[i],
          label: 'Water',
        ));
      }
    }

    return boxes;
  }

  List<BoundingBox> _nonMaxSuppression(
    List<BoundingBox> boxes,
    double threshold,
  ) {
    if (boxes.isEmpty) return [];

    // Sort by confidence
    boxes.sort((a, b) => b.confidence.compareTo(a.confidence));

    final selected = <BoundingBox>[];
    final active = List.filled(boxes.length, true);

    for (int i = 0; i < boxes.length; i++) {
      if (!active[i]) continue;
      
      selected.add(boxes[i]);

      for (int j = i + 1; j < boxes.length; j++) {
        if (!active[j]) continue;

        final iou = _calculateIoU(boxes[i], boxes[j]);
        if (iou > threshold) {
          active[j] = false;
        }
      }
    }

    return selected;
  }

  double _calculateIoU(BoundingBox box1, BoundingBox box2) {
    final x1 = math.max(box1.x1, box2.x1);
    final y1 = math.max(box1.y1, box2.y1);
    final x2 = math.min(box1.x2, box2.x2);
    final y2 = math.min(box1.y2, box2.y2);

    if (x2 < x1 || y2 < y1) return 0.0;

    final intersection = (x2 - x1) * (y2 - y1);
    final area1 = (box1.x2 - box1.x1) * (box1.y2 - box1.y1);
    final area2 = (box2.x2 - box2.x1) * (box2.y2 - box2.y1);
    final union = area1 + area2 - intersection;

    return intersection / union;
  }

  img.Image _drawDetections(img.Image image, List<BoundingBox> boxes) {
    final result = img.Image.from(image);
    
    for (final box in boxes) {
      // Draw bounding box
      img.drawRect(
        result,
        x1: box.x1,
        y1: box.y1,
        x2: box.x2,
        y2: box.y2,
        color: img.ColorRgb8(0, 255, 0),
        thickness: 2,
      );

      // Draw label with confidence
      final label = "${box.label}: ${(box.confidence * 100).toStringAsFixed(1)}%";
      img.drawString(
        result,
        label,
        font: img.arial14,
        x: box.x1,
        y: math.max(0, box.y1 - 20),
        color: img.ColorRgb8(0, 255, 0),
      );
    }

    return result;
  }

  void dispose() {
    if (_isModelLoaded) {
      _interpreter.close();
      _isModelLoaded = false;
    }
  }
}

// Data classes
class BoundingBox {
  final int x1, y1, x2, y2;
  final double confidence;
  final String label;

  BoundingBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.confidence,
    required this.label,
  });
}

class DetectionResult {
  final List<BoundingBox> boxes;
  final img.Image? processedImage;
  final int inferenceTime;

  DetectionResult({
    required this.boxes,
    this.processedImage,
    required this.inferenceTime,
  });
}