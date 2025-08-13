import 'package:flutter/foundation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/helpers.dart';
import '../utils/log_level.dart';
import '../utils/constants.dart';
import 'logging_service.dart';

class QrScannerService extends ChangeNotifier {
  static final QrScannerService _instance = QrScannerService._internal();
  factory QrScannerService() => _instance;
  QrScannerService._internal();

  final LoggingService _logger = LoggingService();
  MobileScannerController? _controller;
  bool _isInitialized = false;
  bool _isScanning = false;
  String? _lastScannedCode;
  DateTime? _lastScanTime;
  String? _scannedData;

  // Getters
  MobileScannerController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  bool get isScanning => _isScanning;
  String? get lastScannedCode => _lastScannedCode;
  DateTime? get lastScanTime => _lastScanTime;
  String? get scannedData => _scannedData;

  // Initialize the QR scanner
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      _logger.logQrScan('Initializing QR scanner');

      // Check camera permission
      final permissionStatus = await _checkCameraPermission();
      if (!permissionStatus) {
        _logger.logQrScan('Camera permission denied', success: false);
        return false;
      }

      // Initialize the controller
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        facing: CameraFacing.back,
        torchEnabled: false,
      );

      _isInitialized = true;
      _logger.logQrScan('QR scanner initialized successfully');
      notifyListeners();
      return true;
    } catch (e, stackTrace) {
      _logger.logError('Failed to initialize QR scanner',
          error: e, stackTrace: stackTrace, category: 'QR-SCAN');
      return false;
    }
  }

  // Start scanning
  Future<bool> startScanning() async {
    if (!_isInitialized) {
      final initialized = await initialize();
      if (!initialized) return false;
    }

    try {
      await _controller?.start();
      _isScanning = true;
      _logger.logQrScan('QR scanning started');
      notifyListeners();
      return true;
    } catch (e, stackTrace) {
      _logger.logError('Failed to start QR scanning',
          error: e, stackTrace: stackTrace, category: 'QR-SCAN');
      return false;
    }
  }

  // Stop scanning
  Future<void> stopScanning() async {
    try {
      await _controller?.stop();
      _isScanning = false;
      _logger.logQrScan('QR scanning stopped');
      notifyListeners();
    } catch (e, stackTrace) {
      _logger.logError('Error stopping QR scanner',
          error: e, stackTrace: stackTrace, category: 'QR-SCAN');
    }
  }

  // Process scanned QR code
  void processScannedCode(BarcodeCapture capture) {
    final startTime = DateTime.now();
    
    try {
      _logger.logQrScan('QR_SCAN_START: Processing QR code capture');
      
      final codes = capture.barcodes;
      if (codes.isEmpty) {
        _logger.logQrScan('QR_SCAN_EMPTY: No QR codes detected in capture', success: false);
        return;
      }

      _logger.logQrScan('QR_SCAN_DETECTED: Found ${codes.length} QR code(s) in capture');
      
      final code = codes.first;
      final rawValue = code.rawValue;

      if (rawValue == null || rawValue.isEmpty) {
        _logger.logQrScan('QR_SCAN_NULL: QR code data is null or empty', success: false);
        return;
      }

      _logger.logQrScan('QR_SCAN_DATA: Raw QR data extracted: "$rawValue"');
      _logger.logQrScan('QR_SCAN_LENGTH: QR data length: ${rawValue.length} characters');

      // Prevent duplicate scans within a short time frame
      if (_isDuplicateScan(rawValue)) {
        _logger.logQrScan('QR_SCAN_DUPLICATE: Duplicate scan ignored (within ${Constants.qrScanCooldownMs}ms)', 
            qrData: rawValue, success: false);
        return;
      }

      _lastScannedCode = rawValue;
      _lastScanTime = DateTime.now();

      final processTime = DateTime.now().difference(startTime).inMilliseconds;
      _logger.logQrScan('QR_SCAN_CAPTURED: QR code captured successfully in ${processTime}ms', 
          qrData: rawValue, success: true);

      // Extract and validate session ID
      _logger.logQrScan('QR_VALIDATE_START: Beginning session ID validation');
      final sessionId = _extractSessionId(rawValue);
      
      if (sessionId != null) {
        _logger.logQrScan('QR_VALIDATE_SUCCESS: Valid session ID extracted: "$sessionId"', 
            qrData: rawValue, success: true);
        
        _scannedData = sessionId;
        notifyListeners();
        
        final totalTime = DateTime.now().difference(startTime).inMilliseconds;
        _logger.logQrScan('QR_SCAN_COMPLETE: QR processing completed in ${totalTime}ms');
        
      } else {
        _logger.logQrScan('QR_VALIDATE_FAILED: Invalid session ID format', 
            qrData: rawValue, success: false);
        _logger.logQrScan('QR_VALIDATE_PATTERNS: Expected: medha-XXXXX, session_XXXXX, or alphanumeric');
      }
      
    } catch (e, stackTrace) {
      final errorTime = DateTime.now().difference(startTime).inMilliseconds;
      _logger.logError('QR_SCAN_ERROR: Exception after ${errorTime}ms - $e',
          error: e, stackTrace: stackTrace, category: 'QR-SCAN');
    }
  }

  // Toggle flashlight
  Future<void> toggleFlashlight() async {
    try {
      if (_controller != null) {
        await _controller!.toggleTorch();
        final torchState = _controller!.torchEnabled;
        _logger.logQrScan('Flashlight ${torchState ? 'enabled' : 'disabled'}');
        notifyListeners();
      }
    } catch (e, stackTrace) {
      _logger.logError('Failed to toggle flashlight',
          error: e, stackTrace: stackTrace, category: 'QR-SCAN');
    }
  }

  // Switch camera
  Future<void> switchCamera() async {
    try {
      if (_controller != null) {
        await _controller!.switchCamera();
        _logger.logQrScan('Camera switched');
        notifyListeners();
      }
    } catch (e, stackTrace) {
      _logger.logError('Failed to switch camera',
          error: e, stackTrace: stackTrace, category: 'QR-SCAN');
    }
  }

  // Get camera permission
  Future<bool> _checkCameraPermission() async {
    try {
      PermissionStatus status = await Permission.camera.status;
      
      _logger.logQrScan('Camera permission status: ${status.name}');

      if (status == PermissionStatus.denied) {
        status = await Permission.camera.request();
        _logger.logQrScan('Camera permission requested: ${status.name}');
      }

      if (status == PermissionStatus.permanentlyDenied) {
        _logger.logQrScan('Camera permission permanently denied',
            success: false);
        return false;
      }

      final granted = status == PermissionStatus.granted;
      _logger.logQrScan('Camera permission ${granted ? 'granted' : 'denied'}',
          success: granted);
      
      return granted;
    } catch (e, stackTrace) {
      _logger.logError('Error checking camera permission',
          error: e, stackTrace: stackTrace, category: 'QR-SCAN');
      return false;
    }
  }

  // Check if this is a duplicate scan
  bool _isDuplicateScan(String code) {
    if (_lastScannedCode == null || _lastScanTime == null) {
      return false;
    }

    final timeDifference = DateTime.now().difference(_lastScanTime!);
    return _lastScannedCode == code && timeDifference.inSeconds < 2;
  }

  // Extract session ID from QR code with detailed logging
  String? _extractSessionId(String qrData) {
    try {
      _logger.logQrScan('QR_EXTRACT_START: Beginning session ID extraction');
      _logger.logQrScan('QR_EXTRACT_INPUT: Input data: "$qrData"');
      _logger.logQrScan('QR_EXTRACT_LENGTH: Input length: ${qrData.length} characters');

      final trimmedData = qrData.trim();
      _logger.logQrScan('QR_EXTRACT_TRIMMED: Trimmed data: "$trimmedData"');

      // Pattern 1: medha-XXXXXX format (priority pattern)
      final medhaPattern = RegExp(r'medha-([A-Za-z0-9]+)', caseSensitive: false);
      final medhaMatch = medhaPattern.firstMatch(trimmedData);
      if (medhaMatch != null) {
        final sessionId = medhaMatch.group(0)!;
        _logger.logQrScan('QR_EXTRACT_MEDHA: Session ID extracted using medha pattern: "$sessionId"');
        _logger.logQrScan('QR_EXTRACT_SUCCESS: Extraction successful with pattern 1');
        return sessionId;
      }

      // Pattern 2: session_XXXXXX format
      final sessionPattern = RegExp(r'session_([A-Za-z0-9]+)', caseSensitive: false);
      final sessionMatch = sessionPattern.firstMatch(trimmedData);
      if (sessionMatch != null) {
        final sessionId = sessionMatch.group(0)!;
        _logger.logQrScan('QR_EXTRACT_SESSION: Session ID extracted using session pattern: "$sessionId"');
        _logger.logQrScan('QR_EXTRACT_SUCCESS: Extraction successful with pattern 2');
        return sessionId;
      }

      // Pattern 3: Direct alphanumeric (8+ characters)
      final directPattern = RegExp(r'^[A-Za-z0-9\-_]{8,}$');
      if (directPattern.hasMatch(trimmedData) && trimmedData.length >= 8) {
        _logger.logQrScan('QR_EXTRACT_DIRECT: Using direct QR code as session ID: "$trimmedData"');
        _logger.logQrScan('QR_EXTRACT_SUCCESS: Extraction successful with pattern 3');
        return trimmedData;
      }

      // Pattern 4: URL-like format (extract from query params or path)
      final urlPattern = RegExp(r'[?&]session[=:]([A-Za-z0-9\-_]+)', caseSensitive: false);
      final urlMatch = urlPattern.firstMatch(trimmedData);
      if (urlMatch != null) {
        final sessionId = urlMatch.group(1)!;
        _logger.logQrScan('QR_EXTRACT_URL: Session ID extracted from URL: "$sessionId"');
        _logger.logQrScan('QR_EXTRACT_SUCCESS: Extraction successful with pattern 4');
        return sessionId;
      }

      _logger.logQrScan('QR_EXTRACT_FAILED: No valid session ID pattern matched');
      _logger.logQrScan('QR_EXTRACT_PATTERNS: Supported patterns:');
      _logger.logQrScan('QR_EXTRACT_PATTERN1: medha-XXXXX (e.g., medha-OR10ae)');
      _logger.logQrScan('QR_EXTRACT_PATTERN2: session_XXXXX (e.g., session_12345)');
      _logger.logQrScan('QR_EXTRACT_PATTERN3: Direct alphanumeric 8+ chars');
      _logger.logQrScan('QR_EXTRACT_PATTERN4: URL with session parameter');
      
      return null;

    } catch (e) {
      _logger.logError('QR_EXTRACT_ERROR: Exception during session ID extraction - $e', 
          category: 'QR-SCAN');
      return null;
    }
  }

  // Validate session ID format
  bool _isValidSessionId(String sessionId) {
    return Helpers.isValidSessionId(sessionId);
  }

  // Reset scanner state
  void reset() {
    _lastScannedCode = null;
    _lastScanTime = null;
    _logger.logQrScan('QR scanner state reset');
    notifyListeners();
  }

  // Get scanner status info
  Map<String, dynamic> getStatusInfo() {
    return {
      'isInitialized': _isInitialized,
      'isScanning': _isScanning,
      'lastScannedCode': _lastScannedCode,
      'lastScanTime': _lastScanTime?.toIso8601String(),
      'torchEnabled': _controller?.torchEnabled ?? false,
      'cameraFacing': _controller?.facing.name ?? 'unknown',
    };
  }

  // Validate QR code content
  bool validateQrContent(String content) {
    if (content.isEmpty) {
      _logger.logQrScan('QR code validation failed: empty content',
          success: false);
      return false;
    }

    // Add specific validation logic here based on your requirements
    // For now, we'll just check if it's a valid session ID
    final isValid = _isValidSessionId(content);
    
    _logger.logQrScan('QR code validation ${isValid ? 'passed' : 'failed'}',
        qrData: content, success: isValid);

    return isValid;
  }

  // Error handling for scanner errors
  void handleScannerError(Object error, StackTrace? stackTrace) {
    _logger.logError('QR scanner error occurred',
        error: error, stackTrace: stackTrace, category: 'QR-SCAN');
    
    _isScanning = false;
    notifyListeners();
  }

  // Performance monitoring
  void logScanPerformance(Duration scanDuration) {
    _logger.logApp('QR scan performance',
        level: LogLevel.info,
        data: {
          'scanDuration': scanDuration.inMilliseconds,
          'scanDurationFormatted': Helpers.formatDuration(scanDuration),
        });
  }

  // Dispose resources
  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _isScanning = false;
    _logger.logQrScan('QR scanner disposed');
    super.dispose();
  }

  // Get available cameras
  Future<List<CameraFacing>> getAvailableCameras() async {
    try {
      // This is a simplified implementation
      // In a real app, you might want to check actual camera availability
      return [CameraFacing.back, CameraFacing.front];
    } catch (e, stackTrace) {
      _logger.logError('Failed to get available cameras',
          error: e, stackTrace: stackTrace, category: 'QR-SCAN');
      return [CameraFacing.back];
    }
  }

  // Check if flashlight is available
  Future<bool> isFlashlightAvailable() async {
    try {
      // This would typically check device capabilities
      // For now, we'll assume it's available on most devices
      return true;
    } catch (e) {
      _logger.logQrScan('Failed to check flashlight availability',
          success: false);
      return false;
    }
  }
}
