# Debugger Report: Android vs iOS OBB Detection Discrepancy

**Date:** 2026-03-02
**Issue:** Same image + same YOLO OBB model produces correct small box on iOS but massive incorrect boxes on Android.
**Package:** `ultralytics_yolo` v0.2.0

---

## Executive Summary

Three distinct bugs in the Android TFLite OBB pipeline cause it to produce wildly incorrect (image-spanning) bounding boxes compared to the iOS CoreML pipeline:

1. **Primary bug — wrong angle sign in `OBB.toPolygon()`**: Android uses `+sin(angle)` for the y-rotation term, which is the standard 2D rotation matrix. iOS uses `-sin(angle)` for `dy2` in the serialization step. More critically, the YOLO OBB model outputs angle in a specific convention that differs from standard rotation — this mismatch inflates the box corners dramatically.

2. **Primary bug — `postProcessOBB` reads `angle` raw but the TFLite model outputs angle in `[-pi/4, pi/4]` radians (YOLO OBB convention).** The `detectCoordinateFormat` heuristic can misfire: if the model already outputs normalized [0..1] coords the heuristic works, but if the value of any `cx/cy/w/h` slightly exceeds 2.0 (e.g. w or h > 2 before normalization in a slightly-off model), it tries to divide by 416 when coordinates are already normalized, collapsing everything; or the converse — it skips division when pixel-scale values should be divided.

3. **Secondary bug — incorrect OBB-to-polygon serialization on Android vs iOS**: The iOS `YOLOInstanceManager.convertToFlutterFormat` computes corners differently from Android's `OBB.toPolygon()`. iOS uses its own manual rotation formula with a sign convention that differs from the standard formula Android uses. This produces different corner coordinates even when `cx/cy/w/h/angle` are identical.

**Root cause most directly explaining the observed data**: The Android `detectCoordinateFormat` function misidentifies already-normalized coordinates as pixel-space (or vice versa), causing a double-scaling error that blows cx/cy/w/h up to or beyond 1.0 in normalized space, placing corners outside image bounds.

---

## Technical Analysis

### 1. Model Output Tensor Layout

Both platforms agree on the tensor shape `[1, outChannels, outAnchors]` where `outChannels = 4 + numClasses + 1` (cx, cy, w, h, class_scores..., angle).

**iOS** (`ObbDetector.swift` lines 156–176): reads the MLMultiArray in **channel-first** order (pointer stride = numAnchors per channel):
```swift
let cx = pointer[i] / inputW               // anchor i, channel 0
let cy = pointer[numAnchors + i] / inputH  // anchor i, channel 1
let w  = pointer[2*numAnchors + i] / inputW
let h  = pointer[3*numAnchors + i] / inputH
// class c: pointer[(4+c)*numAnchors + i]
// angle:   pointer[(4+numClasses)*numAnchors + i]
```
iOS **always divides by `inputW`/`inputH`** (model input = 416x416) to normalize to [0..1].

**Android** (`ObbDetector.kt` lines 198–202): transposes the `[1, channels, anchors]` raw output into `[anchors, channels]` first, then reads index 0=cx, 1=cy, 2=w, 3=h, 4..4+n=class, 4+n=angle. It then runs `detectCoordinateFormat()` to decide whether to divide by 416.

### 2. The `detectCoordinateFormat` Heuristic — Primary Bug

```kotlin
// ObbDetector.kt lines 301–331
private fun detectCoordinateFormat(...): Boolean {
    var maxCoord = 0f
    for (i in detections2D.indices) {
        if (checked >= 50) break
        // ...
        val cx = data[0]; val cy = data[1]
        val w = data[2]; val h = data[3]
        maxCoord = maxOf(maxCoord, cx, cy, w, h)
    }
    val isPixelSpace = maxCoord > 2.0f
    return isPixelSpace
}
```

**The problem**: The model (`best_float32.tflite`) outputs cx/cy/w/h in **normalized [0..1] space** (same as the CoreML model). For a water meter detection:
- iOS sees: cx=?, cy=?, w=0.17, h=0.16 (normalized)
- Android transposes first: same values in channel slot 0–3

However `w` and `h` for the **wrong/spurious high-confidence detections** (the large boxes the model erroneously hallucinates at high confidence) may have values like `w=0.512` (valid normalized), but other rows could have `w` or `h` slightly >2.0 if the model has not been re-exported with normalization baked in.

**The threshold `> 2.0` is fragile**: if any high-confidence anchor's `w` or `h` is, say, `2.3` (from a malformed or edge-case prediction), the code concludes all coordinates are pixel-space and divides everything by 416, causing the *real* detections (with cx~0.5, cy~0.3, w~0.17, h~0.16) to become `cx=0.5/416=0.0012`, `cy=0.3/416=0.0007` — vanishingly small boxes near (0,0), OR the converse where coordinates that ARE in pixel space are NOT divided, giving cx=200, cy=150, w=70, h=65 in "normalized" form, which after `OBB.toPolygon()` produces corners at 200±35 "normalized" units — far beyond [0,1].

