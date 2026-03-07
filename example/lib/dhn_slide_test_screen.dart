import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/water_meter_sdk_ultralytics_yolo.dart';

class DhnSlideTestScreen extends StatefulWidget {
  const DhnSlideTestScreen({super.key});

  @override
  State<DhnSlideTestScreen> createState() => _DhnSlideTestScreenState();
}

class _DhnSlideTestScreenState extends State<DhnSlideTestScreen> {
  final _sdk = WaterMeterSdkUltralyticsYolo();
  bool _initialized = false;
  List<String> _assetPaths = [];
  bool _loadingAssets = true;

  late PageController _pageController;
  int _currentPage = 0;

  // Cache results per index
  final Map<int, _SlideResult> _results = {};
  // Rotation per slide (steps of 45°, 0-7)
  final Map<int, int> _rotations = {};
  // Rotation for cropped image per slide (steps of 45°, 0-7)
  final Map<int, int> _croppedRotations = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _initSdk();
    _loadAssetList();
  }

  Future<void> _initSdk() async {
    try {
      await _sdk.init();
      if (mounted) setState(() => _initialized = true);
    } catch (e) {
      debugPrint('SDK init error: $e');
    }
  }

  Future<void> _loadAssetList() async {
    try {
      final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final allAssets = assetManifest.listAssets();
      final paths = allAssets
          .where((k) => k.startsWith('assets/test_images/10/'))
          .where((k) => k.endsWith('.jpg') || k.endsWith('.png') || k.endsWith('.jpeg'))
          .toList()
        ..sort();

      if (mounted) {
        setState(() {
          _assetPaths = paths;
          _loadingAssets = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading asset manifest: $e');
      if (mounted) setState(() => _loadingAssets = false);
    }
  }

  Future<void> _runOcrOnline(int index) async {
    if (!_initialized || index >= _assetPaths.length) return;

    // Mark as processing
    setState(() {
      _results[index] = _SlideResult(isProcessing: true);
    });

    try {
      final data = await rootBundle.load(_assetPaths[index]);
      final bytes = data.buffer.asUint8List();

      // Rotate bytes if user has rotated the image
      final turns = _rotations[index] ?? 0;
      Uint8List processBytes = bytes;
      if (turns != 0) {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          final rotated = img.copyRotate(decoded, angle: turns * 45.0);
          processBytes = Uint8List.fromList(img.encodeJpg(rotated));
        }
      }

      final result = await _sdk.processImage(processBytes, isOnline: true);

      if (mounted) {
        setState(() {
          _results[index] = _SlideResult(
            imageBytes: bytes,
            ocrResult: result,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _results[index] = _SlideResult(
            error: e.toString(),
          );
        });
      }
    }
  }

  Future<void> _runOcrOnlineCropped(int index) async {
    final croppedBytes = _results[index]?.ocrResult?.imageBytes;
    if (croppedBytes == null) return;

    setState(() {
      _results[index] = (_results[index] ?? _SlideResult()).copyWith(
        isCroppedProcessing: true,
        croppedOcrText: null,
        croppedOcrScore: null,
        croppedError: null,
      );
    });

    try {
      final turns = _croppedRotations[index] ?? 0;
      Uint8List processBytes = croppedBytes;
      if (turns != 0) {
        final decoded = img.decodeImage(croppedBytes);
        if (decoded != null) {
          // Apply single rotation at total angle to avoid compounding canvas expansion
          final rotated = img.copyRotate(decoded, angle: turns * 45.0);
          processBytes = Uint8List.fromList(img.encodeJpg(rotated));
        }
      }

      final tempFile = await _sdk.saveBytesToTempFile(processBytes, 'cropped_ocr_$index.jpg');
      final apiResult = await GetNumberOCR().ocrImage(tempFile);
      try { tempFile.deleteSync(); } catch (_) {}

      if (mounted) {
        setState(() {
          _results[index] = (_results[index] ?? _SlideResult()).copyWith(
            isCroppedProcessing: false,
            croppedOcrText: apiResult?.text ?? '',
            croppedOcrScore: apiResult?.score ?? 0.0,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _results[index] = (_results[index] ?? _SlideResult()).copyWith(
            isCroppedProcessing: false,
            croppedError: e.toString(),
          );
        });
      }
    }
  }

  void _goToPage(int page) {
    if (page < 0 || page >= _assetPaths.length) return;
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    _sdk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _loadingAssets
              ? 'Loading...'
              : 'DHN Test (${_currentPage + 1}/${_assetPaths.length})',
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // Jump to specific image
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Jump to image',
            onPressed: _assetPaths.isEmpty ? null : _showJumpDialog,
          ),
        ],
      ),
      body: _loadingAssets
          ? const Center(child: CircularProgressIndicator())
          : _assetPaths.isEmpty
              ? const Center(child: Text('No images found'))
              : Column(
                  children: [
                    Expanded(
                      child: PageView.builder(
                        controller: _pageController,
                        itemCount: _assetPaths.length,
                        onPageChanged: (page) {
                          setState(() => _currentPage = page);
                        },
                        itemBuilder: (context, index) {
                          return _SlidePage(
                            assetPath: _assetPaths[index],
                            index: index,
                            result: _results[index],
                            initialized: _initialized,
                            rotationTurns: _rotations[index] ?? 0,
                            croppedRotationTurns: _croppedRotations[index] ?? 0,
                            onRotate: () => setState(
                              () => _rotations[index] = ((_rotations[index] ?? 0) + 1) % 8,
                            ),
                            onRotateCropped: () => setState(
                              () => _croppedRotations[index] = ((_croppedRotations[index] ?? 0) + 1) % 8,
                            ),
                            onRunOcr: () => _runOcrOnline(index),
                            onRunOcrCropped: () => _runOcrOnlineCropped(index),
                          );
                        },
                      ),
                    ),
                    // Bottom navigation bar
                    _buildBottomBar(),
                  ],
                ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous),
              onPressed: _currentPage > 0 ? () => _goToPage(0) : null,
            ),
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: _currentPage > 0
                  ? () => _goToPage(_currentPage - 1)
                  : null,
            ),
            Expanded(
              child: LinearProgressIndicator(
                value: _assetPaths.isEmpty
                    ? 0
                    : (_currentPage + 1) / _assetPaths.length,
                backgroundColor: Colors.grey.shade300,
                valueColor: const AlwaysStoppedAnimation(Colors.teal),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: _currentPage < _assetPaths.length - 1
                  ? () => _goToPage(_currentPage + 1)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next),
              onPressed: _currentPage < _assetPaths.length - 1
                  ? () => _goToPage(_assetPaths.length - 1)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  void _showJumpDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Jump to image'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: '1 - ${_assetPaths.length}',
            labelText: 'Image number',
          ),
          autofocus: true,
          onSubmitted: (value) {
            final page = int.tryParse(value);
            if (page != null && page >= 1 && page <= _assetPaths.length) {
              Navigator.pop(ctx);
              _goToPage(page - 1);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final page = int.tryParse(controller.text);
              if (page != null && page >= 1 && page <= _assetPaths.length) {
                Navigator.pop(ctx);
                _goToPage(page - 1);
              }
            },
            child: const Text('Go'),
          ),
        ],
      ),
    );
  }
}

