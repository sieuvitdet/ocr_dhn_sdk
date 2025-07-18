import 'dart:typed_data';

import 'water_meter_sdk_platform_interface.dart';
import 'services/water_meter_ocr_service.dart';
import 'models/water_meter_result.dart';
export 'models/water_meter_result.dart';

class WaterMeterSdk {
  final WaterMeterOCRService _ocrService = WaterMeterOCRService();

  Future<String?> getPlatformVersion() {
    return WaterMeterSdkPlatform.instance.getPlatformVersion();
  }

  /// Process an image file to extract water meter reading
  /// [imagePath] should be a valid path to an image file
  Future<WaterMeterResult> processWaterMeterImage(Uint8List imageBytes, {String? imageFull}) async {
    return await _ocrService.processImage(imageBytes, imageFull: imageFull);
  }

  /// Dispose of resources
  Future<void> dispose() async {
    await _ocrService.dispose();
  }
}
