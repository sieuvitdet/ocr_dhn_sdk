import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:image/image.dart' as img;
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/water_meter_sdk_ultralytics_yolo.dart';

class PhotoViewScreen extends StatefulWidget {
  final File imageFile;
  final WaterMeterSdkUltralyticsYolo sdk;

  const PhotoViewScreen({
    super.key,
    required this.imageFile,
    required this.sdk,
  });

  @override
  State<PhotoViewScreen> createState() => _PhotoViewScreenState();
}

class _PhotoViewScreenState extends State<PhotoViewScreen> {
  // Image rotation (45° increments)
  int _rotationTurns = 0;

  // Full image OCR via API
  bool _isFullOcrProcessing = false;
  String? _fullOcrText;
  double? _fullOcrScore;
  String? _fullOcrError;
  bool? _lastAutoOrientation;

  // YOLO detection + crop
  bool _isDetecting = false;
  WaterMeterResult? _result;
  Uint8List? _croppedImageBytes;

  // Cropped image rotation & OCR
  int _croppedRotationTurns = 0;
  bool _isCroppedProcessing = false;
  String? _croppedOcrText;
  double? _croppedOcrScore;
  String? _croppedError;

  // Connectivity for cropped OCR mode
  bool _isOnlineOcr = false;
  bool _hasInternet = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    _initConnectivity();
  }

  Future<void> _initConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    _updateConnectivity(results);
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_updateConnectivity);
  }

  void _updateConnectivity(List<ConnectivityResult> results) {
    final connected = results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet);
    if (!mounted) return;
    setState(() {
      _hasInternet = connected;
      if (!connected) _isOnlineOcr = false;
    });
  }

  /// Get image bytes with user rotation applied.
  Future<Uint8List> _getRotatedImageBytes() async {
    final bytes = await widget.imageFile.readAsBytes();
    if (_rotationTurns == 0) return bytes;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final rotated = img.copyRotate(decoded, angle: _rotationTurns * 45.0);
    return Uint8List.fromList(img.encodeJpg(rotated));
  }

  /// OCR full image via API with auto_orientation flag.
  Future<void> _runFullImageOcr({required bool autoOrientation}) async {
    if (_isFullOcrProcessing) return;
    setState(() {
      _isFullOcrProcessing = true;
      _fullOcrText = null;
      _fullOcrScore = null;
      _fullOcrError = null;
      _lastAutoOrientation = autoOrientation;
    });

    try {
      final processBytes = await _getRotatedImageBytes();
      final tempFile =
          await widget.sdk.saveBytesToTempFile(processBytes, 'full_ocr.jpg');
      final result = await GetNumberOCR()
          .ocrImage(tempFile, autoOrientation: autoOrientation);
      try {
        tempFile.deleteSync();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _isFullOcrProcessing = false;
          _fullOcrText = result?.text ?? '';
          _fullOcrScore = result?.score ?? 0.0;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFullOcrProcessing = false;
          _fullOcrError = e.toString();
        });
      }
    }
  }

  /// Run YOLO detection to crop water meter region.
  Future<void> _processImage() async {
    if (_isDetecting) return;
    setState(() {
      _isDetecting = true;
      _croppedImageBytes = null;
      _result = null;
      _croppedRotationTurns = 0;
      _croppedOcrText = null;
      _croppedOcrScore = null;
      _croppedError = null;
    });

    try {
      final bytes = await _getRotatedImageBytes();
      final result = await widget.sdk.processImage(bytes, isOnline: false);
      if (mounted) {
        setState(() {
          _isDetecting = false;
          _result = result;
          _croppedImageBytes = result.imageBytes;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDetecting = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  /// OCR on cropped image (local or online).
  Future<void> _runOcrOnCropped() async {
    final croppedBytes = _croppedImageBytes;
    if (croppedBytes == null) return;

    setState(() {
      _isCroppedProcessing = true;
      _croppedOcrText = null;
      _croppedOcrScore = null;
      _croppedError = null;
    });

    try {
      Uint8List processBytes = croppedBytes;
      if (_croppedRotationTurns != 0) {
        final decoded = img.decodeImage(croppedBytes);
        if (decoded != null) {
          final rotated =
              img.copyRotate(decoded, angle: _croppedRotationTurns * 45.0);
          processBytes = Uint8List.fromList(img.encodeJpg(rotated));
        }
      }

      if (_isOnlineOcr) {
        final tempFile = await widget.sdk
            .saveBytesToTempFile(processBytes, 'cropped_ocr.jpg');
        final apiResult = await GetNumberOCR().ocrImage(tempFile);
        try {
          tempFile.deleteSync();
        } catch (_) {}
        if (mounted) {
          setState(() {
            _isCroppedProcessing = false;
            _croppedOcrText = apiResult?.text ?? '';
            _croppedOcrScore = apiResult?.score ?? 0.0;
          });
        }
      } else {
        final localResult = await widget.sdk.runLocalOcr(processBytes);
        if (mounted) {
          setState(() {
            _isCroppedProcessing = false;
            _croppedOcrText = localResult.reading.isNotEmpty
                ? localResult.reading
                : '';
            _croppedOcrScore = localResult.confidence;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCroppedProcessing = false;
          _croppedError = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photo View'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            // --- Full image with rotation ---
            _buildFullImageSection(),
            const SizedBox(height: 12),
            // --- Full image OCR buttons ---
            _buildFullOcrButtons(),
            // --- Full image OCR result ---
            _buildFullOcrResult(),
            const SizedBox(height: 8),
            const Divider(thickness: 2),
            const SizedBox(height: 8),
            // --- Process (YOLO detect) ---
            _buildProcessButton(),
            // --- Cropped image section ---
            if (_croppedImageBytes != null) ...[
              const SizedBox(height: 12),
              _buildCroppedSection(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFullImageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Original Image:',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Transform.rotate(
              angle: _rotationTurns * math.pi / 4,
              child: Image.file(
                widget.imageFile,
                fit: BoxFit.contain,
                width: double.infinity,
                height: 350,
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () =>
                setState(() => _rotationTurns = (_rotationTurns + 1) % 8),
            icon: const Icon(Icons.rotate_right, size: 18),
            label: Text('Rotate 45° (${_rotationTurns * 45}°)'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.orange,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFullOcrButtons() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isFullOcrProcessing
                ? null
                : () => _runFullImageOcr(autoOrientation: false),
            icon: Icon(_isFullOcrProcessing
                ? Icons.hourglass_empty
                : Icons.text_fields),
            label: const Text('OCR Original'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _isFullOcrProcessing
                ? null
                : () => _runFullImageOcr(autoOrientation: true),
            icon: Icon(_isFullOcrProcessing
                ? Icons.hourglass_empty
                : Icons.auto_fix_high),
            label: const Text('OCR Auto Orient'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFullOcrResult() {
    return Column(
      children: [
        if (_isFullOcrProcessing)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_fullOcrError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Error: $_fullOcrError',
                style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
          ),
        if (_fullOcrText != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'OCR${_lastAutoOrientation == true ? " (Auto Orient)" : ""}: '
                    '${_fullOcrText!.isNotEmpty ? _fullOcrText! : "No reading"}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue.shade900,
                    ),
                  ),
                  if (_fullOcrScore != null)
                    Text(
                      'Score: ${(_fullOcrScore! * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildProcessButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isDetecting ? null : _processImage,
        icon: _isDetecting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.analytics),
        label: Text(_isDetecting ? 'Detecting...' : 'Detect Water Meter'),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          backgroundColor: Colors.teal,
          foregroundColor: Colors.white,
        ),
      ),
    );
  }

  Widget _buildCroppedSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Cropped Image:',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 4),
        Container(
          constraints: const BoxConstraints(maxHeight: 250),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Transform.rotate(
              angle: _croppedRotationTurns * math.pi / 4,
              child: Image.memory(_croppedImageBytes!, fit: BoxFit.contain),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => setState(
              () => _croppedRotationTurns = (_croppedRotationTurns + 1) % 8,
            ),
            icon: const Icon(Icons.rotate_right, size: 18),
            label: const Text('Rotate 45°'),
            style: TextButton.styleFrom(
              foregroundColor: Colors.orange,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
        ),
        // Cropped OCR controls
        Row(
          children: [
            Icon(
              _hasInternet ? Icons.wifi : Icons.wifi_off,
              size: 16,
              color: _hasInternet ? Colors.green : Colors.red,
            ),
            const SizedBox(width: 4),
            Text(
              _isOnlineOcr ? 'Online' : 'Local',
              style: const TextStyle(fontSize: 13),
            ),
            Switch(
              value: _isOnlineOcr,
              onChanged: _hasInternet
                  ? (v) => setState(() => _isOnlineOcr = v)
                  : null,
              activeTrackColor: Colors.orange.shade200,
              activeThumbColor: Colors.orange,
            ),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isCroppedProcessing ? null : _runOcrOnCropped,
                icon: Icon(_isCroppedProcessing
                    ? Icons.hourglass_empty
                    : _isOnlineOcr
                        ? Icons.cloud_upload
                        : Icons.offline_bolt),
                label: Text(_isCroppedProcessing
                    ? 'Processing...'
                    : _isOnlineOcr
                        ? 'OCR Online'
                        : 'OCR Local'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor:
                      _isOnlineOcr ? Colors.orange : Colors.teal,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
        if (_croppedError != null) ...[
          const SizedBox(height: 8),
          Text('Error: $_croppedError',
              style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
        ],
        if (_croppedOcrText != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cropped OCR: ${_croppedOcrText!.isNotEmpty ? _croppedOcrText! : "No reading"}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade900,
                  ),
                ),
                if (_croppedOcrScore != null)
                  Text(
                    'Score: ${(_croppedOcrScore! * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
        // Show YOLO detection result info
        if (_result != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Detection Result',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade800,
                  ),
                ),
                Text(
                  'Reading: ${_result!.reading.isNotEmpty ? _result!.reading : "N/A"}',
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  'Confidence: ${(_result!.confidence * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 12),
                ),
                if (_result!.rawOcrText != null &&
                    _result!.rawOcrText!.isNotEmpty)
                  Text(
                    'Raw: ${_result!.rawOcrText}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                if (_result!.candidates.length > 1) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Candidates (${_result!.candidates.length}):',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade700),
                  ),
                  ..._result!.candidates.asMap().entries.map((entry) {
                    final i = entry.key;
                    final c = entry.value;
                    return Text(
                      '  #${i + 1}: "${c.text}" (${(c.confidence * 100).toStringAsFixed(1)}%)${i == 0 ? " *best" : ""}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: i == 0
                            ? Colors.green.shade800
                            : Colors.grey.shade700,
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