// --- Slide Result Model ---

class _SlideResult {
  final bool isProcessing;
  final Uint8List? imageBytes;
  final WaterMeterResult? ocrResult;
  final String? error;
  final bool isCroppedProcessing;
  final String? croppedOcrText;
  final double? croppedOcrScore;
  final String? croppedError;

  _SlideResult({
    this.isProcessing = false,
    this.imageBytes,
    this.ocrResult,
    this.error,
    this.isCroppedProcessing = false,
    this.croppedOcrText,
    this.croppedOcrScore,
    this.croppedError,
  });

  _SlideResult copyWith({
    bool? isProcessing,
    Uint8List? imageBytes,
    WaterMeterResult? ocrResult,
    String? error,
    bool? isCroppedProcessing,
    String? croppedOcrText,
    double? croppedOcrScore,
    String? croppedError,
  }) =>
      _SlideResult(
        isProcessing: isProcessing ?? this.isProcessing,
        imageBytes: imageBytes ?? this.imageBytes,
        ocrResult: ocrResult ?? this.ocrResult,
        error: error ?? this.error,
        isCroppedProcessing: isCroppedProcessing ?? this.isCroppedProcessing,
        croppedOcrText: croppedOcrText ?? this.croppedOcrText,
        croppedOcrScore: croppedOcrScore ?? this.croppedOcrScore,
        croppedError: croppedError ?? this.croppedError,
      );
}

