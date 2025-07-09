# Model Files Directory for Android

Place your model files here:

## Required Files:
- `model.onnx` - Water meter classification model
- `det_model.nb` - PaddleOCR text detection model  
- `rec_model.nb` - PaddleOCR text recognition model

## Alternative File Names:
- `ch_ppocr_mobile_v2.0_det_slim_opt.nb` - Detection model
- `ch_ppocr_mobile_v2.0_rec_slim_opt.nb` - Recognition model
- `ch_ppocr_mobile_v2.0_cls_slim_opt.nb` - Classification model

## Instructions:
1. Download the model files from your training pipeline
2. Place them in this directory
3. They will be automatically included in the Android APK assets
