import os, cv2, numpy as np
from pathlib import Path
from ultralytics import YOLO
import onnxruntime as ort

# ==== SỬA 2 DÒNG NÀY ====
MODEL_PATH = "water_model_2k_obb.onnx"   # ONNX OBB
# ========================
OUT_DIR      = Path("outputs")
OBB_DIR      = OUT_DIR / "obb"


# ===== Cấu hình =====
REC_MODEL_PATH = "ocr_model.onnx"

def load_image_bgr(path: str) -> np.ndarray:
    img = cv2.imread(path, cv2.IMREAD_COLOR)  # luôn 3 kênh BGR
    if img is None:
        raise FileNotFoundError(f"Không thể đọc ảnh: {path}")
    return img

def preprocess(img_bgr: np.ndarray, target_size=(320, 320)) -> np.ndarray:
    # BGR -> RGB
    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    # Resize
    img_rgb = cv2.resize(img_rgb, target_size, interpolation=cv2.INTER_LINEAR)
    # [H,W,C] -> normalize -> [1,C,H,W], float32
    img = img_rgb.astype("float32") / 255.0
    img = np.transpose(img, (2, 0, 1))          # C,H,W
    img = np.expand_dims(img, axis=0).copy()    # 1,C,H,W (contiguous)
    return img

def get_input_info(session: ort.InferenceSession):
    inp = session.get_inputs()[0]
    name = inp.name
    shape = inp.shape  # ví dụ: [1, 3, 320, 320] hoặc [1,3,-1,-1]
    return name, shape

def infer(image_path: str, model_path: str):
    # Tạo session
    session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    input_name, input_shape = get_input_info(session)
    # Suy ra size từ shape nếu có
    # shape: [N, C, H, W] (thường là vậy). Nếu H/W động (-1) thì dùng 320.
    try:
        H = int(input_shape[2]) if (len(input_shape) == 4 and isinstance(input_shape[2], int) and input_shape[2] > 0) else 320
        W = int(input_shape[3]) if (len(input_shape) == 4 and isinstance(input_shape[3], int) and input_shape[3] > 0) else 320
    except Exception:
        H, W = 320, 320

    # Load & preprocess
    img_bgr = load_image_bgr(image_path)
    inp = preprocess(img_bgr, target_size=(W, H))

    # Chạy suy luận
    outputs = session.run(None, {input_name: inp})
    return outputs

def softmax(x, axis=-1):
    x = x - np.max(x, axis=axis, keepdims=True)
    e = np.exp(x)
    return e / np.sum(e, axis=axis, keepdims=True)

def ctc_greedy_decode(logits, charset, blank_index=0):
    """
    logits: (T, C)
    charset: list ký tự (C-1 ký tự, không gồm blank)
    blank_index: vị trí class blank trong output
    """
    probs = softmax(logits, axis=1)
    pred_ids = np.argmax(probs, axis=1)

    text_tokens, token_confs = [], []
    prev = None
    for t, cls in enumerate(pred_ids):
        if cls == blank_index:       # blank
            prev = cls
            continue
        if prev == cls:              # collapse lặp
            prev = cls
            continue
        prev = cls
        idx = cls - 1 if blank_index == 0 else cls
        if 0 <= idx < len(charset):
            text_tokens.append(charset[idx])
            token_confs.append(float(probs[t, cls]))
    text = "".join(text_tokens)
    conf = float(np.mean(token_confs)) if token_confs else 0.0
    return text, conf

def run_ocr_onnx(path):
    outs = infer(path, REC_MODEL_PATH)
    logits = outs[0]   # (1, T, C) hoặc (1, C, T)
    if logits.ndim != 3:
        raise RuntimeError(f"Shape output không hợp lệ: {logits.shape}")
    _, a, b = logits.shape
    # chuẩn hóa về (T,C)
    if b > a:  # (1,T,C)
        logits_tc = logits[0]
    else:      # (1,C,T)
        logits_tc = np.transpose(logits[0], (1,0))

    T, C = logits_tc.shape

    # Chỉ số 0 là blank, còn lại là số
    BLANK_INDEX = 0
    charset = list("0123456789")
    # đảm bảo đủ C-1 class
    if len(charset) < (C-1):
        charset += ["0"] * ((C-1)-len(charset))

    text, conf = ctc_greedy_decode(logits_tc, charset, blank_index=BLANK_INDEX)
    return text

def order_quad(pts):
    P = np.array(pts, dtype=np.float32).reshape(4,2)
    c = P.mean(0)
    ang = np.arctan2(P[:,1]-c[1], P[:,0]-c[0])
    P = P[np.argsort(ang)]  # CCW
    start = np.argmin(P.sum(1))  # top-left ~ min(x+y)
    return np.roll(P, -start, axis=0)

def rectify_crop(img_bgr, poly_xyxyxyxy):
    P = order_quad(poly_xyxyxyxy)
    w = int(max(np.linalg.norm(P[1]-P[0]), np.linalg.norm(P[2]-P[3])))
    h = int(max(np.linalg.norm(P[2]-P[1]), np.linalg.norm(P[3]-P[0])))
    w = max(w, 2); h = max(h, 2)
    dst = np.array([[0,0],[w-1,0],[w-1,h-1],[0,h-1]], dtype=np.float32)
    M = cv2.getPerspectiveTransform(P, dst)
    return cv2.warpPerspective(img_bgr, M, (w, h), flags=cv2.INTER_LINEAR)

def ocr(img_path:str):
    for d in [OUT_DIR, OBB_DIR]:
        d.mkdir(parents=True, exist_ok=True)
    assert os.path.exists(MODEL_PATH), f"Không thấy model: {MODEL_PATH}"

    # ONNX + task=obb để dùng pipeline OBB
    model  = YOLO(MODEL_PATH, task="obb")
    device = "cpu"  # onnxruntime CPU

    img = cv2.imread(str(img_path))
    if img is None:
        print(f"[SKIP] Không đọc được ảnh: {Path(img_path).name}")
        return "Không đọc được ảnh!"

    r = model.predict(
        source=str(img_path),
        imgsz=416,        # khớp imgsz khi export
        conf=0.001,       # giữ giống code gốc; có thể tăng 0.25 nếu nhiễu
        iou=0.60,
        device=device,
        save=False,
        verbose=False
    )[0]

    # Lấy polygon từ OBB
    if getattr(r, "obb", None) is None or len(r.obb) == 0:
        print("No detections.")
        return "No Detections!"

    confs = r.obb.conf
    idx   = int(confs.argmax().item())
    conf  = float(confs[idx].item())
    poly8 = r.obb.xyxyxyxy[idx].cpu().numpy()   # shape (8,)
    poly  = poly8.reshape(4,2).astype(np.float32)

    obb_crop = rectify_crop(img, poly)
    obb_file = OBB_DIR / f"{Path(img_path).stem}_top1_obb_{conf:.2f}.png"
    result = ""
    try:
        cv2.imwrite(str(obb_file), obb_crop)
        result = run_ocr_onnx(str(obb_file))
    finally:
        if obb_file.exists():
            os.remove(str(obb_file))
    return result

def main():
    IMG_DIR    = Path("test_images")
    exts = {".jpg",".jpeg",".png",".bmp",".webp"}
    imgs = sorted([p for p in IMG_DIR.iterdir() if p.suffix.lower() in exts])

    for img_path in imgs:
        result = ocr(img_path)
        print(result)

if __name__ == "__main__":
    main()
