// import 'dart:io';
// import 'dart:math';
// import 'package:flutter/material.dart';
// import 'package:ultralytics_yolo/models/yolo_task.dart';
// import 'package:ultralytics_yolo/yolo_view.dart';
// import 'water_meter_detector.dart';

// /// Trang camera realtime detect dong ho nuoc OBB
// class CameraOBBPage extends StatefulWidget {
//   const CameraOBBPage({super.key});

//   @override
//   State<CameraOBBPage> createState() => _CameraOBBPageState();
// }

// class _CameraOBBPageState extends State<CameraOBBPage> {
//   List<OBBDetection> _detections = [];

//   String get _modelPath {
//     if (Platform.isAndroid) {
//       return 'best_float32';
//     } else {
//       return 'best';
//     }
//   }

//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         title: const Text('Water Meter OBB'),
//         actions: [
//           if (_detections.isNotEmpty)
//             Padding(
//               padding: const EdgeInsets.only(right: 16),
//               child: Center(
//                 child: Text(
//                   '${_detections.length} found',
//                   style: const TextStyle(fontWeight: FontWeight.bold),
//                 ),
//               ),
//             ),
//         ],
//       ),
//       body: Stack(
//         children: [
//           // Camera + YOLO realtime
//           YOLOView(
//             modelPath: _modelPath,
//             task: YOLOTask.obb,
//             onResult: _onResult,
//           ),

//           // Overlay info phia duoi
//           Positioned(
//             left: 0,
//             right: 0,
//             bottom: 0,
//             child: _buildInfoPanel(),
//           ),
//         ],
//       ),
//     );
//   }

//   void _onResult(List<dynamic> results) {
//     final detections = <OBBDetection>[];
//     for (final r in results) {
//       if (r is Map<String, dynamic>) {
//         final points = (r['points'] as List<dynamic>? ?? [])
//             .map((p) =>
//                 Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()))
//             .toList();

//         detections.add(OBBDetection(
//           className: r['class'] as String? ?? 'water_meter',
//           confidence: (r['confidence'] as num?)?.toDouble() ?? 0.0,
//           angleDeg: (r['angle'] as num?)?.toDouble() ?? 0.0,
//           points: points,
//           cx: (r['x'] as num?)?.toDouble() ?? 0.0,
//           cy: (r['y'] as num?)?.toDouble() ?? 0.0,
//           width: (r['width'] as num?)?.toDouble() ?? 0.0,
//           height: (r['height'] as num?)?.toDouble() ?? 0.0,
//         ));
//       }
//     }

//     if (mounted) {
//       setState(() => _detections = detections);
//     }
//   }

//   Widget _buildInfoPanel() {
//     if (_detections.isEmpty) {
//       return Container(
//         padding: const EdgeInsets.all(16),
//         color: Colors.black54,
//         child: const Text(
//           'Dua camera vao dong ho nuoc...',
//           style: TextStyle(color: Colors.white, fontSize: 16),
//           textAlign: TextAlign.center,
//         ),
//       );
//     }

//     return Container(
//       padding: const EdgeInsets.all(16),
//       color: Colors.black87,
//       child: Column(
//         mainAxisSize: MainAxisSize.min,
//         children: _detections.map((d) {
//           return Padding(
//             padding: const EdgeInsets.symmetric(vertical: 4),
//             child: Row(
//               children: [
//                 // Confidence bar
//                 Container(
//                   width: 60,
//                   height: 24,
//                   decoration: BoxDecoration(
//                     color: _confColor(d.confidence),
//                     borderRadius: BorderRadius.circular(4),
//                   ),
//                   alignment: Alignment.center,
//                   child: Text(
//                     '${(d.confidence * 100).toStringAsFixed(0)}%',
//                     style: const TextStyle(
//                       color: Colors.white,
//                       fontWeight: FontWeight.bold,
//                       fontSize: 12,
//                     ),
//                   ),
//                 ),
//                 const SizedBox(width: 12),
//                 // Info
//                 Expanded(
//                   child: Text(
//                     '${d.className}  |  '
//                     'angle: ${d.angleDeg.toStringAsFixed(1)}°  |  '
//                     '${d.width.toInt()}x${d.height.toInt()}',
//                     style: const TextStyle(color: Colors.white, fontSize: 14),
//                   ),
//                 ),
//               ],
//             ),
//           );
//         }).toList(),
//       ),
//     );
//   }

//   Color _confColor(double conf) {
//     if (conf > 0.8) return Colors.green;
//     if (conf > 0.5) return Colors.orange;
//     return Colors.red;
//   }
// }
