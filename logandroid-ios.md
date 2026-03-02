log của iOS và của Android khi test trên cùng 1 ảnh @2.jpg  
log của iOS (Đang rất đúng) :

========== DETECTION TEST LOG ==========
Timestamp: 2026-03-02T00:37:37.478463
Scenario: 1 - Pub Cache (default)

--- IMAGE INFO ---
Input: 1020x765
Resized: 416x416

--- OBB DETECTIONS (1) ---
[0] class=meter_clock confidence=0.90966796875
    P0=(0.42661482095718384, 0.2716916501522064)
    P1=(0.5931418538093567, 0.3279746472835541)
    P2=(0.5571592450141907, 0.43443813920021057)
    P3=(0.39063215255737305, 0.3781551420688629)

--- OCR RESULT ---
Reading: 
Confidence: 0.0%

--- LOGS ---
Input image: 1020x765
Resized to: 416x416
Running YOLO predict...
Result keys: [boxes, imageSize, speed, annotatedImage, obb, detections]
Total OBB detections: 1
--- Detection #0 ---
  class=meter_clock confidence=0.9097
  points_count=4
  P0=(0.42661482095718384, 0.2716916501522064)
  P1=(0.5931418538093567, 0.3279746472835541)
  P2=(0.5571592450141907, 0.43443813920021057)
  P3=(0.39063215255737305, 0.3781551420688629)
  isNormalized=true
Drawing bbox #0 conf=0.910 normalized=true
Scenario 1: Using Android (normalized) crop logic
  Valid detection: conf=0.9097 normalized=true
  Best detection: conf=0.9097
Running OCR on cropped image...
Online OCR result: 
========================================



log của Android (Chưa đúng vị trí, bounding box to , nghiêng lệch) :

========== DETECTION TEST LOG ==========
Timestamp: 2026-03-02T00:12:31.474893
Scenario: 1 - Pub Cache (default)

--- IMAGE INFO ---
Input: 1020x765
Resized: 416x416

--- OBB DETECTIONS (2) ---
[0] class=meter_clock confidence=0.974034309387207
    P0=(0.4878571629524231, 0.2960937023162842)
    P1=(1.0, 1.0)
    P2=(0.20341509580612183, 1.0)
    P3=(0.0, 0.8397684097290039)
[1] class=meter_clock confidence=0.5302587747573853
    P0=(0.39435362815856934, 0.15872859954833984)
    P1=(0.8463302850723267, 0.42126306891441345)
    P2=(0.5750814080238342, 0.8882423639297485)
    P3=(0.12310472130775452, 0.6257078647613525)

--- OCR RESULT ---
Reading: 
Confidence: 0.0%

--- LOGS ---
Input image: 1020x765
Resized to: 416x416
Running YOLO predict...
Result keys: [boxes, annotatedImage, imageSize, obb, speed, detections]
Total OBB detections: 2
--- Detection #0 ---
  class=meter_clock confidence=0.9740
  points_count=4
  P0=(0.4878571629524231, 0.2960937023162842)
  P1=(1.0, 1.0)
  P2=(0.20341509580612183, 1.0)
  P3=(0.0, 0.8397684097290039)
  isNormalized=true
--- Detection #1 ---
  class=meter_clock confidence=0.5303
  points_count=4
  P0=(0.39435362815856934, 0.15872859954833984)
  P1=(0.8463302850723267, 0.42126306891441345)
  P2=(0.5750814080238342, 0.8882423639297485)
  P3=(0.12310472130775452, 0.6257078647613525)
  isNormalized=true
Drawing bbox #0 conf=0.974 normalized=true
Drawing bbox #1 conf=0.530 normalized=true
Scenario 1: Using Android (normalized) crop logic
  Valid detection: conf=0.9740 normalized=true
  Valid detection: conf=0.5303 normalized=true
  Best detection: conf=0.9740
Running OCR on cropped image...
Online OCR result: 
========================================