# WaterMeterSdkYoloOldVersion - Reference (Branch 1.0.7)

> File goc: `lib/water_meter_sdk_yolo_old_version.dart`
> Trang thai: **Chay tot tren iOS** voi model `yolo11n-obb`
> Muc dich: Lam tai lieu trace lai khi code tren nhanh moi

---

## 1. TONG QUAN PIPELINE

```
Input imageBytes (Uint8List)
    |
    v
[1] Decode image goc (img.decodeImage)
    |
    v
[2] Resize ve 416x416 (img.copyResize)
    |
    v
[3] Encode thanh PNG (img.encodePng)
    |
    v
[4] YOLO predict (yolo11n-obb, task: OBB)
    |
    v
[5] Loc detections: points.length == 4 && confidence > 0.2 && confidence < 1.0
    |
    v
[6] Crop bang axis-aligned bounding box (KHONG xoay)
    |  - Nhan toa do normalized [0..1] * image.width/height
    |  - Padding: iOS = 15px, Android = 0px
    |
    v
[7] OCR:
    - isOnline=true  -> POST image len API meobeo.ai
    - isOnline=false -> Google ML Kit Text Recognition (local)
    |
    v
Output: WaterMeterResult { reading, confidence, imageBytes }
```

---

## 2. CLASS WaterMeterSdkYoloOldVersion

### 2.1 Properties

```dart
class WaterMeterSdkYoloOldVersion {
  final WaterMeterOCRService _ocrService = WaterMeterOCRService();
  late YOLO yolo;
}
```

### 2.2 Model Path

```dart
String get modelPath {
  if (Platform.isAndroid) {
    return 'yolo11n-obb'; // android/app/src/main/assets/best_float32.tflite
  } else {
    return 'yolo11n-obb'; // ios/Runner/best.mlpackage
  }
}
```

**QUAN TRONG:** Ca Android va iOS deu dung model name `yolo11n-obb`. Tren iOS chay rat tot.

### 2.3 init()

```dart
Future init() async {
  yolo = YOLO(
    modelPath: modelPath,  // 'yolo11n-obb'
    task: YOLOTask.obb,     // Oriented Bounding Box
  );
  await yolo.loadModel();
}
```

### 2.4 processWaterMeterImage() - HAM CHINH

```dart
Future<WaterMeterResult?> processWaterMeterImage(
  Uint8List imageBytes,
  {bool isOnline = false}
) async {
  // B1: Detect + Crop
  final croppedBytesAfter = await runOBBDetectionAndCrop(imageBytes);

  if (isOnline) {
    // B2a: Online OCR
    final tempFile = await saveBytesToTempFile(croppedBytesAfter, 'cropped.jpg');
    final ocrApi = GetNumberOCR();
    final result = await ocrApi.ocrImage(tempFile);
    return WaterMeterResult(
      imageBytes: croppedBytesAfter,
      reading: result ?? '',
      confidence: 0,
    );
  } else {
    // B2b: Offline OCR (Google ML Kit)
    return await _ocrService.processImage(croppedBytesAfter);
  }
}
```

**Logic:**
- Goi `runOBBDetectionAndCrop` de detect va crop vung dong ho nuoc
- Neu `isOnline=true`: Luu file tam -> goi API `meobeo.ai`
- Neu `isOnline=false`: Dung `WaterMeterOCRService` (Google ML Kit)

### 2.5 runOBBDetectionAndCrop() - DETECT VA CROP

```dart
Future<Uint8List> runOBBDetectionAndCrop(Uint8List imageBytes) async {
  // B1: Decode anh goc
  final originalImage = img.decodeImage(imageBytes);
  if (originalImage == null) return imageBytes;  // Tra ve anh goc neu loi

  // B2: Resize ve 416x416
  final resizedImage = img.copyResize(originalImage, width: 416, height: 416);
  final resizedImageBytes = Uint8List.fromList(img.encodePng(resizedImage));

  // B3: Chay YOLO predict
  final results = await yolo.predict(resizedImageBytes);
  final obbList = results['obb'] as List<dynamic>;

  // B4: Duyet tung detection
  if (obbList.isNotEmpty) {
    for (final detection in obbList) {
      final boxes = detection as Map<dynamic, dynamic>;
      final points = boxes['points'] as List<dynamic>? ?? [];

      if (points.isNotEmpty && points.length == 4
          && (boxes['confidence'] as num).toDouble() > 0.2
          && (boxes['confidence'] as num).toDouble() < 1) {
        // Crop va tra ve NGAY detection dau tien hop le
        return cropImageFromOBB(resizedImageBytes, points);
      }
    }
  }

  // Khong tim thay detection hop le -> tra ve anh goc (KHONG phai anh resized)
  return imageBytes;
}
```

