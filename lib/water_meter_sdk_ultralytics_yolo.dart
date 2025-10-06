import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:ultralytics_yolo/yolo.dart';
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/services/water_meter_ocr_service.dart';

class WaterMeterSdkUltralyticsYolo {
  final WaterMeterOCRService _ocrService = WaterMeterOCRService();
  late YOLO yolo;


  Future init() async {
      yolo = YOLO(
          modelPath: 'yolo11n-obb',
        task: YOLOTask.obb,
      );
      await yolo.loadModel();
  }

  Future<WaterMeterResult?> processWaterMeterImage(Uint8List imageBytes, {bool isOnline = false}) async {
    final croppedBytesAfter = await runOBBDetectionAndCrop(imageBytes);
        if (isOnline) {
        final tempFile = await saveBytesToTempFile(croppedBytesAfter, 'cropped.jpg');

        final ocrApi = GetNumberOCR();
        final result = await ocrApi.ocrImage(tempFile);
        return WaterMeterResult(
          imageBytes: croppedBytesAfter,
            reading: result ?? '',
            confidence: 0,
          );
        } else {
          return await _ocrService.processImage(croppedBytesAfter);
        }
  }

  Future<File> saveBytesToTempFile(Uint8List bytes, String filename) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$filename');
    await file.writeAsBytes(bytes);
    return file;
  }



  Future<Uint8List> runOBBDetectionAndCrop(Uint8List imageBytes) async {

    Uint8List imageBytesAfter;

    final originalImageBytes = imageBytes;
    
    final originalImage = img.decodeImage(originalImageBytes);
    if (originalImage == null) {
      return imageBytes;
    }
    
    final resizedImage = img.copyResize(originalImage, width: 416, height: 416);
    final resizedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));
    
    final results = await yolo.predict(resizedImageBytes);
    final obbList = results['obb'] as List<dynamic>;
    
    if (obbList.isNotEmpty) {
      final detections = <Map<String, dynamic>>[];
      
      for (final detection in obbList) {
        final boxes = detection as Map<dynamic, dynamic>;
        final points = boxes['points'] as List<dynamic>? ?? [];
        if (points.isNotEmpty) {
          double minX = double.infinity;
          double maxX = double.negativeInfinity;
          double minY = double.infinity;
          double maxY = double.negativeInfinity;
          
          for (final point in points) {
            final pointMap = point as Map<dynamic, dynamic>;
            final x = (pointMap['x'] as num).toDouble();
            final y = (pointMap['y'] as num).toDouble();
            
            minX = minX < x ? minX : x;
            maxX = maxX > x ? maxX : x;
            minY = minY < y ? minY : y;
            maxY = maxY > y ? maxY : y;
          }

          detections.add({
                'class': boxes['class'],
                'confidence': (boxes['confidence'] as num).toDouble(),
                'points': points,
              });
              print('  --- $boxes');

          if (points.isNotEmpty && points.length == 4 && (boxes['confidence'] as num).toDouble() > 0.2 && (boxes['confidence'] as num).toDouble() < 1) { 
            imageBytesAfter = cropImageFromOBB(resizedImageBytes, points);
            return imageBytesAfter;
          }
        }
        
        // Add to detections list for drawing
        detections.add({
          'class': boxes['class'],
          'confidence': (boxes['confidence'] as num).toDouble(),
          'points': points,
        });
        print('  ---');
      }
      
    } 
    return imageBytes;
  }

  Uint8List cropImageFromOBB(Uint8List imageBytes, List<dynamic> points) {
    final image = img.decodeImage(imageBytes);
    if (image == null) throw Exception('Failed to decode image for cropping');

    // Calculate bounding box from OBB points
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    for (final point in points) {
      final pointMap = point as Map<dynamic, dynamic>;
      final x = (pointMap['x'] as num).toDouble() * image.width;
      final y = (pointMap['y'] as num).toDouble() * image.height;

      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
    }

    // Add some padding
    final padding = Platform.isIOS ? 15 : 0;
    minX = math.max(0, minX - padding);
    minY = math.max(0, minY - padding);
    maxX = math.min(image.width.toDouble(), maxX + padding);
    maxY = math.min(image.height.toDouble(), maxY + padding);

    // Crop the image
    final croppedImage = img.copyCrop(
      image,
      x: minX.round(),
      y: minY.round(),
      width: (maxX - minX).round(),
      height: (maxY - minY).round(),
    );

    return Uint8List.fromList(img.encodePng(croppedImage));
  }

  Future<void> dispose() async {
    await yolo.dispose();
    await _ocrService.dispose();
  }
}