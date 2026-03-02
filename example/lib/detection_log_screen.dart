import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:water_meter_sdk/models/detection_test_result.dart';

class DetectionLogScreen extends StatelessWidget {
  final DetectionTestResult result;

  const DetectionLogScreen({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final logText = result.toLogText();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          switch (result.scenario) {
            YoloScenario.pubCache => 'Log: S1 (Pub Cache)',
            YoloScenario.localFork => 'Log: S2 (Local Fork)',
            YoloScenario.oldVersion => 'Log: S0 (YOLO Old Version)',
            YoloScenario.nativeObb => 'Log: S3 (Native OBB)',
          },
        ),
        backgroundColor: switch (result.scenario) {
          YoloScenario.pubCache => Colors.blue,
          YoloScenario.localFork => Colors.orange,
          YoloScenario.oldVersion => Colors.teal,
          YoloScenario.nativeObb => Colors.green,
        },
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all logs',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: logText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Log copied to clipboard!'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Scenario & timestamp
          _buildSectionCard(
            'Info',
            Colors.grey.shade100,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _infoRow('Scenario', switch (result.scenario) {
                    YoloScenario.pubCache => '1 - Pub Cache (default ultralytics_yolo)',
                    YoloScenario.localFork => '2 - Local Fork (/packages)',
                    YoloScenario.oldVersion => '0 - YOLO Old Version (yolo11n-obb)',
                    YoloScenario.nativeObb => '3 - Native OBB (TFLite method channel)',
                  }),
                _infoRow('Time', result.timestamp.toString()),
                _infoRow('Input', '${result.inputWidth}x${result.inputHeight}'),
                _infoRow('Resized', '${result.resizedWidth}x${result.resizedHeight}'),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Input image with bounding boxes
          if (result.inputImageWithBBox != null) ...[
            _buildSectionCard(
              'Input + Bounding Boxes',
              Colors.green.shade50,
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  result.inputImageWithBBox!,
                  fit: BoxFit.contain,
                  width: double.infinity,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Cropped image
          if (result.croppedImage != null) ...[
            _buildSectionCard(
              'Cropped OBB Region',
              Colors.purple.shade50,
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  result.croppedImage!,
                  fit: BoxFit.contain,
                  width: double.infinity,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // OBB Detections
          _buildSectionCard(
            'OBB Detections (${result.totalDetections})',
            Colors.blue.shade50,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: result.obbDetections.isEmpty
                  ? [const Text('No detections', style: TextStyle(color: Colors.red))]
                  : result.obbDetections.map((det) {
                      final conf = (det['confidence'] as num?)?.toDouble() ?? 0;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '[${det['index']}] ${det['class']} '
                              '${(conf * 100).toStringAsFixed(1)}%',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                                color: conf > 0.5 ? Colors.green.shade800 : Colors.orange.shade800,
                              ),
                            ),
                            if (det['isNormalized'] != null)
                              Text(
                                '  normalized=${det['isNormalized']}',
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                              ),
                            for (int j = 0; j < 4; j++)
                              if (det['P${j}_x'] != null)
                                Text(
                                  '  P$j=(${det['P${j}_x']}, ${det['P${j}_y']})',
                                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                                ),
                          ],
                        ),
                      );
                    }).toList(),
            ),
          ),

          const SizedBox(height: 12),

          // OCR Result
          _buildSectionCard(
            'OCR Result',
            Colors.amber.shade50,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.ocrReading.isNotEmpty ? result.ocrReading : 'No reading',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: result.ocrReading.isNotEmpty ? Colors.green.shade900 : Colors.red,
                  ),
                ),
                const SizedBox(height: 4),
                _infoRow('Confidence', '${(result.ocrConfidence * 100).toStringAsFixed(1)}%'),
                if (result.rawOcrText != null && result.rawOcrText!.isNotEmpty)
                  _infoRow('Raw OCR', result.rawOcrText!),
                if (result.processedText != null && result.processedText!.isNotEmpty)
                  _infoRow('Processed', result.processedText!),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Full log text (copyable)
          _buildSectionCard(
            'Full Log (tap to copy)',
            Colors.grey.shade200,
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: logText));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Log copied!')),
                );
              },
              child: SelectableText(
                logText,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionCard(String title, Color bgColor, Widget content) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          content,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}
