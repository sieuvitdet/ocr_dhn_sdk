import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/water_meter_sdk_ultralytics_yolo.dart';

class BatchTestScreen extends StatefulWidget {
  const BatchTestScreen({super.key});

  @override
  State<BatchTestScreen> createState() => _BatchTestScreenState();
}

class _BatchTestScreenState extends State<BatchTestScreen> {
  final _sdk = WaterMeterSdkUltralyticsYolo();
  bool _isRunning = false;
  bool _initialized = false;
  bool _isSaving = false;
  String? _savedPath;
  List<Map<String, dynamic>> _results = [];
  OcrEngine _selectedEngine = OcrEngine.paddleOcr;

  // All test images in assets/test_images/
  final _testAssets = const [
    'assets/test_images/1.jpg',
    'assets/test_images/2.jpg',
    'assets/test_images/3.jpg',
    'assets/test_images/4.jpg',
    'assets/test_images/5.jpg',
    'assets/test_images/6.jpg',
    'assets/test_images/7.jpg',
    'assets/test_images/8.jpg',
    'assets/test_images/9.jpg',
    'assets/test_images/10.jpg',
    'assets/test_images/11.jpg',
    'assets/test_images/sample.jpg',
    'assets/test_images/sample1.png',
    'assets/test_images/sample2.png',
  ];

  @override
  void initState() {
    super.initState();
    _initSdk();
  }

  Future<void> _initSdk() async {
    try {
      await _sdk.init();
      setState(() => _initialized = true);
    } catch (e) {
      debugPrint('SDK init error: $e');
    }
  }

  Future<void> _runBatchTest() async {
    if (!_initialized || _isRunning) return;

    _sdk.ocrEngine = _selectedEngine;

    setState(() {
      _isRunning = true;
      _results = [];
    });

    try {
      final results = await _sdk.testBatchOffline(_testAssets);
      if (mounted) {
        setState(() {
          _results = results;
          _isRunning = false;
        });
      }
    } catch (e) {
      debugPrint('Batch test error: $e');
      if (mounted) {
        setState(() => _isRunning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _saveCroppedImages() async {
    if (_results.isEmpty) return;
    setState(() {
      _isSaving = true;
      _savedPath = null;
    });
    try {
      final path = await WaterMeterSdkUltralyticsYolo.saveBatchCroppedImages(_results);
      if (mounted) {
        setState(() {
          _isSaving = false;
          _savedPath = path;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to: $path'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save error: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _sdk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch OBB + OCR Test'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // OCR Engine selector
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                const Text('OCR Engine: ', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('PaddleOCR'),
                  selected: _selectedEngine == OcrEngine.paddleOcr,
                  onSelected: (_) => setState(() => _selectedEngine = OcrEngine.paddleOcr),
                ),
                // const SizedBox(width: 8),
                // ChoiceChip(
                //   label: const Text('ML Kit'),
                //   selected: _selectedEngine == OcrEngine.mlKit,
                //   onSelected: (_) => setState(() => _selectedEngine = OcrEngine.mlKit),
                // ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: !_initialized || _isRunning ? null : _runBatchTest,
                icon: const Icon(Icons.play_arrow),
                label: Text(_isRunning
                    ? 'Running...'
                    : !_initialized
                        ? 'Initializing SDK...'
                        : 'Run Batch Test (${_testAssets.length} images)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ),
          // Save cropped images button
          if (_results.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _saveCroppedImages,
                  icon: Icon(_isSaving ? Icons.hourglass_empty : Icons.save_alt),
                  label: Text(_isSaving
                      ? 'Saving...'
                      : _savedPath != null
                          ? 'Saved! Tap to save again'
                          : 'Save Cropped Images'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
          if (_isRunning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          Expanded(
            child: _results.isEmpty
                ? const Center(child: Text('Press the button to run tests'))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _results.length,
                    itemBuilder: (context, index) => _ResultCard(
                      result: _results[index],
                      index: index,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatefulWidget {
  final Map<String, dynamic> result;
  final int index;

  const _ResultCard({required this.result, required this.index});

  @override
  State<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<_ResultCard> {
  bool _showLogs = false;

  @override
  Widget build(BuildContext context) {
    final name = widget.result['imageName'] as String? ?? 'unknown';
    final originalBytes = widget.result['originalImage'] as Uint8List?;
    final croppedBytes = widget.result['croppedImage'] as Uint8List?;
    final annotatedBytes = widget.result['annotatedImage'] as Uint8List?;
    final ocrResult = widget.result['ocrResult'] as WaterMeterResult;
    final logs = (widget.result['logs'] as List<dynamic>?)?.cast<String>() ?? [];

    final hasReading = ocrResult.reading.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  hasReading ? Icons.check_circle : Icons.error,
                  color: hasReading ? Colors.green : Colors.red,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '#${widget.index + 1} $name',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            const Divider(),

            // Images row: original | cropped | annotated
            SizedBox(
              height: 150,
              child: Row(
                children: [
                  if (originalBytes != null)
                    _imageColumn('Original', originalBytes),
                  if (croppedBytes != null) ...[
                    const SizedBox(width: 8),
                    _imageColumn('Cropped', croppedBytes),
                  ],
                  if (annotatedBytes != null) ...[
                    const SizedBox(width: 8),
                    _imageColumn('Annotated', annotatedBytes),
                  ],
                  // Show OCR annotated image if available
                  if (ocrResult.imageBytes != null) ...[
                    const SizedBox(width: 8),
                    _imageColumn('OCR Debug', ocrResult.imageBytes!),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 12),

            // OCR Result
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: hasReading ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: hasReading ? Colors.green.shade200 : Colors.red.shade200,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Reading: ${hasReading ? ocrResult.rawOcrText : "No reading"}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: hasReading ? Colors.green.shade800 : Colors.red.shade800,
                    ),
                  ),
                  Text(
                    'Confidence: ${(ocrResult.confidence * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (ocrResult.rawOcrText != null && ocrResult.rawOcrText!.isNotEmpty)
                    Text(
                      'Raw OCR: ${ocrResult.rawOcrText}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  // Show all beam search candidates
                  if (ocrResult.candidates.length > 1) ...[
                    const SizedBox(height: 6),
                    Text(
                      'All candidates (${ocrResult.candidates.length}):',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue.shade700,
                      ),
                    ),
                    ...ocrResult.candidates.asMap().entries.map((entry) {
                      final i = entry.key;
                      final c = entry.value;
                      final isBest = i == 0;
                      return Padding(
                        padding: const EdgeInsets.only(left: 8, top: 2),
                        child: Text(
                          '#${i + 1}: "${c.text}" (${(c.confidence * 100).toStringAsFixed(1)}%)${isBest ? " *" : ""}',
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            fontWeight: isBest ? FontWeight.bold : FontWeight.normal,
                            color: isBest ? Colors.green.shade800 : Colors.grey.shade700,
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),

            // Logs toggle
            if (logs.isNotEmpty) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => setState(() => _showLogs = !_showLogs),
                child: Row(
                  children: [
                    Icon(
                      _showLogs ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                    ),
                    Text(
                      '${_showLogs ? "Hide" : "Show"} logs (${logs.length})',
                      style: const TextStyle(fontSize: 13, color: Colors.blue),
                    ),
                  ],
                ),
              ),
              if (_showLogs)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    logs.join('\n'),
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _imageColumn(String label, Uint8List bytes) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
        ],
      ),
    );
  }
}