// --- Individual Slide Page ---

class _SlidePage extends StatelessWidget {
  final String assetPath;
  final int index;
  final _SlideResult? result;
  final bool initialized;
  final int rotationTurns;
  final int croppedRotationTurns;
  final VoidCallback onRotate;
  final VoidCallback onRotateCropped;
  final VoidCallback onRunOcr;
  final VoidCallback onRunOcrCropped;

  const _SlidePage({
    required this.assetPath,
    required this.index,
    required this.result,
    required this.initialized,
    required this.rotationTurns,
    required this.croppedRotationTurns,
    required this.onRotate,
    required this.onRotateCropped,
    required this.onRunOcr,
    required this.onRunOcrCropped,
  });

  @override
  Widget build(BuildContext context) {

    final fileName = assetPath.split('/').last;
    final isProcessing = result?.isProcessing ?? false;
    final isCroppedProcessing = result?.isCroppedProcessing ?? false;
    final ocrResult = result?.ocrResult;
    final error = result?.error;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // File name
          Text(
            '#${index + 1}: $fileName',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),

          // Original image from asset
          Container(
            constraints: const BoxConstraints(maxHeight: 300),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Transform.rotate(
                angle: rotationTurns * math.pi / 4,
                child: Image.asset(assetPath, fit: BoxFit.contain),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onRotate,
              icon: const Icon(Icons.rotate_right, size: 18),
              label: const Text('Xoay 45°'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.teal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ),
          ),

          // Run OCR button
          ElevatedButton.icon(
            onPressed: !initialized || isProcessing ? null : onRunOcr,
            icon: Icon(isProcessing ? Icons.hourglass_empty : Icons.cloud_upload),
            label: Text(
              isProcessing
                  ? 'Processing...'
                  : !initialized
                      ? 'Initializing SDK...'
                      : ocrResult != null
                          ? 'Re-run OCR Online'
                          : 'Run OCR Online',
            ),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
          ),

          if (isProcessing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),

          // Error
          if (error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Text(
                'Error: $error',
                style: TextStyle(color: Colors.red.shade800),
              ),
            ),
          ],

          // OCR Result
          if (ocrResult != null) ...[
            const SizedBox(height: 12),

            // Cropped/processed image
            if (ocrResult.imageBytes != null) ...[
              const Text('Cropped Image:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Transform.rotate(
                    angle: croppedRotationTurns * math.pi / 4,
                    child: Image.memory(ocrResult.imageBytes!, fit: BoxFit.contain),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onRotateCropped,
                  icon: const Icon(Icons.rotate_right, size: 18),
                  label: const Text('Xoay 45°'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.orange,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: isCroppedProcessing ? null : onRunOcrCropped,
                icon: Icon(isCroppedProcessing ? Icons.hourglass_empty : Icons.cloud_upload),
                label: Text(isCroppedProcessing ? 'Processing...' : 'OCR Online ảnh Cropped'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
              ),
              if (result?.croppedError != null) ...[
                const SizedBox(height: 8),
                Text('Error: ${result!.croppedError}',
                    style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
              ],
              if (result?.croppedOcrText != null) ...[
                const SizedBox(height: 8),
                Container(
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
                        'Cropped OCR: ${result!.croppedOcrText!.isNotEmpty ? result!.croppedOcrText! : "No reading"}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900,
                        ),
                      ),
                      if (result!.croppedOcrScore != null)
                        Text(
                          'Score: ${(result!.croppedOcrScore! * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
            ],

            // Reading result
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ocrResult.reading.isNotEmpty
                    ? Colors.green.shade50
                    : Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: ocrResult.reading.isNotEmpty
                      ? Colors.green.shade200
                      : Colors.orange.shade200,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reading: ${ocrResult.reading.isNotEmpty ? ocrResult.reading : "No reading"}',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: ocrResult.reading.isNotEmpty
                          ? Colors.green.shade800
                          : Colors.orange.shade800,
                    ),
                  ),
                  Text(
                    'Confidence: ${(ocrResult.confidence * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (ocrResult.rawOcrText != null &&
                      ocrResult.rawOcrText!.isNotEmpty)
                    Text(
                      'Raw OCR: ${ocrResult.rawOcrText}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
