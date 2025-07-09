import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'water_meter_sdk_method_channel.dart';
import 'models/water_meter_result.dart';

abstract class WaterMeterSdkPlatform extends PlatformInterface {
  /// Constructs a WaterMeterSdkPlatform.
  WaterMeterSdkPlatform() : super(token: _token);

  static final Object _token = Object();

  static WaterMeterSdkPlatform _instance = MethodChannelWaterMeterSdk();

  /// The default instance of [WaterMeterSdkPlatform] to use.
  ///
  /// Defaults to [MethodChannelWaterMeterSdk].
  static WaterMeterSdkPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [WaterMeterSdkPlatform] when
  /// they register themselves.
  static set instance(WaterMeterSdkPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<Map<String, dynamic>> processImage(String imagePath) async {
    throw UnimplementedError('processImage() has not been implemented.');
  }
}
