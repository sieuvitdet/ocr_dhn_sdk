import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
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

  @override
  void initState() {
    super.initState();
    _sdk.init();
    _checkPhotoPermission();
    _checkCameraPermission();
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
    });

    try {
      final bytes = await _selectedImage!.readAsBytes();
      final result = await _sdk.processImage(bytes, isOnline: true);

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

  @override
  void dispose() {
    _sdk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Water Meter OCR Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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

            if (_processedImageBytes != null)
              Image.memory(
                _processedImageBytes!,
                fit: BoxFit.contain,
                height: MediaQuery.of(context).size.height * 0.5,
                width: MediaQuery.of(context).size.width,
              ),

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
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
