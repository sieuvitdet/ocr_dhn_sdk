// Basic Flutter integration test for water_meter_sdk.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:water_meter_sdk/water_meter_sdk_ultralytics_yolo.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SDK can be constructed and is not initialized', (WidgetTester tester) async {
    final sdk = WaterMeterSdkUltralyticsYolo();
    expect(sdk.isInitialized, isFalse);
  });
}
