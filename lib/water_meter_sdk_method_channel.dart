import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'water_meter_sdk_platform_interface.dart';

/// An implementation of [WaterMeterSdkPlatform] that uses method channels.
class MethodChannelWaterMeterSdk extends WaterMeterSdkPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('water_meter_sdk');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<Map<String, dynamic>> processImage(String imagePath) async {
    try {
      final result = await methodChannel.invokeMethod<Map<Object?, Object?>>(
        'processImage',
        {'imagePath': imagePath},
      );
      
      // Convert the result to Map<String, dynamic>
      return result?.map((key, value) => MapEntry(key.toString(), value)) ?? {};
    } on PlatformException catch (e) {
      return {
        'error': e.message ?? 'Unknown error',
        'details': e.details,
      };
    }
  }
}
