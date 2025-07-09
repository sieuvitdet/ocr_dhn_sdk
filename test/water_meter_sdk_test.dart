import 'package:flutter_test/flutter_test.dart';
import 'package:water_meter_sdk/water_meter_sdk.dart';
import 'package:water_meter_sdk/water_meter_sdk_platform_interface.dart';
import 'package:water_meter_sdk/water_meter_sdk_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockWaterMeterSdkPlatform
    with MockPlatformInterfaceMixin
    implements WaterMeterSdkPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final WaterMeterSdkPlatform initialPlatform = WaterMeterSdkPlatform.instance;

  test('$MethodChannelWaterMeterSdk is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelWaterMeterSdk>());
  });

  test('getPlatformVersion', () async {
    WaterMeterSdk waterMeterSdkPlugin = WaterMeterSdk();
    MockWaterMeterSdkPlatform fakePlatform = MockWaterMeterSdkPlatform();
    WaterMeterSdkPlatform.instance = fakePlatform;

    expect(await waterMeterSdkPlugin.getPlatformVersion(), '42');
  });
}
