// import 'dart:io';
// import 'package:fluttertoast/fluttertoast.dart';
// import 'package:path_provider/path_provider.dart';
// import 'package:ultralytics_yolo/ultralytics_yolo.dart';
// import 'dart:typed_data';
// import 'dart:math' as math;
// import 'package:flutter/foundation.dart';
// import 'package:flutter/services.dart';
// import 'package:image/image.dart' as img;
// import 'package:ultralytics_yolo/yolo.dart';
// import 'package:water_meter_sdk/api/get_number_ocr.dart';
// import 'package:water_meter_sdk/models/water_meter_result.dart';
// import 'package:water_meter_sdk/services/water_meter_ocr_service.dart';
// export 'models/water_meter_result.dart';
// class WaterMeterSdk {
//   final WaterMeterOCRService _ocrService = WaterMeterOCRService();
//   late YOLO yolo;

//   Future init() async {
//     yolo = YOLO(
//       modelPath: 'yolo11n-obb',
//       task: YOLOTask.obb,
      
//     );
//     await yolo.loadModel();
//   }

//   Future<WaterMeterResult?> processWaterMeterImage(Uint8List imageBytes, {bool isOnline = false}) async {
//     Uint8List croppedBytesAfter = Platform.isAndroid ? await runOBBDetectionAndCropAndroid(imageBytes) : await runOBBDetectionAndCropIOS(imageBytes);
//     if (isOnline) {
//       final tempFile = await saveBytesToTempFile(croppedBytesAfter, 'cropped.jpg');
//       final ocrApi = GetNumberOCR();
//       final result = await ocrApi.ocrImage(tempFile);
//       return WaterMeterResult(
//         imageBytes: croppedBytesAfter,
//         reading: result ?? '',
//         confidence: 0,
//       );
//     } else {
//       return await _ocrService.processImage(croppedBytesAfter);
//     }
//   }

//   Future<File> saveBytesToTempFile(Uint8List bytes, String filename) async {
//     final tempDir = await getTemporaryDirectory();
//     final file = File('${tempDir.path}/$filename');
//     await file.writeAsBytes(bytes);
//     return file;
//   }

//   Future<Uint8List> runOBBDetectionAndCropIOS(Uint8List imageBytes) async {
//     Uint8List imageBytesAfter;

//     final originalImageBytes = imageBytes;
    
//     final originalImage = img.decodeImage(originalImageBytes);
//     if (originalImage == null) {
//       return imageBytes;
//     }
    
//     final resizedImage = img.copyResize(originalImage, width: 416, height: 416);
//     final resizedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));
    
//     final results = await yolo.predict(resizedImageBytes);
//     final obbList = results['obb'] as List<dynamic>;
    
//     if (obbList.isNotEmpty) {
//       final detections = <Map<String, dynamic>>[];
      
//       for (final detection in obbList) {
//         final boxes = detection as Map<dynamic, dynamic>;
//         final points = boxes['points'] as List<dynamic>? ?? [];
//         if (points.isNotEmpty) {
//           double minX = double.infinity;
//           double maxX = double.negativeInfinity;
//           double minY = double.infinity;
//           double maxY = double.negativeInfinity;
          
//           for (final point in points) {
//             final pointMap = point as Map<dynamic, dynamic>;
//             final x = (pointMap['x'] as num).toDouble();
//             final y = (pointMap['y'] as num).toDouble();
            
//             minX = minX < x ? minX : x;
//             maxX = maxX > x ? maxX : x;
//             minY = minY < y ? minY : y;
//             maxY = maxY > y ? maxY : y;

//             detections.add({
//                 'class': boxes['class'],
//                 'confidence': (boxes['confidence'] as num).toDouble(),
//                 'points': points,
//               });
//               print('  --- $boxes');

//           }

//           if (points.isNotEmpty && points.length == 4 && (boxes['confidence'] as num).toDouble() > 0.2 && (boxes['confidence'] as num).toDouble() < 1) { 
//             imageBytesAfter = cropImageFromOBB(resizedImageBytes, points);
//             return imageBytesAfter;
//           }
//         }
//       }
//     } 
//     return imageBytes;
//   }

//   Future<Uint8List> runOBBDetectionAndCropAndroid(Uint8List imageBytes) async {
//   final originalImage = img.decodeImage(imageBytes);
//   if (originalImage == null) return imageBytes;

//   final resizedImage = img.copyResize(originalImage, width: 416, height: 416);
//   final resizedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));

//   final results = await yolo.predict(resizedImageBytes);
//   final obbList = results['obb'] as List<dynamic>;

//   if (obbList.isEmpty) return imageBytes;

//   // Lọc chỉ giữ detections có tọa độ normalized (0..1) và confidence > 0.2
//   final validDetections = obbList.where((detection) {
//     final boxes = detection as Map<dynamic, dynamic>;
//     final points = boxes['points'] as List<dynamic>? ?? [];
//     final confidence = (boxes['confidence'] as num).toDouble();

