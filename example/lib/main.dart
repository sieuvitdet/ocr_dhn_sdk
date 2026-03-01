import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:water_meter_sdk/models/detection_test_result.dart';
import 'package:water_meter_sdk/models/water_meter_result.dart';
import 'package:water_meter_sdk/water_meter_sdk_ultralytics_yolo.dart';
import 'package:water_meter_sdk/water_meter_sdk_yolo_old_version.dart';
import 'detection_log_screen.dart';
import 'water_meter_detector.dart';

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
  final _yoloService = WaterMeterSdkUltralyticsYolo();
  final _yoloOldVersionService = WaterMeterSdkYoloOldVersion();
  final _detector = WaterMeterDetector();
  final _imagePicker = ImagePicker();
  WaterMeterResult? _lastResult;
  DetectResult? _lastDetectResult;
  String _lastMethod = '';
  bool _isProcessing = false;
  File? _selectedImage;
  bool _hasPermissionPhoto = false;
  bool _hasPermissionCamera = false;
  Uint8List? selectedImage;

  @override
  void initState() {
    super.initState();

    // _yoloService.init();
    _yoloOldVersionService.init();
    // _detector.loadModel();

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
    // On Android, image_picker uses system intent - no manual permission needed.
    // On iOS, request photo library permission first.
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

  /// Test Scenario: detect + draw bbox + crop + OCR → navigate to log screen
  Future<void> _processWithScenario(YoloScenario scenario) async {
    if (_selectedImage == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _lastResult = null;
      _lastDetectResult = null;
      _lastMethod = scenario == YoloScenario.pubCache
          ? 'Scenario 1 (Pub Cache)'
          : 'Scenario 2 (Local Fork)';
    });

    try {
      final bytes = await _selectedImage!.readAsBytes();
      final result = await _yoloService.processWithScenario(
        bytes,
        scenario,
        isOnline: true,
      );

      if (mounted) {
        setState(() {
          selectedImage = result.inputImageWithBBox;
          _isProcessing = false;
        });

        // Navigate to log screen
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DetectionLogScreen(result: result),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error scenario: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _processWithYoloOldVersion() async {
    if (_selectedImage == null || _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      WaterMeterResult? result;
      result = await _yoloOldVersionService.processWaterMeterImage(await _selectedImage!.readAsBytes(), isOnline: true);
      
      if (mounted) {
        setState(() {
          selectedImage = result?.imageBytes;
          _lastResult = result;
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint('Error processing image: $e');
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error processing image: $e')),
        );
      }
    }
  }
  /// SDK: yolo11n-obb + crop + OCR (original)
  Future<void> _processWithSDK() async {
    if (_selectedImage == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _lastResult = null;
      _lastDetectResult = null;
    });

    try {
      final result = await _yoloService.processWaterMeterImage(
        await _selectedImage!.readAsBytes(),
        isOnline: true,
      );
      if (mounted) {
        setState(() {
          selectedImage = result?.imageBytes;
          _lastResult = result;
          _lastMethod = 'SDK (best model)';
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint('Error SDK: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SDK Error: $e')),
        );
      }
    }
  }

  /// Detector: best_float32/best + OBB detection only
  Future<void> _processWithDetector() async {
    if (_selectedImage == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _lastResult = null;
      _lastDetectResult = null;
    });

    try {
      final bytes = await _selectedImage!.readAsBytes();
      final result = await _detector.detectFromBytes(bytes);
      if (mounted) {
        setState(() {
          selectedImage = result.annotatedImage;
          _lastDetectResult = result;
          _lastMethod = 'OBB Detector (best)';
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint('Error Detector: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Detector Error: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _yoloService.dispose();
    _detector.dispose();
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

            if (selectedImage != null)
              Image.memory(
                selectedImage!,
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

            // === TEST SCENARIOS ===
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade400),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Test Scenarios',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Detect + BBox + Crop + OCR → Log Screen',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : () => _processWithYoloOldVersion(),
                          icon: const Icon(Icons.cloud_download, size: 18),
                          label: Text(
                            _isProcessing && _lastMethod.contains('YOLO Old Version')
                                ? 'Processing...'
                                : 'S0: YOLO Old Version',
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),

                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : () => _processWithScenario(YoloScenario.pubCache),
                          icon: const Icon(Icons.cloud_download, size: 18),
                          label: Text(
                            _isProcessing && _lastMethod.contains('Pub Cache')
                                ? 'Processing...'
                                : 'S1: Pub Cache',
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : () => _processWithScenario(YoloScenario.localFork),
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: Text(
                            _isProcessing && _lastMethod.contains('Local Fork')
                                ? 'Processing...'
                                : 'S2: Local Fork',
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Original detect buttons: SDK vs OBB Detector
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _processWithSDK,
                    icon: const Icon(Icons.analytics),
                    label: Text(_isProcessing && _lastMethod.contains('SDK')
                        ? 'Processing...'
                        : 'SDK (best)'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isProcessing ? null : _processWithDetector,
                    icon: const Icon(Icons.crop_free),
                    label: Text(_isProcessing && _lastMethod.contains('Detector')
                        ? 'Processing...'
                        : 'OBB (best)'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
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

            // Method label
            if (_lastMethod.isNotEmpty && !_isProcessing)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Method: $_lastMethod',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),

            // SDK Results
            if (_lastResult != null)
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
                      _lastResult!.reading.isNotEmpty
                          ? _lastResult!.reading
                          : 'No reading detected',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Confidence: ${(_lastResult!.confidence * 100).toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 14, color: Colors.blue.shade700),
                    ),
                    if (_lastResult!.debugInfo != null && _lastResult!.debugInfo!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Debug: ${_lastResult!.debugInfo!.join(", ")}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ),
                    if (_lastResult!.rawOcrText != null && _lastResult!.rawOcrText!.isNotEmpty)
                      Text(
                        'Raw OCR Text: ${_lastResult!.rawOcrText}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    if (_lastResult!.processedText != null && _lastResult!.processedText!.isNotEmpty)
                      Text(
                        'Processed Text: ${_lastResult!.processedText}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                  ],
                ),
              ),

            // OBB Detector Results
            if (_lastDetectResult != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  border: Border.all(color: Colors.orange.shade200),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'OBB Detections: ${_lastDetectResult!.detections.length}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.orange.shade800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Image: ${_lastDetectResult!.nativeImageWidth}x${_lastDetectResult!.nativeImageHeight}',
                      style: TextStyle(fontSize: 14, color: Colors.orange.shade700),
                    ),
                    Text(
                      'Threshold: conf=${_lastDetectResult!.confidenceThreshold} iou=${_lastDetectResult!.iouThreshold}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 8),
                    ..._lastDetectResult!.detections.asMap().entries.map((entry) {
                      final i = entry.key;
                      final d = entry.value;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '[$i] ${d.className} ${(d.confidence * 100).toStringAsFixed(1)}% '
                          'angle=${d.angleDeg.toStringAsFixed(1)}',
                          style: TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: d.confidence > 0.5 ? Colors.green.shade700 : Colors.red.shade700,
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}


class PermissionHandler {
  static Future<bool> request(
      BuildContext context, PermissionRequestType type, {bool showPopup = true}) async {
    return PermissionRequest.request(type, () {
        String permission="";
        if (type == PermissionRequestType.CAMERA) {
          permission = PermissionDeviceType.permissionCamera;
        } else if (type == PermissionRequestType.LOCATION) {
          permission = PermissionDeviceType.permissionLocation;
        } else if (type == PermissionRequestType.STORAGE) {
          permission = PermissionDeviceType.permissionStorage;
        } else if (type == PermissionRequestType.NOTIFICATION) {
          permission = PermissionDeviceType.permissionNotification;
        } else if (type == PermissionRequestType.MICROPHONE) {
          permission = PermissionDeviceType.permissionMicrophone;
        }
        if(showPopup) {
          PermissionRequest.openSetting();
        }
      });
  }

  static Future<bool> check(PermissionRequestType type) =>
      PermissionRequest.check(type);
}

class PermissionDeviceType {
  static const String permissionCamera = 'camera';
  static const String permissionLocation = 'location';
  static const String permissionStorage = 'storage';
  static const String permissionMicrophone = 'microphone';
  static const String permissionNotification = 'notification';
}


class PermissionRequest {
  static final _channel = MethodChannel("flutter.permission/requestPermission");

  static openSetting() {
    MethodChannel("flutter.permission/requestPermission").invokeMethod('open_screen');
  }

  static Future<bool> request(PermissionRequestType type, Function onDontAskAgain) async {
    bool event = false;
    int? result = 0;

    try{
      if(type == PermissionRequestType.CAMERA){
        result = await _channel.invokeMethod<int>('camera',{'isRequest':true});
      }
      else if(type == PermissionRequestType.LOCATION){
        result = await _channel.invokeMethod<int>('location',{'isRequest':true});
      }
      else if(type == PermissionRequestType.BACKGROUND_LOCATION){
        result = await _channel.invokeMethod<int>('background_location',{'isRequest':true});
      }
      else if(type == PermissionRequestType.STORAGE){
        result = await _channel.invokeMethod<int>('storage',{'isRequest':true});
      }
      else if(type == PermissionRequestType.NOTIFICATION){
        result = await _channel.invokeMethod<int>('notification',{'isRequest':true});
      }
      else if(type == PermissionRequestType.MICROPHONE){
        result = await _channel.invokeMethod<int>('microphone',{'isRequest':true});
      }
    }
    catch(_){}

    if(result == -1)
      await onDontAskAgain();
    else if(result == 1)
      event = true;

    return event;
  }

  static Future<bool> check(PermissionRequestType type, {bool checkAlways = false}) async {
    int? result = 0;
    try{
      if(type == PermissionRequestType.CAMERA){
        result = await _channel.invokeMethod<int>('camera',{'isRequest':false, 'isAlways': checkAlways});
      }
      else if(type == PermissionRequestType.LOCATION){
        result = await _channel.invokeMethod<int>('location',{'isRequest':false, 'isAlways': checkAlways});
      }
      else if(type == PermissionRequestType.BACKGROUND_LOCATION){
        result = await _channel.invokeMethod<int>('background_location',{'isRequest':false, 'isAlways': checkAlways});
      }
      else if(type == PermissionRequestType.STORAGE){
        result = await _channel.invokeMethod<int>('storage',{'isRequest':false, 'isAlways': checkAlways});
      }
      else if(type == PermissionRequestType.NOTIFICATION){
        result = await _channel.invokeMethod<int>('notification',{'isRequest':false, 'isAlways': checkAlways});
      }
      else if(type == PermissionRequestType.MICROPHONE){
        result = await _channel.invokeMethod<int>('microphone',{'isRequest':false, 'isAlways': checkAlways});
      }
    }
    catch(_){}

    return result == 1?true:false;
  }
}

enum PermissionRequestType{
  CAMERA, LOCATION, BACKGROUND_LOCATION, STORAGE, NOTIFICATION, MICROPHONE
}
