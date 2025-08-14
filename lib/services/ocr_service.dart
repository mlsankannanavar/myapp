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
      
      // Read image bytes for storage
      final imageBytes = await image.readAsBytes();

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
        'imageBytes': imageBytes,
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

  /// Enhanced batch matching: searches for each batch number individually in extracted text
  /// Returns matches only if BOTH batch number (75%+ similarity) AND exact expiry date found
  List<BatchMatchResult> findBestBatchMatches({
    required String extractedText,
    required List<dynamic> batches, // List<BatchModel> or Map
    double similarityThreshold = 0.75,
  }) {
    final List<BatchMatchResult> exactMatches = [];
    final List<BatchMatchResult> nearestMatches = [];
    final normalizedText = extractedText.trim().toUpperCase();
    
    _logger.logOcr('MATCH_START: Beginning new batch matching process');
    _logger.logOcr('MATCH_INPUT_TEXT: Extracted text: "$extractedText"');
    _logger.logOcr('MATCH_AVAILABLE_BATCHES: ${batches.length} batches available for matching');

    for (final batch in batches) {
      final batchNumber = (batch.batchNumber ?? batch.batchId ?? '').toString().trim().toUpperCase();
      if (batchNumber.isEmpty) continue;

      // Step 1: Check if batch number exists in text with fuzzy matching
      final batchSimilarity = _findBatchNumberInText(batchNumber, normalizedText);
      
      if (batchSimilarity >= similarityThreshold) {
        _logger.logOcr('BATCH_FOUND: ${batchNumber} found with ${(batchSimilarity * 100).toInt()}% similarity');
        
        // Step 2: Check if batch expiry date exists exactly in text
        bool expiryFound = false;
        if (batch.expiryDate != null) {
          expiryFound = _searchBatchExpiryInText(batch.expiryDate.toString(), extractedText);
          _logger.logOcr('EXPIRY_CHECK: ${batch.expiryDate} ${expiryFound ? 'FOUND' : 'NOT FOUND'} in text');
        } else {
          // If no expiry date in batch, consider it valid
          expiryFound = true;
          _logger.logOcr('EXPIRY_CHECK: No expiry date in batch, considering valid');
        }
        
        if (expiryFound) {
          // Both conditions met - exact match
          exactMatches.add(BatchMatchResult(
            batch: batch,
            similarity: batchSimilarity,
            expiryValid: true,
          ));
          _logger.logOcr('EXACT_MATCH: Added ${batchNumber} as exact match (batch + expiry found)');
        } else {
          // Only batch found, not expiry - add to nearest matches
          nearestMatches.add(BatchMatchResult(
            batch: batch,
            similarity: batchSimilarity,
            expiryValid: false,
          ));
          _logger.logOcr('NEAREST_MATCH: Added ${batchNumber} as nearest match (batch found, expiry missing)');
        }
      } else {
        // Batch similarity below threshold, but add to nearest for potential fallback
        nearestMatches.add(BatchMatchResult(
          batch: batch,
          similarity: batchSimilarity,
          expiryValid: false,
        ));
      }
    }
    
    // Sort exact matches by similarity (highest first)
    exactMatches.sort((a, b) => b.similarity.compareTo(a.similarity));
    
    if (exactMatches.isNotEmpty) {
      _logger.logOcr('MATCH_RESULTS: Found ${exactMatches.length} exact matches (batch + expiry)');
      return exactMatches;
    }
    
    // No exact matches - return top 2 nearest matches for user decision
    nearestMatches.sort((a, b) => b.similarity.compareTo(a.similarity));
    final topNearest = nearestMatches.take(2).toList();
    
    _logger.logOcr('MATCH_RESULTS: No exact matches found, returning ${topNearest.length} nearest matches for user decision');
    return topNearest;
  }
  
  /// Simplified batch number search: check if batch number exists in text with fuzzy matching
  /// No sliding window - just basic contains check with Levenshtein similarity
  double _findBatchNumberInText(String batchNumber, String extractedText) {
    _logger.logOcr('BATCH_SEARCH: Looking for "$batchNumber" in text');
    
    // Direct contains check (case-insensitive)
    if (extractedText.contains(batchNumber)) {
      _logger.logOcr('BATCH_SEARCH: Exact match found for "$batchNumber"');
      return 1.0; // 100% similarity for exact match
    }
    
    // Fuzzy matching - check similarity with each word/segment in text
    double bestSimilarity = 0.0;
    final words = extractedText.split(RegExp(r'\s+'));
    
    for (final word in words) {
      if (word.length >= batchNumber.length - 2) { // Only check words of reasonable length
        final similarity = _levenshteinSimilarity(batchNumber, word);
        if (similarity > bestSimilarity) {
          bestSimilarity = similarity;
        }
      }
    }
    
    // Also check against continuous segments of similar length
    final batchLength = batchNumber.length;
    for (int i = 0; i <= extractedText.length - batchLength; i++) {
      final segment = extractedText.substring(i, i + batchLength);
      final similarity = _levenshteinSimilarity(batchNumber, segment);
      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
      }
    }
    
    _logger.logOcr('BATCH_SEARCH: Best similarity for "$batchNumber": ${(bestSimilarity * 100).toInt()}%');
    return bestSimilarity;
  }
  
  /// Search for batch expiry date in extracted text using multiple formats
  /// Requires 100% exact match for any of the generated date formats
  bool _searchBatchExpiryInText(String batchExpiryDate, String extractedText) {
    _logger.logOcr('EXPIRY_SEARCH: Looking for expiry "$batchExpiryDate" in text');
    
    // Generate multiple date formats from the batch expiry date
    final dateFormats = _generateDateFormats(batchExpiryDate);
    
    _logger.logOcr('EXPIRY_SEARCH: Generated ${dateFormats.length} formats to search: $dateFormats');
    
    final normalizedText = extractedText.toUpperCase();
    
    for (final format in dateFormats) {
      final normalizedFormat = format.toUpperCase();
      if (normalizedText.contains(normalizedFormat)) {
        _logger.logOcr('EXPIRY_SEARCH: EXACT MATCH found for format "$format"');
        return true;
      }
    }
    
    _logger.logOcr('EXPIRY_SEARCH: No exact matches found for any format');
    return false;
  }
  
  /// Generate multiple date formats from a given date string
  List<String> _generateDateFormats(String dateStr) {
    final formats = <String>[];
    
    try {
      // Try to parse the input date
      DateTime? date;
      final cleanDateStr = dateStr.trim();
      
      // Common input formats to try parsing
      final inputFormats = [
        'yyyy-MM-dd', 'dd/MM/yyyy', 'MM/dd/yyyy', 'dd-MM-yyyy', 
        'MM-dd-yyyy', 'yyyy/MM/dd', 'dd MMM yyyy', 'MMM dd yyyy',
        'dd-MMM-yyyy', 'yyyy-MMM-dd'
      ];
      
      for (final inputFormat in inputFormats) {
        try {
          date = DateFormat(inputFormat).parse(cleanDateStr);
          break;
        } catch (e) {
          continue;
        }
      }
      
      if (date == null) {
        _logger.logOcr('DATE_FORMAT: Failed to parse date "$dateStr", using as-is');
        return [dateStr]; // Return original if can't parse
      }
      
      // Generate various output formats
      final outputFormats = [
        'dd/MM/yyyy',   // 31/03/2026
        'MM/yyyy',      // 03/2026
        'dd-MM-yyyy',   // 31-03-2026
        'MM-yyyy',      // 03-2026
        'yyyy-MM-dd',   // 2026-03-31
        'dd/MM/yy',     // 31/03/26
        'MM/yy',        // 03/26
        'dd-MM-yy',     // 31-03-26
        'MM-yy',        // 03-26
        'dd.MM.yyyy',   // 31.03.2026
        'MM.yyyy',      // 03.2026
        'ddMMyyyy',     // 31032026
        'MMyyyy',       // 032026
        'ddMMyy',       // 310326
        'MMyy',         // 0326
        'dd MMM yyyy',  // 31 MAR 2026
        'MMM yyyy',     // MAR 2026
        'dd-MMM-yyyy',  // 31-MAR-2026
        'MMM-yyyy',     // MAR-2026
        'yyyy-MMM-dd',  // 2026-MAR-31
        'yyyy MMM dd',  // 2026 MAR 31
      ];
      
      for (final outputFormat in outputFormats) {
        try {
          final formatted = DateFormat(outputFormat).format(date);
          if (!formats.contains(formatted)) {
            formats.add(formatted);
          }
        } catch (e) {
          // Skip invalid formats
          continue;
        }
      }
      
      _logger.logOcr('DATE_FORMAT: Generated ${formats.length} formats from "$dateStr"');
      return formats;
      
    } catch (e) {
      _logger.logOcr('DATE_FORMAT: Error generating formats for "$dateStr": $e');
      return [dateStr]; // Return original if error
    }
  }
  
  /// Find nearest batch matches for fallback when no exact matches found
  /// Returns the top matches by similarity for user selection
  List<BatchMatchResult> findNearestBatchMatches({
    required String extractedText,
    required List<dynamic> batches,
    int maxResults = 2,
  }) {
    final List<BatchMatchResult> allMatches = [];
    final normalizedText = extractedText.trim().toUpperCase();
    
    _logger.logOcr('NEAREST_SEARCH: Finding nearest matches (no exact expiry match required)');
    
    for (final batch in batches) {
      final batchNumber = (batch.batchNumber ?? batch.batchId ?? '').toString().trim().toUpperCase();
      if (batchNumber.isEmpty) continue;

      final similarity = _findBatchNumberInText(batchNumber, normalizedText);
      
      allMatches.add(BatchMatchResult(
        batch: batch,
        similarity: similarity,
        expiryValid: false, // Mark as not having exact expiry match
      ));
    }
    
    // Sort by similarity and take top results
    allMatches.sort((a, b) => b.similarity.compareTo(a.similarity));
    final result = allMatches.take(maxResults).toList();
    
    _logger.logOcr('NEAREST_SEARCH: Returning ${result.length} nearest matches');
    return result;
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
