# Báo cáo: Vấn đề OBB Detection với ultralytics_yolo

## Tổng quan

SDK đang sử dụng thư viện `ultralytics_yolo` để detect vùng đồng hồ nước bằng mô hình YOLO11n-obb (Oriented Bounding Box). Tuy nhiên, có sự khác biệt lớn về hiệu suất giữa iOS và Android.

## Tình trạng trên iOS ✅

**Hoạt động tốt:**
- Thư viện trả về đầy đủ thông tin OBB bao gồm **angle** (góc xoay)
- Bounding box được xác định chính xác, không bị nghiêng
- Detect chính xác vùng dãy số đồng hồ nước
- OCR đạt độ chính xác cao nhờ crop đúng vùng

## Vấn đề trên Android ❌

**Vấn đề chính:**
1. **Thiếu angle**: Thư viện `ultralytics_yolo` trên Android **KHÔNG trả về thông tin angle** của OBB
2. **Bounding box bị nghiêng**: Do không có angle, không thể xác định chính xác hướng của bounding box
3. **Không crop chính xác**: Bounding box nghiêng dẫn đến việc crop không đúng vùng dãy số
4. **OCR kém chính xác**: Do crop sai vùng, OCR không đọc được số chính xác

**Vấn đề phụ:**
- Thư viện trả về **mixed coordinate formats** (lẫn lộn normalized [0..1] và pixel coordinates >1.0)
- Phải filter thủ công để loại bỏ detection không hợp lệ
- Crop strategy phải compensate bằng cách dùng adaptive positioning (70% width × 40% height, offset 25% từ trên xuống)

## So sánh

| Tiêu chí | iOS | Android |
|----------|-----|---------|
| Angle information | ✅ Có | ❌ Không có |
| Bounding box quality | ✅ Chính xác | ❌ Bị nghiêng |
| Coordinate format | ✅ Normalized [0..1] | ⚠️ Mixed formats |
| Crop accuracy | ✅ Cao | ❌ Thấp |
| OCR accuracy | ✅ Cao | ❌ Thấp |

## Tác động

- **Độ chính xác OCR trên Android giảm đáng kể** do không crop đúng vùng dãy số
- Phải dùng các workaround (adaptive cropping) nhưng vẫn không đảm bảo độ chính xác
- Trải nghiệm người dùng không đồng nhất giữa hai platform

## Giải pháp đề xuất

### 1. Báo lỗi với maintainer của ultralytics_yolo
- Package: https://pub.dev/packages/ultralytics_yolo
- Issue: Android không trả về angle information cho OBB detection
- Request: Parity với iOS implementation

### 2. Tìm thư viện thay thế
- Cân nhắc các package YOLO khác hỗ trợ OBB tốt hơn trên Android
- Hoặc implement native code riêng cho Android bằng TensorFlow Lite

### 3. Cải thiện preprocessing (tạm thời)
- Tăng cường preprocessing trước khi crop
- Thử nghiệm với rotation correction dựa trên heuristics
- Dùng multiple crop strategies và chọn kết quả tốt nhất

### 4. Chuyển sang online mode
- Sử dụng API `https://super-agent-api.meobeo.ai/water-clock-ocr` cho Android
- Trade-off: cần internet connection nhưng độ chính xác cao hơn

## Kết luận

Vấn đề hiện tại nằm ở thư viện `ultralytics_yolo` không hỗ trợ đầy đủ OBB trên Android. Cần có action để:
1. Liên hệ với maintainer để fix bug
2. Hoặc tìm giải pháp thay thế cho Android platform
3. Trong thời gian chờ đợi, khuyến khích người dùng Android sử dụng online mode

---

**Version SDK**: 1.0.6
**Ngày báo cáo**: 2025-10-07
**File tham khảo**:
- [lib/water_meter_sdk.dart](lib/water_meter_sdk.dart) (iOS implementation)
- [lib/water_meter_sdk_ultralytics_yolo.dart](lib/water_meter_sdk_ultralytics_yolo.dart) (Android implementation)
