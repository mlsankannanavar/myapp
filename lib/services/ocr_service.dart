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
  String? get lastExtractedText => _lastExtractedText;
  double? get lastConfidence => _lastConfidence;
  DateTime? get lastProcessTime => _lastProcessTime;

  // Initialize OCR service
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      _logger.logOcr('Initializing OCR service');

      // Check camera permission
      final permissionStatus = await _checkCameraPermission();
      if (!permissionStatus) {
        _logger.logOcr('Camera permission denied', success: false);
        return false;
      }

      // Get available cameras
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        _logger.logOcr('No cameras available', success: false);
        return false;
      }

      _logger.logOcr('Found ${_cameras!.length} cameras');

      // Initialize camera controller with the back camera
      final backCamera = _cameras!.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras!.first,
      );

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      _isInitialized = true;

      _logger.logOcr('OCR service initialized successfully');
      notifyListeners();
      return true;
    } catch (e, stackTrace) {
      _logger.logError('Failed to initialize OCR service',
          error: e, stackTrace: stackTrace, category: 'OCR');
      return false;
    }
  }

  // Capture and process image for text extraction
  Future<String?> captureAndExtractText() async {
    if (!_isInitialized || _cameraController == null) {
      await initialize();
      if (!_isInitialized) return null;
    }

    if (_isProcessing) {
      _logger.logOcr('OCR processing already in progress', success: false);
      return null;
    }

    _isProcessing = true;
    notifyListeners();

    final stopwatch = Stopwatch()..start();

    try {
      _logger.logOcr('Capturing image for text extraction');

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
      
      stopwatch.stop();
      _logger.logPerformance('OCR text extraction', stopwatch.elapsed);

      // Clean up the temporary image file
      try {
        await image.delete();
      } catch (e) {
        _logger.logApp('Failed to delete temporary image file',
            level: LogLevel.warning, data: {'error': e.toString()});
      }

      return extractedText;
    } catch (e, stackTrace) {
      stopwatch.stop();
      _logger.logError('Failed to capture and extract text',
          error: e, stackTrace: stackTrace, category: 'OCR');
      return null;
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

  /// Fuzzy batch matching using Levenshtein distance and expiry validation
  /// Returns a list of matches with similarity >= [similarityThreshold] and valid expiry
  List<BatchMatchResult> findBestBatchMatches({
    required String extractedBatch,
    required String? extractedExpiry,
    required List<dynamic> batches, // List<BatchModel> or Map
    double similarityThreshold = 0.75,
  }) {
    final startTime = DateTime.now();
    
    _logger.logOcr('MATCH_START: Beginning batch matching process');
    _logger.logOcr('MATCH_INPUT_BATCH: Extracted batch text: "$extractedBatch"');
    _logger.logOcr('MATCH_INPUT_EXPIRY: Extracted expiry: "$extractedExpiry"');
    _logger.logOcr('MATCH_AVAILABLE_BATCHES: ${batches.length} batches available for matching');
    _logger.logOcr('MATCH_THRESHOLD: Similarity threshold: ${(similarityThreshold * 100).toStringAsFixed(1)}%');
    
    final List<BatchMatchResult> results = [];
    final normalizedExtracted = extractedBatch.trim().toUpperCase();
    
    _logger.logOcr('MATCH_NORMALIZED: Normalized extracted batch: "$normalizedExtracted"');
    
    // Log available batches for comparison
    _logger.logOcr('MATCH_BATCH_LIST: Available batches:');
    for (int idx = 0; idx < batches.length; idx++) {
      final batch = batches[idx];
      final batchNumber = (batch.batchNumber ?? batch.batchId ?? '').toString();
      _logger.logOcr('MATCH_AVAILABLE_${idx + 1}: "$batchNumber" | Expires: ${batch.expiryDate}');
    }
    
    for (final batch in batches) {
      final batchNumber = (batch.batchNumber ?? batch.batchId ?? '').toString().trim().toUpperCase();
      if (batchNumber.isEmpty) {
        _logger.logOcr('MATCH_SKIP: Skipping batch with empty batch number');
        continue;
      }

      _logger.logOcr('MATCH_COMPARE: Comparing "$normalizedExtracted" with "$batchNumber"');

      // Check for exact match first
      if (normalizedExtracted == batchNumber) {
        _logger.logOcr('MATCH_EXACT: Found exact match! "$normalizedExtracted" = "$batchNumber"');
        
        // Check expiry validity for exact match
        final expiryValid = extractedExpiry != null ? 
            _isExpiryValid(extractedExpiry, batch.expiryDate ?? '') : true;
        
        _logger.logOcr('MATCH_EXACT_EXPIRY: Expiry validation: $expiryValid');
        
        results.add(BatchMatchResult(
          batch: batch,
          similarity: 1.0, // 100% as decimal
          expiryValid: expiryValid,
        ));
        continue;
      }

      // Sliding window: compare all substrings of batchNumber with extractedBatch
      final windowSize = normalizedExtracted.length;
      double bestSim = 0.0;
      String bestSubstring = '';
      
      _logger.logOcr('MATCH_FUZZY_START: Starting fuzzy matching with window size $windowSize');
      
      for (int i = 0; i <= batchNumber.length - windowSize; i++) {
        final sub = batchNumber.substring(i, i + windowSize);
        final sim = _levenshteinSimilarity(normalizedExtracted, sub);
        if (sim > bestSim) {
          bestSim = sim;
          bestSubstring = sub;
        }
      }
      
      _logger.logOcr('MATCH_FUZZY_RESULT: Best substring match "$bestSubstring" with ${(bestSim * 100).toStringAsFixed(1)}% similarity');
      
      // Also compare full batch number
      final fullSim = _levenshteinSimilarity(normalizedExtracted, batchNumber);
      if (fullSim > bestSim) {
        bestSim = fullSim;
        bestSubstring = batchNumber;
      }
      
      _logger.logOcr('MATCH_FULL_COMPARISON: Full batch comparison similarity: ${(fullSim * 100).toStringAsFixed(1)}%');

      // Expiry validation (if extractedExpiry is present)
      bool expiryValid = true;
      if (extractedExpiry != null && batch.expiryDate != null) {
        expiryValid = _isExpiryValid(extractedExpiry, batch.expiryDate);
        _logger.logOcr('MATCH_EXPIRY_CHECK: Expiry validation result: $expiryValid');
      } else {
        _logger.logOcr('MATCH_EXPIRY_SKIP: No expiry data to validate');
      }

      final similarityPercentage = (bestSim * 100).toStringAsFixed(1);
      _logger.logOcr('MATCH_THRESHOLD_CHECK: Best similarity $similarityPercentage% vs threshold ${(similarityThreshold * 100).toStringAsFixed(1)}%');

      if (bestSim >= similarityThreshold && expiryValid) {
        _logger.logOcr('MATCH_ACCEPTED: Adding batch "${batch.batchNumber}" to results with $similarityPercentage% similarity');
        results.add(BatchMatchResult(
          batch: batch,
          similarity: bestSim,
          expiryValid: expiryValid,
        ));
      } else {
        _logger.logOcr('MATCH_REJECTED: Batch "${batch.batchNumber}" rejected - Similarity: $similarityPercentage%, Expiry: $expiryValid');
      }
    }
    
    final processingTime = DateTime.now().difference(startTime).inMilliseconds;
    
    // Sort by similarity descending
    results.sort((a, b) => b.similarity.compareTo(a.similarity));
    
    _logger.logOcr('MATCH_COMPLETE: Found ${results.length} matches in ${processingTime}ms');
    
    // Log final results
    if (results.isNotEmpty) {
      _logger.logOcr('MATCH_RESULTS: Top matches:');
      for (int i = 0; i < results.length && i < 3; i++) {
        final result = results[i];
        final percentage = (result.similarity * 100).toStringAsFixed(1);
        _logger.logOcr('MATCH_RESULT_${i + 1}: ${result.batch.batchNumber} ($percentage% similarity, Expiry: ${result.expiryValid})');
      }
    } else {
      _logger.logOcr('MATCH_NO_RESULTS: No matches found above threshold');
    }
    
    return results;
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

  // Helper method to validate expiry dates
  bool _isExpiryValid(String extractedExpiry, String batchExpiry) {
    try {
      _logger.logOcr('EXPIRY_CHECK: Comparing extracted "$extractedExpiry" with batch "$batchExpiry"');
      
      if (extractedExpiry.isEmpty || batchExpiry.isEmpty) {
        _logger.logOcr('EXPIRY_CHECK: Empty dates - assuming valid');
        return true;
      }
      
      // Parse both dates with comprehensive format support
      final extractedDate = _parseAnyDateFormat(extractedExpiry);
      final batchDate = _parseAnyDateFormat(batchExpiry);
      
      if (extractedDate == null || batchDate == null) {
        _logger.logOcr('EXPIRY_CHECK: Could not parse dates - assuming valid');
        _logger.logOcr('EXPIRY_PARSE_FAIL: Extracted: "$extractedExpiry" → $extractedDate, Batch: "$batchExpiry" → $batchDate');
        return true;
      }
      
      final daysDifference = batchDate.difference(extractedDate).inDays.abs();
      final isValid = daysDifference <= 30; // Allow 30 days difference
      
      _logger.logOcr('EXPIRY_CHECK: Parsed dates - Extracted: ${DateFormat('yyyy-MM-dd').format(extractedDate)}, Batch: ${DateFormat('yyyy-MM-dd').format(batchDate)}');
      _logger.logOcr('EXPIRY_CHECK: Date difference: $daysDifference days, Valid: $isValid');
      
      return isValid;
      
    } catch (e) {
      _logger.logOcr('EXPIRY_CHECK: Error validating expiry - $e, assuming valid');
      return true;
    }
  }

  // Comprehensive date parser supporting ALL possible formats
  DateTime? _parseAnyDateFormat(String dateStr) {
    if (dateStr.isEmpty) return null;
    
    try {
      _logger.logOcr('DATE_PARSE_START: Attempting to parse "$dateStr"');
      
      // Clean the input
      String cleanDate = dateStr.trim().replaceAll(RegExp(r'[^\w\-/.]'), ' ').trim();
      _logger.logOcr('DATE_PARSE_CLEAN: Cleaned to "$cleanDate"');
      
      // Comprehensive list of date formats to try
      final dateFormats = [
        // DD/MM/YYYY variants
        'dd/MM/yyyy', 'dd/MM/yy', 'd/M/yyyy', 'd/M/yy',
        'dd.MM.yyyy', 'dd.MM.yy', 'd.M.yyyy', 'd.M.yy',
        'dd-MM-yyyy', 'dd-MM-yy', 'd-M-yyyy', 'd-M-yy',
        
        // MM/DD/YYYY variants (US format)
        'MM/dd/yyyy', 'MM/dd/yy', 'M/d/yyyy', 'M/d/yy',
        'MM.dd.yyyy', 'MM.dd.yy', 'M.d.yyyy', 'M.d.yy',
        'MM-dd-yyyy', 'MM-dd-yy', 'M-d-yyyy', 'M-d-yy',
        
        // YYYY-MM-DD variants (ISO format)
        'yyyy-MM-dd', 'yyyy-M-d', 'yyyy/MM/dd', 'yyyy/M/d',
        'yyyy.MM.dd', 'yyyy.M.d',
        
        // YYYY-DD-MM variants
        'yyyy-dd-MM', 'yyyy-d-M', 'yyyy/dd/MM', 'yyyy/d/M',
        
        // Month year only formats
        'MM/yyyy', 'M/yyyy', 'MM-yyyy', 'M-yyyy', 'MM.yyyy', 'M.yyyy',
        'MMM yyyy', 'MMM-yyyy', 'MMM.yyyy', 'MMM/yyyy',
        'MMMM yyyy', 'MMMM-yyyy', 'MMMM.yyyy', 'MMMM/yyyy',
        
        // DD MMM YYYY formats
        'dd MMM yyyy', 'd MMM yyyy', 'dd-MMM-yyyy', 'd-MMM-yyyy',
        'dd.MMM.yyyy', 'd.MMM.yyyy', 'dd/MMM/yyyy', 'd/MMM/yyyy',
        
        // MMM DD YYYY formats
        'MMM dd yyyy', 'MMM d yyyy', 'MMM-dd-yyyy', 'MMM-d-yyyy',
        'MMM.dd.yyyy', 'MMM.d.yyyy', 'MMM/dd/yyyy', 'MMM/d/yyyy',
        
        // Compact formats
        'ddMMyyyy', 'ddMMyy', 'yyyyMMdd', 'yyyyddMM', 'MMddyyyy',
        
        // Edge cases
        'yyyy', 'yy'
      ];
      
      // Try each format
      for (String format in dateFormats) {
        try {
          final formatter = DateFormat(format);
          final parsedDate = formatter.parseStrict(cleanDate);
          
          _logger.logOcr('DATE_PARSE_SUCCESS: "$cleanDate" parsed as ${DateFormat('yyyy-MM-dd').format(parsedDate)} using format "$format"');
          return parsedDate;
          
        } catch (e) {
          // Continue to next format
          continue;
        }
      }
      
      // Try manual parsing for irregular formats
      final manualParsed = _tryManualDateParsing(cleanDate);
      if (manualParsed != null) {
        _logger.logOcr('DATE_PARSE_MANUAL: "$cleanDate" parsed manually as ${DateFormat('yyyy-MM-dd').format(manualParsed)}');
        return manualParsed;
      }
      
      _logger.logOcr('DATE_PARSE_FAILED: Could not parse "$dateStr" with any known format');
      return null;
      
    } catch (e) {
      _logger.logOcr('DATE_PARSE_ERROR: Exception parsing "$dateStr" - $e');
      return null;
    }
  }
  
  // Manual parsing for irregular date formats
  DateTime? _tryManualDateParsing(String dateStr) {
    try {
      // Extract numbers from string
      final numbers = RegExp(r'\d+').allMatches(dateStr).map((m) => int.parse(m.group(0)!)).toList();
      
      if (numbers.isEmpty) return null;
      
      // Single number - assume year
      if (numbers.length == 1) {
        int year = numbers[0];
        if (year < 100) year += 2000; // Convert 2-digit year
        if (year < 2000 || year > 2100) return null;
        return DateTime(year, 12, 31); // End of year
      }
      
      // Two numbers - assume month/year
      if (numbers.length == 2) {
        int first = numbers[0];
        int second = numbers[1];
        
        // Try MM/YYYY
        if (first <= 12 && second > 31) {
          int year = second < 100 ? second + 2000 : second;
          return DateTime(year, first, DateTime(year, first + 1, 0).day); // Last day of month
        }
        
        // Try YYYY/MM  
        if (first > 31 && second <= 12) {
          int year = first < 100 ? first + 2000 : first;
          return DateTime(year, second, DateTime(year, second + 1, 0).day); // Last day of month
        }
      }
      
      // Three numbers - assume DD/MM/YYYY or MM/DD/YYYY or YYYY/MM/DD
      if (numbers.length == 3) {
        int first = numbers[0];
        int second = numbers[1];
        int third = numbers[2];
        
        // Convert 2-digit years
        if (third < 100) third += 2000;
        if (first > 1900 && first < 2100) first = first; // Already 4-digit
        if (second > 1900 && second < 2100) second = second; // Already 4-digit
        
        // Try YYYY/MM/DD
        if (first > 1900 && first < 2100 && second <= 12 && third <= 31) {
          return DateTime(first, second, third);
        }
        
        // Try DD/MM/YYYY
        if (third > 1900 && third < 2100 && second <= 12 && first <= 31) {
          return DateTime(third, second, first);
        }
        
        // Try MM/DD/YYYY
        if (third > 1900 && third < 2100 && first <= 12 && second <= 31) {
          return DateTime(third, first, second);
        }
      }
      
      return null;
      
    } catch (e) {
      return null;
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
