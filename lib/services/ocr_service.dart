import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';

import '../utils/constants.dart';
import '../utils/helpers.dart';
import '../utils/log_level.dart';
import 'logging_service.dart';

class OcrService extends ChangeNotifier {
  static final OcrService _instance = OcrService._internal();
  factory OcrService() => _instance;
  static OcrService get instance => _instance;
  OcrService._internal();

  final LoggingService _logger = LoggingService();
  final TextRecognizer _textRecognizer = TextRecognizer();
  
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _isFlashlightOn = false;
  String? _lastExtractedText;
  double? _lastConfidence;
  DateTime? _lastProcessTime;

  // Getters
  CameraController? get cameraController => _cameraController;
  List<CameraDescription>? get cameras => _cameras;
  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;
  bool get isFlashlightOn => _isFlashlightOn;
  String? get lastExtractedText => _lastExtractedText;
  double? get lastConfidence => _lastConfidence;
  DateTime? get lastProcessTime => _lastProcessTime;

  // Initialize OCR service
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      _logger.logOcr('Initializing OCR service');

      // Check camera permission first
      final permissionStatus = await _checkCameraPermission();
      if (!permissionStatus) {
        _logger.logOcr('Camera permission denied', success: false);
        return false;
      }

      // Get available cameras with retry mechanism
      int retryCount = 0;
      const maxRetries = 3;
      
      while (retryCount < maxRetries) {
        try {
          _cameras = await availableCameras();
          if (_cameras != null && _cameras!.isNotEmpty) break;
          
          retryCount++;
          if (retryCount < maxRetries) {
            _logger.logOcr('Retry attempt $retryCount for camera discovery');
            await Future.delayed(Duration(milliseconds: 1000 * retryCount));
          }
        } catch (e) {
          retryCount++;
          _logger.logOcr('Camera discovery error on attempt $retryCount: $e');
          if (retryCount >= maxRetries) rethrow;
          await Future.delayed(Duration(milliseconds: 1000 * retryCount));
        }
      }
      
      if (_cameras == null || _cameras!.isEmpty) {
        _logger.logOcr('No cameras available after retries', success: false);
        return false;
      }

      _logger.logOcr('Found ${_cameras!.length} cameras');

