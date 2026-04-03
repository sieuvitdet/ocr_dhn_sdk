import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:water_meter_sdk/api/get_number_ocr.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/water_meter_sdk_ultralytics_yolo.dart';
import 'package:path_provider/path_provider.dart';
import 'package:water_meter_sdk_example/dhn_slide_test_screen.dart';
import 'package:water_meter_sdk_example/image_document_cache_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _sdk = WaterMeterSdkUltralyticsYolo();
  final _imagePicker = ImagePicker();
  WaterMeterResult? _onlineResult;
  WaterMeterResult? _offlineResult;
  Uint8List? _processedImageBytes;
  bool _isProcessing = false;
  File? _selectedImage;
  bool _hasPermissionPhoto = false;
  bool _hasPermissionCamera = false;

  // Original image rotation
  int _originalRotationTurns = 0;

  // Cropped image rotation & OCR
  int _croppedRotationTurns = 0;

  // Cropped online OCR
  bool _isCroppedProcessing = false;
  String? _croppedOcrText;
  double? _croppedOcrScore;
  String? _croppedError;

  // Cropped local OCR
  bool _isCroppedLocalProcessing = false;
  String? _croppedLocalOcrText;
  double? _croppedLocalOcrScore;
  String? _croppedLocalError;

  bool _hasInternet = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    _sdk.init();
    _checkPhotoPermission();
    _checkCameraPermission();
    _initConnectivity();
  }

  Future<void> _initConnectivity() async {
    // Check current status
    final results = await Connectivity().checkConnectivity();
    _updateConnectivity(results);

    // Listen for changes
    _connectivitySub = Connectivity().onConnectivityChanged.listen(_updateConnectivity);
  }

  void _updateConnectivity(List<ConnectivityResult> results) {
    final connected = results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet);
    if (!mounted) return;
    setState(() {
      _hasInternet = connected;
    });
  }

  /// Android < 13 uses Permission.storage, Android 13+ and iOS use Permission.photos
  Permission get _photoPermission =>
      Platform.isAndroid ? Permission.storage : Permission.photos;

  Future<void> _checkPhotoPermission() async {
    final status = await _photoPermission.status;
    setState(() {
      _hasPermissionPhoto = status.isGranted || status.isLimited;
    });
  }

  Future<void> _requestPhotoPermission() async {
    final status = await _photoPermission.request();

    setState(() {
      _hasPermissionPhoto = status.isGranted || status.isLimited;
    });

    if (status.isPermanentlyDenied && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Photo Library Permission Required'),
          content: const Text('Please enable photo library access in app settings to use this feature.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() {
                  _hasPermissionPhoto = false;
                });
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await openAppSettings();
                if (!mounted) return;
                final newStatus = await _photoPermission.status;
                setState(() {
                  _hasPermissionPhoto = newStatus.isGranted || newStatus.isLimited;
                });
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _checkCameraPermission() async {
    final status = await Permission.camera.status;
    setState(() {
      _hasPermissionCamera = status.isGranted;
    });
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    setState(() {
      _hasPermissionCamera = status.isGranted;
    });

    if (status.isPermanentlyDenied && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Camera Permission Required'),
          content: const Text('Please enable camera access in app settings.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _pickImageFromCamera() async {
    if (!_hasPermissionCamera) {
      await _requestCameraPermission();
      if (!_hasPermissionCamera) return;
    }

    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        setState(() {
          _selectedImage = File(pickedFile.path);
        });
      }
    } catch (e) {
      debugPrint('Error picking image from camera: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera error: $e')),
        );
      }
    }
  }

  Future<void> _pickImageFromGallery() async {
    if (Platform.isIOS && !_hasPermissionPhoto) {
      await _requestPhotoPermission();
      if (!_hasPermissionPhoto) return;
    }

    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        setState(() {
          _selectedImage = File(pickedFile.path);
        });
      }
    } catch (e) {
      debugPrint('Error picking image from gallery: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gallery error: $e')),
        );
      }
    }
  }

  Future<void> _processImage() async {
    if (_selectedImage == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _onlineResult = null;
      _offlineResult = null;
      _processedImageBytes = null;
      _croppedRotationTurns = 0;
      _croppedOcrText = null;
      _croppedOcrScore = null;
      _croppedError = null;
    });

    try {
      var bytes = await _selectedImage!.readAsBytes();

      // Apply rotation if user has rotated the image
      if (_originalRotationTurns != 0) {
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          final rotated = img.copyRotate(decoded, angle: _originalRotationTurns * 45.0);
          bytes = Uint8List.fromList(img.encodeJpg(rotated));
        }
      }

      // Run online + offline OCR in parallel
      final results = await Future.wait([
        _sdk.processImage(bytes, isOnline: true),
        _sdk.processImage(bytes, isOnline: false),
      ]);

      if (mounted) {
        setState(() {
          _onlineResult = results[0];
          _offlineResult = results[1];
          _processedImageBytes = results[0].imageBytes ?? results[1].imageBytes;
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint('Error processing image: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Uint8List? _getRotatedCroppedBytes() {
    final croppedBytes = _onlineResult?.imageBytes ?? _offlineResult?.imageBytes;
    if (croppedBytes == null) return null;
    if (_croppedRotationTurns == 0) return croppedBytes;
    final decoded = img.decodeImage(croppedBytes);
    if (decoded == null) return croppedBytes;
    final rotated = img.copyRotate(decoded, angle: _croppedRotationTurns * 45.0);
    return Uint8List.fromList(img.encodeJpg(rotated));
  }

  Future<void> _runOcrOnlineCropped() async {
    final processBytes = _getRotatedCroppedBytes();
    if (processBytes == null) return;

    setState(() {
      _isCroppedProcessing = true;
      _croppedOcrText = null;
      _croppedOcrScore = null;
      _croppedError = null;
    });

    try {
      final tempFile = await _sdk.saveBytesToTempFile(processBytes, 'cropped_ocr.jpg');
      final apiResult = await GetNumberOCR().ocrImage(tempFile, autoOrientation: true);
      try { tempFile.deleteSync(); } catch (_) {}

      if (mounted) {
        setState(() {
          _isCroppedProcessing = false;
          _croppedOcrText = apiResult?.text ?? '';
          _croppedOcrScore = apiResult?.score ?? 0.0;
        });
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

  Future<void> _runOcrLocalCropped() async {
    final processBytes = _getRotatedCroppedBytes();
    if (processBytes == null) return;

    setState(() {
      _isCroppedLocalProcessing = true;
      _croppedLocalOcrText = null;
      _croppedLocalOcrScore = null;
      _croppedLocalError = null;
    });

    try {
      final localResult = await _sdk.runLocalOcr(processBytes);

      if (mounted) {
        setState(() {
          _isCroppedLocalProcessing = false;
          _croppedLocalOcrText = localResult.reading.isNotEmpty
              ? localResult.reading
              : '';
          _croppedLocalOcrScore = localResult.confidence;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCroppedLocalProcessing = false;
          _croppedLocalError = e.toString();
        });
      }
    }
  }

  Future<void> _saveCroppedImage() async {
    final croppedBytes = _processedImageBytes;
    if (croppedBytes == null || croppedBytes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No cropped image to save')),
        );
      }
      return;
    }

    try {
      Uint8List saveBytes = croppedBytes;
      if (_croppedRotationTurns != 0) {
        final decoded = img.decodeImage(croppedBytes);
        if (decoded != null) {
          final rotated = img.copyRotate(decoded, angle: _croppedRotationTurns * 45.0);
          saveBytes = Uint8List.fromList(img.encodeJpg(rotated, quality: 95));
        }
      }

      final onlineReading = _onlineResult?.reading;
      final localReading = _offlineResult?.reading;
      final onlineVal = (onlineReading != null && onlineReading.isNotEmpty) ? onlineReading : 'novalue';
      final localVal = (localReading != null && localReading.isNotEmpty) ? localReading : 'novalue';
      final fileName = 'online_${onlineVal}_local_$localVal.jpg';

      final docDir = await getApplicationDocumentsDirectory();
      final saveDir = Directory('${docDir.path}/cropped_cache');
      if (!saveDir.existsSync()) saveDir.createSync(recursive: true);

      File('${saveDir.path}/$fileName').writeAsBytesSync(saveBytes);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved: $fileName')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    }
  }

  Widget _buildResultCard({
    required String title,
    required WaterMeterResult result,
    required MaterialColor color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.shade50,
        border: Border.all(color: color.shade200),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color.shade800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            result.reading.isNotEmpty ? result.reading : 'No reading detected',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color.shade900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Confidence: ${(result.confidence * 100).toStringAsFixed(1)}%',
            style: TextStyle(fontSize: 14, color: color.shade700),
          ),
          if (result.rawOcrText != null && result.rawOcrText!.isNotEmpty)
            Text(
              'Raw OCR: ${result.rawOcrText}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          if (result.processedText != null && result.processedText!.isNotEmpty)
            Text(
              'Processed: ${result.processedText}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          if (result.candidates.length > 1) ...[
            const SizedBox(height: 8),
            Text(
              'Candidates (${result.candidates.length}):',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color.shade700,
              ),
            ),
            ...result.candidates.asMap().entries.map((entry) {
              final i = entry.key;
              final c = entry.value;
              return Text(
                '  #${i + 1}: "${c.text}" (${(c.confidence * 100).toStringAsFixed(1)}%)${i == 0 ? " *best" : ""}',
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: i == 0 ? Colors.green.shade800 : Colors.grey.shade700,
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _sdk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Water Meter OCR Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library),
            tooltip: 'Saved Images',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ImageDocumentCacheScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.slideshow),
            tooltip: 'DHN Slide Test',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DhnSlideTestScreen()),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            // Image display area
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _selectedImage != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Transform.rotate(
                        angle: _originalRotationTurns * math.pi / 4,
                        child: Image.file(
                          _selectedImage!,
                          fit: BoxFit.contain,
                          width: double.infinity,
                          height: 400,
                        ),
                      ),
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.image,
                            size: 64,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No image selected',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            if (_selectedImage != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => setState(
                    () => _originalRotationTurns = (_originalRotationTurns + 1) % 8,
                  ),
                  icon: const Icon(Icons.rotate_right, size: 18),
                  label: const Text('Rotate 45°'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.blue,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // Cropped image with rotation & OCR
            if (_processedImageBytes != null) ...[
              Row(
                children: [
                  const Text('Cropped Image:',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  const Spacer(),
                  IconButton(
                    onPressed: _saveCroppedImage,
                    icon: const Icon(Icons.save_alt, size: 20),
                    tooltip: 'Save to document',
                    color: Colors.teal,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
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
                    child: Image.memory(_processedImageBytes!, fit: BoxFit.contain),
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
                  label: const Text('Xoay 45°'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.orange,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isCroppedProcessing ? null : _runOcrOnlineCropped,
                      icon: Icon(_isCroppedProcessing ? Icons.hourglass_empty : Icons.cloud_upload),
                      label: Text(_isCroppedProcessing ? '...' : 'OCR Online'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isCroppedLocalProcessing ? null : _runOcrLocalCropped,
                      icon: Icon(_isCroppedLocalProcessing ? Icons.hourglass_empty : Icons.offline_bolt),
                      label: Text(_isCroppedLocalProcessing ? '...' : 'OCR Local'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: Colors.indigo,
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
                        'Cropped Online: ${_croppedOcrText!.isNotEmpty ? _croppedOcrText! : "No reading"}',
                        style: TextStyle(
                          fontSize: 16,
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
              if (_croppedLocalError != null) ...[
                const SizedBox(height: 8),
                Text('Error: $_croppedLocalError',
                    style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
              ],
              if (_croppedLocalOcrText != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.indigo.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Cropped Local: ${_croppedLocalOcrText!.isNotEmpty ? _croppedLocalOcrText! : "No reading"}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo.shade900,
                        ),
                      ),
                      if (_croppedLocalOcrScore != null)
                        Text(
                          'Score: ${(_croppedLocalOcrScore! * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
            ],

            // Pick image buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pickImageFromGallery,
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Gallery'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pickImageFromCamera,
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Camera'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Process button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isProcessing || _selectedImage == null
                    ? null
                    : _processImage,
                icon: const Icon(Icons.analytics),
                label: Text(_isProcessing ? 'Processing...' : 'Process Water Meter'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Processing indicator
            if (_isProcessing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              ),

            // Online result
            if (_onlineResult != null)
              _buildResultCard(
                title: 'Online OCR',
                result: _onlineResult!,
                color: Colors.blue,
              ),

            if (_onlineResult != null && _offlineResult != null)
              const SizedBox(height: 12),

            // Offline result
            if (_offlineResult != null)
              _buildResultCard(
                title: 'Local OCR',
                result: _offlineResult!,
                color: Colors.teal,
              ),
          ],
        ),
      ),
    );
  }
}