**DIEM QUAN TRONG:**
1. Input resize ve **416x416** truoc khi predict
2. Filter: `points.length == 4 && confidence > 0.2 && confidence < 1.0`
3. Lay **detection dau tien** hop le (KHONG sort theo confidence)
4. Neu khong co detection hop le -> tra ve **anh goc** (khong phai anh da resize)

### 2.6 cropImageFromOBB() - CROP ANH TU OBB POINTS

```dart
Uint8List cropImageFromOBB(Uint8List imageBytes, List<dynamic> points) {
  final image = img.decodeImage(imageBytes);
  if (image == null) throw Exception('Failed to decode image for cropping');

  // Tinh bounding box tu OBB points
  // TOA DO NORMALIZED: nhan voi image.width va image.height
  double minX = double.infinity;
  double maxX = double.negativeInfinity;
  double minY = double.infinity;
  double maxY = double.negativeInfinity;

  for (final point in points) {
    final pointMap = point as Map<dynamic, dynamic>;
    final x = (pointMap['x'] as num).toDouble() * image.width;   // <- NORMALIZED * width
    final y = (pointMap['y'] as num).toDouble() * image.height;  // <- NORMALIZED * height

    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }

  // Padding theo platform
  final padding = Platform.isIOS ? 15 : 0;
  minX = math.max(0, minX - padding);
  minY = math.max(0, minY - padding);
  maxX = math.min(image.width.toDouble(), maxX + padding);
  maxY = math.min(image.height.toDouble(), maxY + padding);

  // Crop bang axis-aligned bounding box (KHONG XOAY)
  final croppedImage = img.copyCrop(
    image,
    x: minX.round(),
    y: minY.round(),
    width: (maxX - minX).round(),
    height: (maxY - minY).round(),
  );

  return Uint8List.fromList(img.encodePng(croppedImage));
}
```

**DIEM QUAN TRONG VE CROP:**
1. **Toa do la NORMALIZED [0..1]** -> nhan voi `image.width` va `image.height`
2. **Crop AXIS-ALIGNED** (dung `img.copyCrop`) - KHONG xoay theo goc OBB
3. **Padding 15px cho iOS**, 0px cho Android
4. Output la PNG

### 2.7 dispose()

```dart
Future<void> dispose() async {
  await yolo.dispose();
  await _ocrService.dispose();
}
```

---

## 3. YOLO OUTPUT FORMAT

```dart
final results = await yolo.predict(resizedImageBytes);
// results la Map<String, dynamic> voi cac key:
// - 'obb': List<dynamic>  (danh sach detections)
// - 'boxes': ...
// - 'annotatedImage': ...
// - 'imageSize': ...
// - 'speed': ...
// - 'detections': ...
```

### Moi detection trong obbList:

```dart
{
  'class': dynamic,        // ten class (vd: 'class_39', 'class_265', ...)
  'confidence': num,       // confidence score
  'points': List<dynamic>, // 4 OBB points
}
```

### Moi point:

```dart
{
  'x': num,  // toa do x (normalized [0..1] hoac pixel tuy platform)
  'y': num,  // toa do y (normalized [0..1] hoac pixel tuy platform)
}
```

### Log thuc te tu iOS (DANG CHAY TOT):

```
OBB detections: 5
Detection #0: class=class_39,  confidence=636.0000  -> SKIP (conf > 1)
Detection #1: class=class_265, confidence=634.5000  -> SKIP (conf > 1)
Detection #2: class=class_197, confidence=235.8750  -> SKIP (conf > 1)
Detection #3: class=class_197, confidence=90.3125   -> SKIP (conf > 1)
Detection #4: class=class_266, confidence=0.3640    -> CROP (0.2 < 0.364 < 1.0)
  P0: x=0.0005166, y=-0.0000099
  P1: x=0.0007123, y=-0.0000021
  P2: x=0.0007140, y=-0.0000444
  P3: x=0.0005182, y=-0.0000521
```

**Ghi chu:** Model `yolo11n-obb` la model COCO generic (80+ classes). Confidence values > 1.0 la raw scores, khong phai probability. Filter `> 0.2 && < 1.0` chi giu lai detections co confidence nho.

---

## 4. SO SANH VOI PHIEN BAN MOI (WaterMeterSdkUltralyticsYolo)

| Dac diem | Old Version | New Version |
|----------|-------------|-------------|
| Model | `yolo11n-obb` (generic COCO) | `best_float32`/`best` (custom water meter) |
| Resize | 416x416 | 416x416 |
| Crop Android | Normalized coords, KHONG xoay | Normalized, co xoay (rotation-aware) |
| Crop iOS | Normalized coords, KHONG xoay | Pixel coords, co xoay |
| Padding | iOS: 15px, Android: 0px | Khong co padding, dung rotation |
| Detection filter | First valid (>0.2, <1.0) | iOS: first valid; Android: best confidence |
| Crop method | `img.copyCrop` (axis-aligned) | `img.copyRotate` + `img.copyCrop` (rotation-aware) |

---

## 5. FILE PHU THUOC

