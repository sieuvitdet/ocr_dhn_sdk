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
  WaterMeterResult? _result;
  Uint8List? _processedImageBytes;
  bool _isProcessing = false;
  File? _selectedImage;
  bool _hasPermissionPhoto = false;
  bool _hasPermissionCamera = false;

  // Cropped image rotation & OCR
  int _croppedRotationTurns = 0;
  bool _isCroppedProcessing = false;
  String? _croppedOcrText;
  double? _croppedOcrScore;
  String? _croppedError;

  // Online/offline OCR - auto-detected from connectivity
  bool _isOnlineOcr = false;
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
      // Auto-switch to local when no internet
      if (!connected) _isOnlineOcr = false;
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
      _result = null;
      _processedImageBytes = null;
      _croppedRotationTurns = 0;
      _croppedOcrText = null;
      _croppedOcrScore = null;
      _croppedError = null;
    });

    try {
      final bytes = await _selectedImage!.readAsBytes();
      final result = await _sdk.processImage(bytes, isOnline: false);

      if (mounted) {
        setState(() {
          _result = result;
          _processedImageBytes = result.imageBytes;
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

  Future<void> _runOcrOnCropped() async {
    final croppedBytes = _result?.imageBytes;
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
          final rotated = img.copyRotate(decoded, angle: _croppedRotationTurns * 45.0);
          processBytes = Uint8List.fromList(img.encodeJpg(rotated));
        }
      }

      if (_isOnlineOcr) {
        // Online OCR via API
        final tempFile = await _sdk.saveBytesToTempFile(processBytes, 'cropped_ocr.jpg');
        final apiResult = await GetNumberOCR().ocrImage(tempFile);
        try { tempFile.deleteSync(); } catch (_) {}

        if (mounted) {
          setState(() {
            _isCroppedProcessing = false;
            _croppedOcrText = apiResult?.text ?? '';
            _croppedOcrScore = apiResult?.score ?? 0.0;
          });
        }
      } else {
        // Local OCR (PaddleOCR / ML Kit)
        final localResult = await _sdk.runLocalOcr(processBytes);

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
          // IconButton(
          //   icon: const Icon(Icons.science),
          //   tooltip: 'Batch Test',
          //   onPressed: () {
          //     Navigator.push(
          //       context,
          //       MaterialPageRoute(builder: (_) => const BatchTestScreen()),
          //     );
          //   },
          // ),
          // IconButton(
          //   icon: const Icon(Icons.slideshow),
          //   tooltip: 'DHN Slide Test',
          //   onPressed: () {
          //     Navigator.push(
          //       context,
          //       MaterialPageRoute(builder: (_) => const DhnSlideTestScreen()),
          //     );
          //   },
          // ),
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
                      child: Image.file(
                        _selectedImage!,
                        fit: BoxFit.contain,
                        width: double.infinity,
                        height: 400,
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

            const SizedBox(height: 16),

            // Cropped image with rotation & OCR
            if (_processedImageBytes != null) ...[
              const Text('Cropped Image:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
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
                    // Disable switch when no internet - can only be local
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
                          : _isOnlineOcr ? Icons.cloud_upload : Icons.offline_bolt),
                      label: Text(_isCroppedProcessing
                          ? 'Processing...'
                          : _isOnlineOcr ? 'OCR Online' : 'OCR Local'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: _isOnlineOcr ? Colors.orange : Colors.teal,
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

            // Result display
            if (_result != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  border: Border.all(color: Colors.blue.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Water Meter Reading',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _result!.reading.isNotEmpty
                          ? _result!.reading
                          : 'No reading detected',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Confidence: ${(_result!.confidence * 100).toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 14, color: Colors.blue.shade700),
                    ),
                    if (_result!.rawOcrText != null && _result!.rawOcrText!.isNotEmpty)
                      Text(
                        'Raw OCR Text: ${_result!.rawOcrText}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    if (_result!.processedText != null && _result!.processedText!.isNotEmpty)
                      Text(
                        'Processed Text: ${_result!.processedText}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    // Show all beam search candidates
                    if (_result!.candidates.length > 1) ...[
                      const SizedBox(height: 8),
                      Text(
                        'All candidates (${_result!.candidates.length}):',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue.shade700,
                        ),
                      ),
                      ..._result!.candidates.asMap().entries.map((entry) {
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
              ),
          ],
        ),
      ),
    );
  }
}