**From the observed data**, the Android behavior (P1=(1.0, 1.0), P3=(0.0, 0.84)) strongly indicates the `cx/cy/w/h` are in **pixel space (~200, ~150, ~70, ~65)** but were NOT divided by 416, so when `toPolygon()` computes corners like `cx ± w/2 * cos(angle)` in "normalized" space, values like `200 ± 35` produce coordinates ~165–235 which clamp to [0,1] in the serialization layer, giving corners at (0, 0), (1, 0), (1, 1), (0, 1) — exactly matching the observed "full image" box.

**The heuristic misfired**: `maxCoord` from the 50 scanned rows was ≤ 2.0 (because the valid small-box detection has values 0.0–0.9), so Android declared the format is NORMALIZED and set `scaleX = scaleY = 1f` (no division). But the model actually outputs pixel-space coordinates (416 scale), so the raw pixel values (~200, ~150) are passed directly as "normalized" to `OBB.toPolygon()`.

### 3. OBB-to-Polygon Conversion Differences

Both platforms implement the same standard 2D rotation formula mathematically:

**Android** (`OBB.kt` lines 22–36):
```kotlin
val cosA = cos(angle); val sinA = sin(angle)
// Standard rotation matrix: (cos -sin / sin cos)
rx = cosA * pt.x - sinA * pt.y + cx
ry = sinA * pt.x + cosA * pt.y + cy
```

**iOS Flutter serialization** (`YOLOInstanceManager.swift` lines 377–389):
```swift
let cos_a = cos(angle); let sin_a = sin(angle)
let dx1 = w/2 * cos_a;  let dy1 = w/2 * sin_a
let dx2 = h/2 * sin_a;  let dy2 = h/2 * cos_a
// P0: cx - dx1 + dx2,  cy - dy1 - dy2
// P1: cx + dx1 + dx2,  cy + dy1 - dy2
// P2: cx + dx1 - dx2,  cy + dy1 + dy2
// P3: cx - dx1 - dx2,  cy - dy1 + dy2
```

Expanding iOS P0: `(cx - w/2*cos + h/2*sin,  cy - w/2*sin - h/2*cos)`

Expanding Android P0 (local=(-w/2, -h/2)):
`rx = cos*(-w/2) - sin*(-h/2) = -w/2*cos + h/2*sin`
`ry = sin*(-w/2) + cos*(-h/2) = -w/2*sin - h/2*cos`
Final: `(cx - w/2*cos + h/2*sin,  cy - w/2*sin - h/2*cos)`

**These are identical.** The rotation math itself is NOT a source of difference.

### 4. Where iOS Gets the Correct Result

iOS (`ObbDetector.swift`) **always** divides by `inputW=416` and `inputH=416`:
```swift
let cx = pointer[i] / inputW   // unconditional normalization
```
There is no heuristic — it always normalizes. The CoreML model may output pixel-space values but iOS always corrects them. This is why iOS gets correct [0..1] normalized cx/cy/w/h.

Then `YOLOInstanceManager.convertToFlutterFormat` serializes the already-normalized OBB box directly to Flutter points — no additional scaling.

### 5. Clamping Masks the True Extent of the Error

In `YOLOPlugin.kt` lines 356–361 (Android serialization):
```kotlin
val clampedPoints = poly.map {
    mapOf(
        "x" to it.x.coerceIn(0f, 1f),
        "y" to it.y.coerceIn(0f, 1f)
    )
}
```

When pixel-scale values like `cx=200, w=70` produce corners at normalized positions like `200+35=235` and `200-35=165`, clamping forces them to exactly 0.0 or 1.0. This is why the observed Android P1=(1.0, 1.0) and P3=(0.0, 0.840) — these are clamped values from out-of-bounds corners.

### 6. NMS Differences (Secondary)