      // Find the best camera (prefer back camera)
      final backCamera = _cameras!.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );

      // Dispose existing controller if any
      if (_cameraController != null) {
        try {
          await _cameraController!.dispose();
        } catch (e) {
          _logger.logOcr('Warning: Error disposing previous camera controller: $e');
        }
        _cameraController = null;
      }

      // Create new camera controller
      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      // Initialize camera with retry mechanism and longer delays
      retryCount = 0;
      while (retryCount < maxRetries) {
        try {
          _logger.logOcr('Attempting camera initialization, attempt ${retryCount + 1}');
          await _cameraController!.initialize();
          
          // Verify camera is actually working
          if (!_cameraController!.value.isInitialized) {
            throw Exception('Camera controller reports not initialized');
          }
          
          _logger.logOcr('Camera controller initialized successfully');
          break;
        } catch (e) {
          retryCount++;
          _logger.logOcr('Camera initialization failed on attempt $retryCount: $e');
          
          if (retryCount >= maxRetries) {
            throw Exception('Failed to initialize camera after $maxRetries attempts: $e');
          }
          
          // Dispose and recreate controller for retry
          try {
            await _cameraController!.dispose();
          } catch (_) {}
          
          await Future.delayed(Duration(milliseconds: 2000 * retryCount));
          
          // Recreate controller for retry
          _cameraController = CameraController(
            backCamera,
            ResolutionPreset.high,
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.yuv420,
          );
        }
      }
      
      _isInitialized = true;
      _logger.logOcr('OCR service initialized successfully');
      notifyListeners();
      return true;
    } catch (e, stackTrace) {
      _logger.logError('Failed to initialize OCR service',
          error: e, stackTrace: stackTrace, category: 'OCR');
      
      // Clean up on failure
      try {
        _cameraController?.dispose();
      } catch (_) {}
      _cameraController = null;
      _isInitialized = false;
      return false;
    }
  }

  // Check if camera is properly initialized and working
  bool get isCameraReady {
    return _isInitialized && 
           _cameraController != null && 
           _cameraController!.value.isInitialized;
  }
  
  // Force re-initialization (useful for lifecycle management)
  Future<bool> reinitialize() async {
    _logger.logOcr('Force re-initializing OCR service');
    
    // Clean up current state
    _isInitialized = false;
    try {
      _cameraController?.dispose();
    } catch (e) {
      _logger.logOcr('Warning during cleanup: $e');
    }
    _cameraController = null;
    
    // Re-initialize
    return await initialize();
  }

  // Capture and process image for text extraction with auto-matching
  Future<Map<String, dynamic>?> captureAndExtractTextWithMatching({
    required List<dynamic> availableBatches,
    double similarityThreshold = 0.75,
  }) async {
    // Check if camera is ready, if not try to initialize
    if (!isCameraReady) {
      _logger.logOcr('Camera not ready, attempting initialization');
      final initialized = await initialize();
      if (!initialized || !isCameraReady) {
        return {
          'success': false,
          'extractedText': '',
          'matches': <BatchMatchResult>[],
          'nearestMatches': <BatchMatchResult>[],
          'error': 'Camera initialization failed'
        };
      }
    }

    if (_isProcessing) {
      _logger.logOcr('OCR processing already in progress', success: false);
      return null;
    }

    _isProcessing = true;
    notifyListeners();

    final stopwatch = Stopwatch()..start();

    try {
      _logger.logOcr('Capturing image for text extraction and matching');

      // Capture image
      final XFile imageFile = await _cameraController!.takePicture();
      final File image = File(imageFile.path);

      // Log image details
      final imageStats = await image.stat();
      _logger.logOcr('Image captured successfully',
          success: true,
          extractedText: null,
          confidence: null);
      
      _logger.logApp('Image capture details',
          data: {
            'filePath': imageFile.path,
            'fileSize': Helpers.formatFileSize(imageStats.size),
            'sizeBytes': imageStats.size,
          });

      // Process image for text recognition
      final extractedText = await _processImageForText(image);
      
      if (extractedText == null || extractedText.isEmpty) {
        stopwatch.stop();
        _logger.logOcr('No text extracted from image', success: false);
        return {
          'success': false,
          'extractedText': '',
          'matches': <BatchMatchResult>[],
          'nearestMatches': <BatchMatchResult>[],
          'error': 'No text extracted from image'
        };
      }

      // Perform batch matching automatically
      final matches = findBestBatchMatches(
        extractedText: extractedText,
        batches: availableBatches,
        similarityThreshold: similarityThreshold,
      );

      // If no matches found, get nearest matches
      List<BatchMatchResult> nearestMatches = [];
      if (matches.isEmpty) {
        nearestMatches = findNearestBatchMatches(
          extractedText: extractedText,
          batches: availableBatches,
          maxResults: 2,
        );
        _logger.logOcr('No exact matches found, showing ${nearestMatches.length} nearest matches');
      }

      stopwatch.stop();
      _logger.logPerformance('OCR text extraction and matching', stopwatch.elapsed);

      // Clean up the temporary image file
      try {
        await image.delete();
      } catch (e) {
        _logger.logApp('Failed to delete temporary image file',
            level: LogLevel.warning, data: {'error': e.toString()});
      }

      return {
        'success': true,
        'extractedText': extractedText,
        'matches': matches,
        'nearestMatches': nearestMatches,
        'confidence': _lastConfidence ?? 0.0,
      };
    } catch (e, stackTrace) {
      stopwatch.stop();
      _logger.logError('Failed to capture and process image',
          error: e, stackTrace: stackTrace, category: 'OCR');
      return {
        'success': false,
        'extractedText': '',
        'matches': <BatchMatchResult>[],
        'nearestMatches': <BatchMatchResult>[],
        'error': e.toString()
      };
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  // Process image file for text extraction
  Future<String?> processImageFile(File imageFile) async {
    if (_isProcessing) {
      _logger.logOcr('OCR processing already in progress', success: false);
      return null;
    }

    _isProcessing = true;
    notifyListeners();

    final stopwatch = Stopwatch()..start();

    try {
      final imageStats = await imageFile.stat();
      _logger.logOcr('Processing image file for text extraction',
          success: true,
          extractedText: null,
          confidence: null);
      
      _logger.logApp('Image file details',
          data: {
            'filePath': imageFile.path,
            'fileSize': Helpers.formatFileSize(imageStats.size),
            'sizeBytes': imageStats.size,
          });

      final extractedText = await _processImageForText(imageFile);
      
      stopwatch.stop();
      _logger.logPerformance('OCR file processing', stopwatch.elapsed);

      return extractedText;
    } catch (e, stackTrace) {
      stopwatch.stop();
      _logger.logError('Failed to process image file',
          error: e, stackTrace: stackTrace, category: 'OCR');
      return null;
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  // Process image with path
  Future<String?> processImage(String imagePath) async {
    return await processImageFile(File(imagePath));
  }

  // Internal method to process image for text recognition
  Future<String?> _processImageForText(File imageFile) async {
    try {
      _logger.logOcr('Starting text recognition');

      final inputImage = InputImage.fromFile(imageFile);
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);

      final extractedText = recognizedText.text;
      final confidence = _calculateAverageConfidence(recognizedText);

      _lastExtractedText = extractedText;
      _lastConfidence = confidence;
      _lastProcessTime = DateTime.now();

      if (extractedText.isEmpty) {
        _logger.logOcr('No text detected in image', 
            success: false, confidence: confidence);
        return null;
      }

      _logger.logOcr('Text extraction completed',
          success: true,
          extractedText: extractedText,
          confidence: confidence);

      // Log detailed results
      _logger.logApp('OCR results',
          data: {
            'textLength': extractedText.length,
            'confidence': confidence,
            'confidenceThreshold': Constants.ocrConfidenceThreshold,
            'passedThreshold': confidence >= Constants.ocrConfidenceThreshold,
            'blockCount': recognizedText.blocks.length,
            'lineCount': recognizedText.blocks
                .expand((block) => block.lines)
                .length,
          });

      // Filter results based on confidence threshold
      if (confidence < Constants.ocrConfidenceThreshold) {
        _logger.logOcr('Text recognition confidence below threshold',
            success: false,
            extractedText: extractedText,
            confidence: confidence);
        return null;
      }

      return extractedText;
    } catch (e, stackTrace) {
      _logger.logError('Text recognition failed',
          error: e, stackTrace: stackTrace, category: 'OCR');
      return null;
    }
  }

  // Calculate average confidence from recognized text
  double _calculateAverageConfidence(RecognizedText recognizedText) {
    if (recognizedText.blocks.isEmpty) return 0.0;

    double totalConfidence = 0.0;
    int elementCount = 0;

    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        for (final _ in line.elements) {
          // Note: As of current ML Kit version, confidence values might not be available
          // This is a placeholder for when confidence values become available
          totalConfidence += 1.0; // Assuming maximum confidence for now
          elementCount++;
        }
      }
    }

    return elementCount > 0 ? totalConfidence / elementCount : 0.0;
  }

  // Extract specific information from text (e.g., batch numbers, expiry dates)
  Map<String, String?> extractBatchInformation(String text) {
    final result = <String, String?>{};

    try {
      _logger.logOcr('Extracting batch information from text');

      // Extract batch number patterns
      final batchPattern = RegExp(r'BATCH[:\s]*([A-Z0-9]+)', caseSensitive: false);
      final batchMatch = batchPattern.firstMatch(text);
      result['batchNumber'] = batchMatch?.group(1);

      // Extract lot number patterns
      final lotPattern = RegExp(r'LOT[:\s]*([A-Z0-9]+)', caseSensitive: false);
      final lotMatch = lotPattern.firstMatch(text);
      result['lotNumber'] = lotMatch?.group(1);

      // Extract expiry date patterns (various formats)
      final expiryPatterns = [
        RegExp(r'EXP[:\s]*(\d{2}/\d{2}/\d{4})', caseSensitive: false),
        RegExp(r'EXPIRY[:\s]*(\d{2}/\d{2}/\d{4})', caseSensitive: false),
        RegExp(r'(\d{2}/\d{2}/\d{4})'),
        RegExp(r'(\d{4}-\d{2}-\d{2})'),
      ];

      for (final pattern in expiryPatterns) {
        final match = pattern.firstMatch(text);
        if (match != null) {
          result['expiryDate'] = match.group(1);
          break;
        }
      }

      // Extract manufacturing date patterns
      final mfgPattern = RegExp(r'MFG[:\s]*(\d{2}/\d{2}/\d{4})', caseSensitive: false);
      final mfgMatch = mfgPattern.firstMatch(text);
      result['manufacturingDate'] = mfgMatch?.group(1);

      _logger.logApp('Batch information extraction completed',
          data: result);

      return result;
    } catch (e, stackTrace) {
      _logger.logError('Failed to extract batch information',
          error: e, stackTrace: stackTrace, category: 'OCR');
      return result;
    }
  }

  /// Enhanced fuzzy batch matching: searches for batch numbers within the extracted text
  /// Returns a list of matches with similarity >= [similarityThreshold] and valid expiry
  List<BatchMatchResult> findBestBatchMatches({
    required String extractedText,
    required List<dynamic> batches, // List<BatchModel> or Map
    double similarityThreshold = 0.75,
  }) {
    final List<BatchMatchResult> results = [];
    final normalizedText = extractedText.trim().toUpperCase();
    
    _logger.logOcr('MATCH_START: Beginning batch matching process');
    _logger.logOcr('MATCH_INPUT_BATCH: Extracted text: "$extractedText"');
    _logger.logOcr('MATCH_AVAILABLE_BATCHES: ${batches.length} batches available for matching');

    // Extract potential expiry dates from the text
    String? extractedExpiry = _extractExpiryFromText(normalizedText);
    _logger.logOcr('MATCH_INPUT_EXPIRY: Extracted expiry: "${extractedExpiry ?? "null"}"');
    
    for (final batch in batches) {
      final batchNumber = (batch.batchNumber ?? batch.batchId ?? '').toString().trim().toUpperCase();
      if (batchNumber.isEmpty) continue;

      // Check if the batch number is contained within the extracted text using fuzzy matching
      double bestSim = _findBatchInText(batchNumber, normalizedText);
      
      // Expiry validation (if extractedExpiry is present and batch has expiry)
      bool expiryValid = true;
      if (extractedExpiry != null && batch.expiryDate != null) {
        expiryValid = _compareExpiryDates(extractedExpiry, batch.expiryDate.toString());
        _logger.logOcr('Expiry validation for ${batchNumber}: extracted="$extractedExpiry", batch="${batch.expiryDate}", valid=$expiryValid');
      }

      // Add to results if similarity meets threshold AND expiry is valid (if present)
      if (bestSim >= similarityThreshold && expiryValid) {
        results.add(BatchMatchResult(
          batch: batch,
          similarity: bestSim,
          expiryValid: expiryValid,
        ));
        _logger.logOcr('Match found: ${batchNumber} with similarity ${(bestSim * 100).toInt()}% and valid expiry');
      }
    }
    
    // Sort by similarity descending
    results.sort((a, b) => b.similarity.compareTo(a.similarity));
    _logger.logOcr('MATCH_RESULTS: Found ${results.length} matches above threshold');
    
    return results;
  }
  
  /// Find batch number within extracted text using sliding window and fuzzy matching
  double _findBatchInText(String batchNumber, String extractedText) {
    double bestSimilarity = 0.0;
    final batchLength = batchNumber.length;
    
    // Try sliding window across the extracted text
    for (int i = 0; i <= extractedText.length - batchLength; i++) {
      final window = extractedText.substring(i, i + batchLength);
      final similarity = _levenshteinSimilarity(batchNumber, window);
      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
      }
    }
    
    // Also try with different window sizes (±2 characters)
    for (int offset = -2; offset <= 2; offset++) {
      final windowSize = batchLength + offset;
      if (windowSize <= 0 || windowSize > extractedText.length) continue;
      
      for (int i = 0; i <= extractedText.length - windowSize; i++) {
        final window = extractedText.substring(i, i + windowSize);
        final similarity = _levenshteinSimilarity(batchNumber, window);
        if (similarity > bestSimilarity) {
          bestSimilarity = similarity;
        }
      }
    }
    
    return bestSimilarity;
  }
  
  /// Extract expiry date from text using multiple patterns
  String? _extractExpiryFromText(String text) {
    final expiryPatterns = [
      RegExp(r'EXP[:\s]*(\d{2}[\/\-]\d{2}[\/\-]\d{4})', caseSensitive: false),
      RegExp(r'EXPIRY[:\s]*(\d{2}[\/\-]\d{2}[\/\-]\d{4})', caseSensitive: false),
      RegExp(r'(\d{4}-\d{2}-\d{2})'), // ISO format
      RegExp(r'(\d{2}[\/\-]\d{2}[\/\-]\d{4})'), // DD/MM/YYYY or MM/DD/YYYY
      RegExp(r'(\d{2}[\/\-]\d{4})'), // MM/YYYY
      RegExp(r'(\d{4}[\/\-]\d{2}[\/\-]\d{2})'), // YYYY/MM/DD
      RegExp(r'EXP[:\s]*(\d{2}[\/\-]\d{4})', caseSensitive: false), // EXP: MM/YYYY
    ];

    for (final pattern in expiryPatterns) {
      final match = pattern.firstMatch(text);
      if (match != null && match.group(1) != null) {
        return match.group(1)!.trim();
      }
    }
    return null;
  }
  
  /// Find nearest batch matches for fallback when no exact matches found
  List<BatchMatchResult> findNearestBatchMatches({
    required String extractedText,
    required List<dynamic> batches,
    int maxResults = 2,
  }) {
    final List<BatchMatchResult> allMatches = [];
    final normalizedText = extractedText.trim().toUpperCase();
    
    _logger.logOcr('Finding nearest matches with lower threshold');
    
    for (final batch in batches) {
      final batchNumber = (batch.batchNumber ?? batch.batchId ?? '').toString().trim().toUpperCase();
      if (batchNumber.isEmpty) continue;

      double bestSim = _findBatchInText(batchNumber, normalizedText);
      
      // Add all matches regardless of threshold for nearest search
      allMatches.add(BatchMatchResult(
        batch: batch,
        similarity: bestSim,
        expiryValid: true, // Don't filter by expiry for nearest matches
      ));
    }
    
    // Sort by similarity and take top results
    allMatches.sort((a, b) => b.similarity.compareTo(a.similarity));
    return allMatches.take(maxResults).toList();
  }

  /// Levenshtein similarity (1 - normalized distance)
  double _levenshteinSimilarity(String a, String b) {
    final dist = _levenshtein(a, b);
    final maxLen = a.length > b.length ? a.length : b.length;
    if (maxLen == 0) return 1.0;
    return 1.0 - (dist / maxLen);
  }

  /// Levenshtein distance implementation
  int _levenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;
    List<List<int>> d = List.generate(s.length + 1, (_) => List.filled(t.length + 1, 0));
    
    for (int i = 0; i <= s.length; i++) {
      d[i][0] = i;
    }
    for (int j = 0; j <= t.length; j++) {
      d[0][j] = j;
    }
    
    for (int i = 1; i <= s.length; i++) {
      for (int j = 1; j <= t.length; j++) {
        int cost = s[i - 1] == t[j - 1] ? 0 : 1;
        d[i][j] = [
          d[i - 1][j] + 1,
          d[i][j - 1] + 1,
          d[i - 1][j - 1] + cost
        ].reduce((a, b) => a < b ? a : b);
      }
    }
    return d[s.length][t.length];
  }

  /// Expiry date comparison (supports multiple formats)
  bool _compareExpiryDates(String extracted, String batchExpiry) {
    final formats = [
      'dd/MM/yyyy', 'MM/yyyy', 'yyyy-MM-dd', 'dd-MM-yyyy', 'MM-yy', 'MM/yyyy', 'yyyy/MM/dd', 'dd MMM yyyy'
    ];
    
    DateTime? parseDate(String s) {
      for (final f in formats) {
        try {
          return DateFormat(f).parse(s);
        } catch (_) {}
      }
      return null;
    }
    
    final d1 = parseDate(extracted);
    final d2 = parseDate(batchExpiry);
    if (d1 == null || d2 == null) return false;
    
    // Allow for month/year only matches
    return d1.year == d2.year && d1.month == d2.month;
  }

  // Switch camera (front/back)
  Future<void> switchCamera() async {
    if (!_isInitialized || _cameras == null || _cameras!.length < 2) {
      _logger.logOcr('Cannot switch camera - not enough cameras available',
          success: false);
      return;
    }

    try {
      final currentCamera = _cameraController!.description;
      final newCamera = _cameras!.firstWhere(
        (camera) => camera.lensDirection != currentCamera.lensDirection,
        orElse: () => currentCamera,
      );

      if (newCamera == currentCamera) {
        _logger.logOcr('No alternative camera found', success: false);
        return;
      }

      await _cameraController!.dispose();

      _cameraController = CameraController(
        newCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      _logger.logOcr('Camera switched successfully');
      notifyListeners();
    } catch (e, stackTrace) {
      _logger.logError('Failed to switch camera',
          error: e, stackTrace: stackTrace, category: 'OCR');
    }
  }

  // Toggle flashlight
  Future<void> toggleFlashlight() async {
    if (!_isInitialized || _cameraController == null) {
      _logger.logOcr('Cannot toggle flashlight - camera not initialized',
          success: false);
      return;
    }

    try {
      // Toggle flashlight (CameraController doesn't have getFlashMode, so we'll track it ourselves)
      final newMode = _isFlashlightOn ? FlashMode.off : FlashMode.torch;
      await _cameraController!.setFlashMode(newMode);
      _isFlashlightOn = !_isFlashlightOn;
      
      _logger.logOcr('Flashlight ${_isFlashlightOn ? 'enabled' : 'disabled'}');
      notifyListeners();
    } catch (e, stackTrace) {
      _logger.logError('Failed to toggle flashlight',
          error: e, stackTrace: stackTrace, category: 'OCR');
    }
  }

  // Check camera permission
  Future<bool> _checkCameraPermission() async {
    try {
      PermissionStatus status = await Permission.camera.status;
      
      _logger.logOcr('Camera permission status: ${status.name}');

      if (status == PermissionStatus.denied) {
        status = await Permission.camera.request();
        _logger.logOcr('Camera permission requested: ${status.name}');
      }

      if (status == PermissionStatus.permanentlyDenied) {
        _logger.logOcr('Camera permission permanently denied', success: false);
        return false;
      }

      final granted = status == PermissionStatus.granted;
      _logger.logOcr('Camera permission ${granted ? 'granted' : 'denied'}',
          success: granted);
      
      return granted;
    } catch (e, stackTrace) {
      _logger.logError('Error checking camera permission',
          error: e, stackTrace: stackTrace, category: 'OCR');
      return false;
    }
  }

  // Get OCR status info
  Map<String, dynamic> getStatusInfo() {
    return {
      'isInitialized': _isInitialized,
      'isProcessing': _isProcessing,
      'cameraCount': _cameras?.length ?? 0,
      'lastExtractedText': _lastExtractedText,
      'lastConfidence': _lastConfidence,
      'lastProcessTime': _lastProcessTime?.toIso8601String(),
      'currentCamera': _cameraController?.description.lensDirection.name,
    };
  }

  // Reset OCR state
  void reset() {
    _lastExtractedText = null;
    _lastConfidence = null;
    _lastProcessTime = null;
    _logger.logOcr('OCR state reset');
    notifyListeners();
  }

  // Dispose resources
  @override
  void dispose() {
    _cameraController?.dispose();
    _textRecognizer.close();
    _logger.logOcr('OCR service disposed');
    super.dispose();
  }
}

/// Result class for batch matching
class BatchMatchResult {
  final dynamic batch;
  final double similarity;
  final bool expiryValid;
  
  BatchMatchResult({
    required this.batch, 
    required this.similarity, 
    required this.expiryValid
  });
}