//     if (points.length != 4 || confidence <= 0.2) return false;

//     // Kiểm tra tất cả points có normalized không
//     return points.every((p) {
//       final m = p as Map;
//       final x = (m['x'] as num).toDouble();
//       final y = (m['y'] as num).toDouble();
//       return x >= 0 && x <= 1.0 && y >= 0 && y <= 1.0;
//     });
//   }).toList();

//   if (validDetections.isEmpty) return imageBytes;

//   // Chọn detection có confidence cao nhất trong các detection hợp lệ
//   validDetections.sort((a, b) {
//     final confA = (a['confidence'] as num).toDouble();
//     final confB = (b['confidence'] as num).toDouble();
//     return confB.compareTo(confA);
//   });

//   final bestDetection = validDetections.first as Map<dynamic, dynamic>;
//   final points = bestDetection['points'] as List<dynamic>;

//   final pixelPoints = points.map((p) {
//     final m = p as Map;
//     final x = (m['x'] as num).toDouble() * resizedImage.width;
//     final y = (m['y'] as num).toDouble() * resizedImage.height;
//     return {'x': x, 'y': y};
//   }).toList();

//   return cropImageFromPoints(resizedImage, pixelPoints);
// }

//   Uint8List cropImageFromPoints(img.Image image, List<Map<String, double>> points) {
//       // Tính center và góc xoay của OBB
//       final centerX = points.map((p) => p['x']!).reduce((a, b) => a + b) / 4;
//       final centerY = points.map((p) => p['y']!).reduce((a, b) => a + b) / 4;

//       // Tính góc xoay từ 2 điểm đầu tiên
//       final dx = points[1]['x']! - points[0]['x']!;
//       final dy = points[1]['y']! - points[0]['y']!;
//       final angle = math.atan2(dy, dx);

//       // Xoay ngược lại các điểm về axis-aligned
//       final rotatedPoints = points.map((p) {
//         final x = p['x']! - centerX;
//         final y = p['y']! - centerY;
//         return {
//           'x': x * math.cos(-angle) - y * math.sin(-angle),
//           'y': x * math.sin(-angle) + y * math.cos(-angle),
//         };
//       }).toList();

//       // Tính bounding box sau khi xoay
//       double minX = rotatedPoints.map((p) => p['x']!).reduce(math.min);
//       double maxX = rotatedPoints.map((p) => p['x']!).reduce(math.max);
//       double minY = rotatedPoints.map((p) => p['y']!).reduce(math.min);
//       double maxY = rotatedPoints.map((p) => p['y']!).reduce(math.max);

//       final width = (maxX - minX).round();
//       final height = (maxY - minY).round();

//       // Xoay ảnh gốc, crop, rồi xoay lại
//       final rotatedImage = img.copyRotate(image, angle: -angle * 180 / math.pi);

//       // Tính vị trí crop trên ảnh đã xoay
//       final rotatedCenterX = rotatedImage.width / 2;
//       final rotatedCenterY = rotatedImage.height / 2;
//       final cropX = (rotatedCenterX + minX).clamp(0, rotatedImage.width - width);
//       final cropY = (rotatedCenterY + minY).clamp(0, rotatedImage.height - height);

//       final cropped = img.copyCrop(
//         rotatedImage,
//         x: cropX.round(),
//         y: cropY.round(),
//         width: width,
//         height: height,
//       );

//       return Uint8List.fromList(img.encodePng(cropped));
//     }

//   Uint8List cropImageFromOBB(Uint8List imageBytes, List<dynamic> points) {
//     final image = img.decodeImage(imageBytes);
//     if (image == null) throw Exception('Failed to decode image for cropping');

//     // Calculate bounding box from OBB points
//     double minX = double.infinity;
//     double maxX = double.negativeInfinity;
//     double minY = double.infinity;
//     double maxY = double.negativeInfinity;

//     for (final point in points) {
//       final pointMap = point as Map<dynamic, dynamic>;
//       final x = (pointMap['x'] as num).toDouble() * image.width;
//       final y = (pointMap['y'] as num).toDouble() * image.height;

//       minX = math.min(minX, x);
//       maxX = math.max(maxX, x);
//       minY = math.min(minY, y);
//       maxY = math.max(maxY, y);
//     }

//     // Add some padding
//     final padding = 0;
//     minX = math.max(0, minX - padding);
//     minY = math.max(0, minY - padding);
//     maxX = math.min(image.width.toDouble(), maxX + padding);
//     maxY = math.min(image.height.toDouble(), maxY + padding);

//     // Crop the image
//     final croppedImage = img.copyCrop(
//       image,
//       x: minX.round(),
//       y: minY.round(),
//       width: (maxX - minX).round(),
//       height: (maxY - minY).round(),
//     );

//     return Uint8List.fromList(img.encodePng(croppedImage));
//   }

//   Future<void> dispose() async {
//     await yolo.dispose();
//     await _ocrService.dispose();
//   }

// }

