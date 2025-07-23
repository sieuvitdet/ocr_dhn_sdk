# water_meter_sdk

A new Flutter plugin project.

## Getting Started

This project is a starting point for a Flutter
[plug-in package](https://flutter.dev/to/develop-plugins),
a specialized package that includes platform-specific implementation code for
Android and/or iOS.

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev), which offers tutorials,
samples, guidance on mobile development, and a full API reference.


// 1.0.3
Tải về model : water_model_detect.tflite và lưu ở assets/models/water_model_detect.tflite'

WaterMeterResult? result = await _waterMeterSdkPlugin.processWaterMeterImage(imageBytes, {bool isOnline = false});

isOnline = true : Call api OCR (Khuyến nghị dùng để tăng độ chính xác nhe).
inOnline = false : Detect+OCR local , không cần Internet.
Có thể check Connectivity trước khi dùng SDK , hoặc truyền default nhé.