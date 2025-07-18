import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:water_meter_sdk/water_meter_sdk.dart';

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
  final _waterMeterSdkPlugin = WaterMeterSdk();
  final _imagePicker = ImagePicker();
  WaterMeterResult? _lastResult;
  bool _isProcessing = false;
  File? _selectedImage;
  bool _hasPermission = false;
   Uint8List? selectedImage;

  @override
  void initState() {
    super.initState();
    _checkPhotoPermission();
  }

  Future<void> _checkPhotoPermission() async {
    final status = await Permission.photos.status;
    setState(() {
      _hasPermission = status.isGranted;
    });
  }
  

  Future<void> _requestPhotoPermission() async {
    final status = await Permission.photos.request();
    
    setState(() {
      _hasPermission = status.isGranted;
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
                  _hasPermission = false;
                });
              },
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await openAppSettings();
                if (!mounted) return;
                final newStatus = await Permission.photos.status;
                setState(() {
                  _hasPermission = newStatus.isGranted;
                });
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    setState(() {
      _hasPermission = status.isGranted;
    });
  }

  Future<void> _pickImageFromCamera() async {
    if (!_hasPermission) {
      await _requestCameraPermission();
      return;
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
      debugPrint('Error picking image: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking image: $e')),
      );
    }

  }

  Future<void> _pickImageFromGallery() async {
    if (!_hasPermission) {
      await _requestPhotoPermission();
      return;
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
      debugPrint('Error picking image: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking image: $e')),
      );
    }
  }

  Future<void> _processImage() async {
    if (_selectedImage == null || _isProcessing) {
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
        WaterMeterResult result = await _waterMeterSdkPlugin.processWaterMeterImage(await _selectedImage!.readAsBytes(), imageFull: _selectedImage!.path);
      
      if (mounted) {
        setState(() {
          selectedImage = result.imageBytes;
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

  @override
  void dispose() {
    _waterMeterSdkPlugin.dispose();
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
          // crossAxisAlignment: CrossAxisAlignment.stretch,
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
                Image.memory(selectedImage!,
                fit: BoxFit.contain,
                height: 200,
                width: 200,),
            
            // Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _hasPermission ? _pickImageFromGallery : _requestPhotoPermission,
                    icon: const Icon(Icons.photo_library),
                    label: Text(_hasPermission ? 'Chọn ảnh' : 'Grant Permission'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _hasPermission ? _pickImageFromCamera : _requestPhotoPermission,
                    icon: const Icon(Icons.camera),
                    label: Text(_hasPermission ? 'Chụp ảnh' : 'Grant Permission'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),

                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _selectedImage != null && !_isProcessing ? _processImage : null,
                    icon: const Icon(Icons.analytics),
                    label: Text(_isProcessing ? 'Processing...' : 'Analyze'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Results
            if (_lastResult != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  border: Border.all(color: Colors.green.shade200),
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
                        color: Colors.green.shade800,
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
                        color: Colors.green.shade900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Confidence: ${(_lastResult!.confidence * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.green.shade700,
                      ),
                    ),
                    if (_lastResult!.debugInfo != null && _lastResult!.debugInfo!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Debug: ${_lastResult!.debugInfo!.join(", ")}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),

                      if(_lastResult!.rawOcrText != null && _lastResult!.rawOcrText!.isNotEmpty)
                        Text(
                          'Raw OCR Text: ${_lastResult!.rawOcrText}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),

                      if(_lastResult!.processedText != null && _lastResult!.processedText!.isNotEmpty)
                        Text(
                          'Processed Text: ${_lastResult!.processedText}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
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
          /// Xử lý show popup warning xin quyền với button từ chối và cấp quyền, khi chọn cấp quyền chạy openSetting
          PermissionRequest.openSetting();
        }
      });
  }

  static Future<bool> check(PermissionRequestType type) =>
      PermissionRequest.check(type);
}

class PermissionDeviceType {
  /// CAMERA
  static const String permissionCamera = 'camera';
  /// LOCATION
  static const String permissionLocation = 'location';
  /// STORAGE
  static const String permissionStorage = 'storage';
  /// MICROPHONE
  static const String permissionMicrophone = 'microphone';
  /// NOTIFICATION
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