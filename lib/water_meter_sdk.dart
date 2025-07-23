import 'package:water_meter_sdk/services/water_meter_ocr_service_tf_lite.dart';
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:path_provider/path_provider.dart';
import 'services/water_meter_ocr_service.dart';
import 'models/water_meter_result.dart';
export 'models/water_meter_result.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';
import 'dart:io';
class WaterMeterSdk {
  final WaterMeterOCRService _ocrService = WaterMeterOCRService();

  Future<WaterMeterResult?> processWaterMeterImage(Uint8List imageBytes, {bool isOnline = false}) async {
    final detector = WaterMeterOcrServiceTfLite();
    await detector.loadModel();

    DetectionResult? resultImage = await detector.detect(imageBytes);
    if (resultImage != null) {
      if (resultImage.boxes.isNotEmpty && resultImage.processedImage != null) {
        final box = resultImage.boxes.first;
        final cropped = img.copyCrop(
          resultImage.processedImage!,
          x: box.x1,
          y: box.y1,
          width: box.x2 - box.x1,
          height: box.y2 - box.y1,
        );
        final croppedBytes = img.encodeJpg(cropped);
        if (isOnline) {
        final tempFile = await saveBytesToTempFile(croppedBytes, 'cropped.jpg');

        final ocrApi = GetNumberOCR();
        final result = await ocrApi.ocrImage(tempFile);
        return WaterMeterResult(
          imageBytes: croppedBytes,
            reading: result ?? '',
            confidence: 0,
          );
        } else {
          return await processWaterMeterImageAfterDetect(croppedBytes);
        }
      } else {
        return null;
      }
    }
    return null;
  }

  Future<File> saveBytesToTempFile(Uint8List bytes, String filename) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$filename');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<WaterMeterResult> processWaterMeterImageAfterDetect(Uint8List imageBytes) async {
    return await _ocrService.processImage(imageBytes);
  }

  Future<void> dispose() async {
    await _ocrService.dispose();
  }
}