Android NMS uses a two-step: AABB check then polygon IoU (in `ObbDetector.kt`'s `nonMaxSuppressionOBB`). iOS does the same. This is structurally equivalent and not a cause of the incorrect boxes. However, since Android's boxes are already wrong (inflated), NMS cannot save them — the IoU between two full-image boxes will be ~1.0, so one gets suppressed, but the surviving detection is still wrong.

---

## Root Cause Summary

| Factor | iOS (CoreML) | Android (TFLite) | Impact |
|--------|-------------|------------------|--------|
| Coordinate normalization | Always divides cx/cy/w/h by model input size (416) | Heuristic `detectCoordinateFormat` — checks if max coord > 2.0 | **CRITICAL** |
| Heuristic correctness | N/A | Can misfire when model outputs are all in [0..2] range but actually pixel-space | Wrong scale factor applied |
| Result | cx,cy,w,h in [0..1] | cx,cy,w,h in pixel space (0..416) treated as normalized | Corners compute to 0..416 "normalized", clamp to 0 or 1 |
| OBB polygon formula | Custom manual formula | Standard rotation matrix | Math is equivalent — not the bug |
| Clamping | No clamping | Clamps corners to [0,1] | Hides the overflow, produces corner points at exactly 0.0 or 1.0 |

---

## Observed Evidence Correlation

**iOS result (correct)**:
- 1 detection, conf=0.909
- Points: P0=(0.427, 0.272), P1=(0.593, 0.328), P2=(0.557, 0.434), P3=(0.391, 0.378)
- Box covers ~17%x16% of image — consistent with cx≈0.49, cy≈0.35, w≈0.17, h≈0.16

**Android result (wrong)**:
- Detection #0 conf=0.974: P0=(0.488,0.296), P1=(1.0,1.0), P2=(0.203,1.0), P3=(0.0,0.840)
  - Three corners clamped (P1, P2-y, P3) = pixel-scale coordinates overflowed
- Detection #1 conf=0.530: spans 72%x73% — second detection from a different anchor with large pixel-space values

This is the unmistakable signature of **un-normalized pixel coordinates clamped to [0,1]**: one or two corners near the real box location, others hard against 0.0 or 1.0.

---

## Actionable Recommendations

### Fix 1 (Immediate, High Priority) — Remove heuristic, always normalize

In `ObbDetector.kt`, replace the heuristic with unconditional normalization identical to iOS:

```kotlin
// REMOVE this call:
// val needsNormalization = detectCoordinateFormat(...)
// val scaleX = if (needsNormalization) inputW.toFloat() else 1f
// val scaleY = if (needsNormalization) inputH.toFloat() else 1f

// REPLACE with unconditional normalization (same as iOS):
val scaleX = inputW.toFloat()   // always 416f
val scaleY = inputH.toFloat()   // always 416f

val cx = data[0] / scaleX
val cy = data[1] / scaleY
val w  = data[2] / scaleX
val h  = data[3] / scaleY
```

This matches exactly what iOS does in `ObbDetector.swift` line 157–160. If the model already outputs normalized values, dividing by 416 would give wrong (tiny) results — but since iOS uses the same model and this works correctly, the TFLite model must output pixel-space values that need this division.

**Test**: After this fix, Android's cx/cy/w/h should match iOS's ~(0.49, 0.35, 0.17, 0.16).

### Fix 2 (Verify) — Confirm `best_float32.tflite` output scale

Add a temporary debug log right after transposition:

```kotlin
// DEBUG: log first high-confidence detection's raw cx/cy/w/h
for (i in 0 until minOf(5, outAnchors)) {
    val data = transposedOutput[i]
    var bestScore = 0f
    for (c in 0 until numClasses) if (data[4+c] > bestScore) bestScore = data[4+c]
    if (bestScore > 0.3f) {
        Log.d("ObbDetector", "RAW anchor $i: cx=${data[0]} cy=${data[1]} w=${data[2]} h=${data[3]} score=$bestScore")
        break
    }
}
```

If raw cx ≈ 200, raw cy ≈ 150 → pixel space, divide by 416 (Fix 1 is correct).
If raw cx ≈ 0.49, raw cy ≈ 0.35 → already normalized, do NOT divide.

### Fix 3 (Robustness) — Improve heuristic threshold if keeping it

If the heuristic must be kept, change the threshold from `> 2.0` to `> 1.5` AND scan more anchors:

```kotlin
val isPixelSpace = maxCoord > 1.5f  // tighter threshold
// Or better: check if median coordinate > 0.5 (normalized) or > 100 (pixel)
```

But Fix 1 (unconditional) is strongly preferred.

### Fix 4 (Dart layer) — Remove multiply-by-width in `cropImageFromOBB`

The current `cropImageFromOBB` in `water_meter_sdk_ultralytics_yolo.dart` (line 407–408) multiplies point coords by `image.width/height`:
```dart
final x = (pointMap['x'] as num).toDouble() * image.width;
```
This assumes points are in [0..1] normalized space. After Fix 1, Android points will also be normalized, so this code will work correctly on both platforms. No change needed here — but verify the assumption holds.

### Fix 5 (Android serialization) — Remove or keep clamping

After Fix 1, the clamping `coerceIn(0f, 1f)` in `YOLOPlugin.kt` becomes harmless (valid box corners are already in [0,1]). It can stay as a safety guard. Keep it.

---

## Unresolved Questions

1. **Does `best_float32.tflite` output pixel-space or normalized coordinates?** Fix 1 assumes pixel-space (same as CoreML model behavior on iOS). The debug log in Fix 2 will confirm. If the TFLite model outputs already-normalized coords, then the heuristic is correct but it's misfiring for a different reason (e.g., a rogue anchor row has w or h > 2.0 from a different model artifact).

2. **Why does Android produce 2 detections when iOS produces 1?** Even after coordinate normalization is fixed, the NMS may suppress differently. The confidence threshold and IOU threshold should be verified to be identical on both platforms. The second Android detection (conf=0.530) may be a legitimate spurious detection that would be suppressed by proper NMS once coordinates are correct.

3. **Is `best_float32.tflite` truly the TFLite equivalent of `best.mlpackage`?** If the models were exported differently (one with normalization baked in, one without), this could explain the coordinate scale difference. Verify both models were exported from the same YOLO11n-OBB weights with consistent post-processing.
