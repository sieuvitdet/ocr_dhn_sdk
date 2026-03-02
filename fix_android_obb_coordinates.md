# Fix: Android OBB Detection Returns Wrong Bounding Boxes

## Problem

Same image, same model (`best_float32`), but Android and iOS return very different OBB detection results.

**iOS (CORRECT):** 1 detection, small accurate bounding box
```
class=meter_clock  confidence=0.9097
P0=(0.427, 0.272)  P1=(0.593, 0.328)
P2=(0.557, 0.434)  P3=(0.391, 0.378)
-> Box covers ~17% x 16% of image = correct water meter region
```

**Android (WRONG):** 2 detections, giant boxes filling entire image
```
class=meter_clock  confidence=0.974
P0=(0.488, 0.296)  P1=(1.0, 1.0)
P2=(0.203, 1.0)    P3=(0.0, 0.840)
-> Box covers nearly 100% of image = clearly wrong
```

---

## Root Cause

### Bug location
`lib/packages/ultralytics_yolo/android/src/main/kotlin/com/ultralytics/yolo/ObbDetector.kt`
Method: `postProcessOBB()` (line 238-241)

### What was wrong

The YOLO OBB model outputs coordinates in **pixel space** (0..416 for a 416x416 input).

**iOS** (`ObbDetector.swift` line 157-160) always normalizes:
```swift
let cx = pointer[i] / inputW    // e.g. 200 / 416 = 0.48
let cy = pointer[numAnchors + i] / inputH
let w  = pointer[2 * numAnchors + i] / inputW
let h  = pointer[3 * numAnchors + i] / inputH
```

**Android** (`ObbDetector.kt` line 238-241) used raw values WITHOUT normalizing:
```kotlin
val cx = data[0]   // e.g. 200.0 (pixel space, NOT normalized!)
val cy = data[1]   // e.g. 150.0
val w  = data[2]   // e.g. 70.0
val h  = data[3]   // e.g. 65.0
```

### Chain of failure

1. `OBB(cx=200, cy=150, w=70, h=65)` is created with pixel-space values
2. `OBB.toPolygon()` computes corners: `(200 +/- 35, 150 +/- 32.5)` = points like `(165, 117)` to `(235, 183)`
3. `YOLOPlugin.kt` clamps all points to `[0, 1]`:
   ```kotlin
   val clampedPoints = poly.map {
       mapOf("x" to it.x.coerceIn(0f, 1f),   // 165.0 -> 1.0
             "y" to it.y.coerceIn(0f, 1f))    // 117.0 -> 1.0
   }
   ```
4. Result: all large values become `1.0`, small values become `0.0` -> giant box

---

## Fix Applied

**File:** `lib/packages/ultralytics_yolo/android/src/main/kotlin/com/ultralytics/yolo/ObbDetector.kt`

**Before (WRONG):**
```kotlin
private fun postProcessOBB(...): List<OBBResult> {
    ...
    for (i in 0 until anchorsCount) {
        val data = detections2D[i]
        val cx = data[0]        // RAW pixel value (e.g. 200.0)
        val cy = data[1]
        val w  = data[2]
        val h  = data[3]
```

**After (FIXED):**
```kotlin
private fun postProcessOBB(...): List<OBBResult> {
    ...
    // Model outputs pixel-space coordinates (0..inputW/H), normalize to [0..1] like iOS
    val inputW = modelInputSize.first.toFloat()   // 416.0
    val inputH = modelInputSize.second.toFloat()  // 416.0

    for (i in 0 until anchorsCount) {
        val data = detections2D[i]
        val cx = data[0] / inputW   // 200.0 / 416.0 = 0.48 (normalized)
        val cy = data[1] / inputH
        val w  = data[2] / inputW
        val h  = data[3] / inputH
```

### Why this fix works

- Dividing by `inputW`/`inputH` (416) converts pixel-space coordinates to normalized `[0..1]` range
- This matches exactly what iOS does in `ObbDetector.swift`
- After normalization, `OBB.toPolygon()` computes correct small corners
- The clamping in `YOLOPlugin.kt` no longer distorts values since they're already in `[0..1]`

### Expected result after fix

Android should now return results matching iOS:
```
1 detection: class=meter_clock  confidence ~0.91
P0 ~(0.43, 0.27)  P1 ~(0.59, 0.33)
P2 ~(0.56, 0.43)  P3 ~(0.39, 0.38)
-> Small accurate bounding box around water meter
```

---

## Also Fixed: iOS Index Out of Range Crash

**File:** `lib/packages/ultralytics_yolo/ios/Classes/ObbDetector.swift` (line 54, 112)

**Problem:** `labels[result.cls]` crashes when `result.cls >= labels.count`

**Fix:** Added bounds check:
```swift
// Before:
let clsIdx = labels[result.cls]

// After:
let clsIdx = result.cls < labels.count ? labels[result.cls] : "class_\(result.cls)"
```

---

## Files Modified

| File | Change |
|------|--------|
| `lib/packages/ultralytics_yolo/android/.../ObbDetector.kt` | Normalize cx/cy/w/h by dividing by inputW/inputH |
| `lib/packages/ultralytics_yolo/ios/Classes/ObbDetector.swift` | Bounds check for labels array (2 occurrences) |
| `pubspec.yaml` | `dependency_overrides` points to `lib/packages/ultralytics_yolo` |