### 5.1 WaterMeterResult (`lib/models/water_meter_result.dart`)

```dart
@immutable
class WaterMeterResult {
  final String reading;         // Ket qua so doc duoc (vd: "00123")
  final double confidence;      // Do tin cay [0..1]
  final Uint8List? imageBytes;  // Anh da xu ly (annotated)
  final List<String>? debugInfo;
  final String? rawOcrText;     // Text tho tu OCR
  final String? processedText;  // Text sau khi xu ly

  const WaterMeterResult({
    required this.reading,
    required this.confidence,
    this.imageBytes,
    this.debugInfo,
    this.rawOcrText,
    this.processedText,
  });

  factory WaterMeterResult.empty() => const WaterMeterResult(reading: '', confidence: 0.0);
}
```

### 5.2 GetNumberOCR - Online OCR (`lib/api/get_number_ocr.dart`)

```dart
class GetNumberOCR {
  final String apiUrl = 'https://super-agent-api.meobeo.ai/water-clock-ocr';

  Future<String?> ocrImage(File imageFile) async {
    // POST multipart form: field 'image' = imageFile
    // Response JSON:
    // {
    //   "status_code": 0,
    //   "data": { "success": true, "result": "00123" }
    // }
    // Tra ve data['data']['result'] as String
  }
}
```

### 5.3 WaterMeterOCRService - Offline OCR (`lib/services/water_meter_ocr_service.dart`)

```dart
class WaterMeterOCRService {
  final TextRecognizer _textRecognizer = TextRecognizer(); // Google ML Kit

  Future<WaterMeterResult> processImage(Uint8List imageBytes) async {
    // B1: Decode image
    // B2: Chay OCR voi approach 'threshold' (img goc, khong tien xu ly dac biet)
    // B3: Chon ket qua tot nhat (_selectBestFromMultipleResults)
    // B4: Tao annotated image (ve bbox xanh quanh text)
    // B5: Tra ve WaterMeterResult
  }
}
```

**OCR Error Correction:**
```dart
'O' -> '0', 'o' -> '0', 'D' -> '0'
'I' -> '1', 'l' -> '1'
'S' -> '5', 's' -> '5'
'Z' -> '2'
'B' -> '8'
```

**Uu tien ket qua:**
1. So co **5 chu so** (regex `^\d{5}$`)
2. So co **4 chu so** (regex `^\d{4}$`)
3. Tinh diem: do dai >= 6 (+50), >= 4 (+30), >= 3 (+10); la so hop le 0..9999999 (+25); khong bat dau bang '20' (+15)

**Extract reading logic:**
- Tach text thanh cac dong
- Bo qua dong co chu cai (tru 'm3' hoac 'm3')
- Tim tat ca so trong dong (regex `\d+`)
- Uu tien 5 chu so, roi 4 chu so

**Confidence calculation:**
- reading bat dau bang '000' -> 0.9
- reading 5-7 ky tu -> 0.7
- Con lai -> 0.3

---

## 6. IMPORTS CAN THIET

```dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/services/water_meter_ocr_service.dart';
```

---

## 7. HELPER FUNCTION

```dart
Future<File> saveBytesToTempFile(Uint8List bytes, String filename) async {
  final tempDir = await getTemporaryDirectory();
  final file = File('${tempDir.path}/$filename');
  await file.writeAsBytes(bytes);
  return file;
}
```

---

## 8. FULL SOURCE CODE (BACKUP)

```dart
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
import 'package:water_meter_sdk/models/detection_test_result.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/services/water_meter_ocr_service.dart';

class WaterMeterSdkYoloOldVersion {
  final WaterMeterOCRService _ocrService = WaterMeterOCRService();
  late YOLO yolo;

  String get modelPath {
    if (Platform.isAndroid) {
      return 'yolo11n-obb';
    } else {
      return 'yolo11n-obb';
    }
  }

  Future init() async {
    yolo = YOLO(
      modelPath: modelPath,
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

          if (points.isNotEmpty && points.length == 4
              && (boxes['confidence'] as num).toDouble() > 0.2
              && (boxes['confidence'] as num).toDouble() < 1) {
            imageBytesAfter = cropImageFromOBB(resizedImageBytes, points);
            return imageBytesAfter;
          }
        }

        detections.add({
          'class': boxes['class'],
          'confidence': (boxes['confidence'] as num).toDouble(),
          'points': points,
        });
      }
    }
    return imageBytes;
  }

  Uint8List cropImageFromOBB(Uint8List imageBytes, List<dynamic> points) {
    final image = img.decodeImage(imageBytes);
    if (image == null) throw Exception('Failed to decode image for cropping');

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

    final padding = Platform.isIOS ? 15 : 0;
    minX = math.max(0, minX - padding);
    minY = math.max(0, minY - padding);
    maxX = math.min(image.width.toDouble(), maxX + padding);
    maxY = math.min(image.height.toDouble(), maxY + padding);

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
```

