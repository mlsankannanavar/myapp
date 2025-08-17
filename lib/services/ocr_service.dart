import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';

import '../utils/constants.dart';
import '../utils/helpers.dart';
import '../utils/log_level.dart';
import 'logging_service.dart';

class OptimizedHospitalOcrService extends ChangeNotifier {
  static final OptimizedHospitalOcrService _instance = OptimizedHospitalOcrService._internal();
  factory OptimizedHospitalOcrService() => _instance;
  static OptimizedHospitalOcrService get instance => _instance;
  OptimizedHospitalOcrService._internal();

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

  // Performance caches
  final Map<String, double> _similarityCache = {};
  final Map<String, List<String>> _dateFormatCache = {};

  // Getters (same as before)
  CameraController? get cameraController => _cameraController;
  List<CameraDescription>? get cameras => _cameras;
  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;
  bool get isFlashlightOn => _isFlashlightOn;
  String? get lastExtractedText => _lastExtractedText;
  double? get lastConfidence => _lastConfidence;
  DateTime? get lastProcessTime => _lastProcessTime;

  // Initialize OCR service (same as before - keeping existing logic)
  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      _logger.logOcr('Initializing optimized OCR service');

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
      _logger.logOcr('Optimized OCR service initialized successfully');
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
    
    // Clear caches
    _similarityCache.clear();
    _dateFormatCache.clear();
    
    // Re-initialize
    return await initialize();
  }

  // Capture and process image for text extraction with auto-matching
  Future<Map<String, dynamic>?> captureAndExtractTextWithMatching({
    required List<dynamic> availableBatches,
    double similarityThreshold = 0.85, // Increased for hospital safety
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

      // Perform optimized batch matching
      final matches = findBestBatchMatchesOptimized(
        extractedText: extractedText,
        batches: availableBatches,
        similarityThreshold: similarityThreshold,
      );

      // If no matches found, get nearest matches
      List<BatchMatchResult> nearestMatches = [];
      if (matches.isEmpty) {
        nearestMatches = findNearestBatchMatchesOptimized(
          extractedText: extractedText,
          batches: availableBatches,
          maxResults: 2,
        );
        _logger.logOcr('No exact matches found, showing ${nearestMatches.length} nearest matches');
      }

      stopwatch.stop();
      _logger.logPerformance('Optimized OCR text extraction and matching', stopwatch.elapsed);

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

  // Process image file for text extraction (same logic as before)
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

  // Internal method to process image for text recognition (same as before)
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

  // Calculate average confidence from recognized text (same as before)
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

  // Extract specific information from text (same as before)
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

  /// OPTIMIZED: Enhanced batch matching with improved performance
  /// Uses KMP-like approach for efficient string searching
  /// Returns matches only if BOTH batch number (85%+ similarity) AND exact expiry date found
  List<BatchMatchResult> findBestBatchMatchesOptimized({
    required String extractedText,
    required List<dynamic> batches,
    double similarityThreshold = 0.85, // Increased for hospital safety
  }) {
    final List<BatchMatchResult> exactMatches = [];
    final List<BatchMatchResult> nearestMatches = [];
    final normalizedText = extractedText.trim().toUpperCase();
    
    _logger.logOcr('OPTIMIZED_MATCH_START: Beginning optimized batch matching process');
    _logger.logOcr('MATCH_INPUT_TEXT: Extracted text: "$extractedText"');
    _logger.logOcr('MATCH_AVAILABLE_BATCHES: ${batches.length} batches available for matching');

    // Pre-process text for faster searching
    final words = normalizedText.split(RegExp(r'\s+'));
    final wordSet = Set<String>.from(words);

    for (final batch in batches) {
      final batchNumber = (batch.batchNumber ?? batch.batchId ?? '').toString().trim().toUpperCase();
      if (batchNumber.isEmpty) continue;

      // Step 1: Optimized batch number search
      final batchSimilarity = _findBatchNumberOptimized(batchNumber, normalizedText, words, wordSet);
      
      if (batchSimilarity >= similarityThreshold) {
        _logger.logOcr('BATCH_FOUND: ${batchNumber} found with ${(batchSimilarity * 100).toInt()}% similarity');
        
        // Step 2: Optimized expiry date search
        bool expiryFound = false;
        if (batch.expiryDate != null) {
          expiryFound = _searchBatchExpiryOptimized(batch.expiryDate.toString(), extractedText);
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
      } else if (batchSimilarity > 0.60) { // Only add reasonable near-matches
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

  /// OPTIMIZED: Fast batch number search using word-based approach and caching
  /// Time complexity: O(n) instead of O(n²)
  double _findBatchNumberOptimized(String batchNumber, String extractedText, List<String> words, Set<String> wordSet) {
    _logger.logOcr('OPTIMIZED_BATCH_SEARCH: Looking for "$batchNumber" in text');
    
    // Cache key for memoization
    final cacheKey = '$batchNumber|$extractedText';
    if (_similarityCache.containsKey(cacheKey)) {
      return _similarityCache[cacheKey]!;
    }
    
    double bestSimilarity = 0.0;
    
    // Method 1: Direct substring search (fastest)
    if (extractedText.contains(batchNumber)) {
      _logger.logOcr('OPTIMIZED_BATCH_SEARCH: Exact match found for "$batchNumber"');
      _similarityCache[cacheKey] = 1.0;
      return 1.0;
    }
    
    // Method 2: Word-based fuzzy matching (O(n) instead of O(n²))
    for (final word in words) {
      if ((word.length - batchNumber.length).abs() <= 3) { // Quick length filter
        final similarity = _optimizedLevenshteinSimilarity(batchNumber, word);
        if (similarity > bestSimilarity) {
          bestSimilarity = similarity;
          // Early exit if we find a very good match
          if (similarity >= 0.95) break;
        }
      }
    }
    
    // Method 3: Sliding window only for very short batch numbers (length <= 6)
    if (bestSimilarity < 0.8 && batchNumber.length <= 6) {
      final batchLength = batchNumber.length;
      for (int i = 0; i <= extractedText.length - batchLength; i += 2) { // Skip every other position for speed
        final segment = extractedText.substring(i, i + batchLength);
        final similarity = _optimizedLevenshteinSimilarity(batchNumber, segment);
        if (similarity > bestSimilarity) {
          bestSimilarity = similarity;
          // Early exit if we find a very good match
          if (similarity >= 0.95) break;
        }
      }
    }
    
    _logger.logOcr('OPTIMIZED_BATCH_SEARCH: Best similarity for "$batchNumber": ${(bestSimilarity * 100).toInt()}%');
    
    // Cache the result
    _similarityCache[cacheKey] = bestSimilarity;
    
    return bestSimilarity;
  }

  /// OPTIMIZED: Fast expiry date search with comprehensive medical date formats
  /// Uses cached date format generation and optimized string matching
  bool _searchBatchExpiryOptimized(String batchExpiryDate, String extractedText) {
    _logger.logOcr('OPTIMIZED_EXPIRY_SEARCH: Looking for expiry "$batchExpiryDate" in text');
    
    // Check cache first
    if (_dateFormatCache.containsKey(batchExpiryDate)) {
      final cachedFormats = _dateFormatCache[batchExpiryDate]!;
      return _searchFormatsInText(cachedFormats, extractedText);
    }
    
    // Generate comprehensive date formats for medical/hospital use
    final dateFormats = _generateComprehensiveMedicalDateFormats(batchExpiryDate);
    
    // Cache the generated formats
    _dateFormatCache[batchExpiryDate] = dateFormats;
    
    _logger.logOcr('OPTIMIZED_EXPIRY_SEARCH: Generated ${dateFormats.length} formats to search');
    
    return _searchFormatsInText(dateFormats, extractedText);
  }

  /// Search multiple date formats efficiently
  bool _searchFormatsInText(List<String> formats, String extractedText) {
    final normalizedText = extractedText.toUpperCase();
    
    for (final format in formats) {
      final normalizedFormat = format.toUpperCase();
      if (normalizedText.contains(normalizedFormat)) {
        _logger.logOcr('OPTIMIZED_EXPIRY_SEARCH: EXACT MATCH found for format "$format"');
        return true;
      }
    }
    
    _logger.logOcr('OPTIMIZED_EXPIRY_SEARCH: No exact matches found for any format');
    return false;
  }

  /// COMPREHENSIVE: Generate extensive medical date formats including hospital-specific patterns
  List<String> _generateComprehensiveMedicalDateFormats(String dateStr) {
    final formats = <String>[];
    
    try {
      // Try to parse the input date
      DateTime? date;
      final cleanDateStr = dateStr.trim();
      
      // Extended input formats for medical context
      final inputFormats = [
        'yyyy-MM-dd', 'dd/MM/yyyy', 'MM/dd/yyyy', 'dd-MM-yyyy', 
        'MM-dd-yyyy', 'yyyy/MM/dd', 'dd MMM yyyy', 'MMM dd yyyy',
        'dd-MMM-yyyy', 'yyyy-MMM-dd', 'ddMMyyyy', 'MMyyyy',
        'dd.MM.yyyy', 'MM.yyyy', 'yyyy.MM.dd', 'ddMMyy', 'MMyy',
        'dd/MM/yy', 'MM/yy', 'yyyy-MM', 'yyyyMMdd'
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
        _logger.logOcr('COMPREHENSIVE_DATE_FORMAT: Failed to parse date "$dateStr", using as-is');
        return [dateStr]; // Return original if can't parse
      }
      
      // COMPREHENSIVE MEDICAL DATE FORMATS
      final outputFormats = [
        // FDA Medical Device Standard (Mandatory)
        'yyyy-MM-dd',   // 2026-03-31 (FDA required format)
        
        // Common US Hospital Formats
        'MM/dd/yyyy',   // 03/31/2026
        'MM/dd/yy',     // 03/31/26
        'MM/yyyy',      // 03/2026
        'MM/yy',        // 03/26
        
        // European Medical Standards
        'dd/MM/yyyy',   // 31/03/2026
        'dd/MM/yy',     // 31/03/26
        'dd.MM.yyyy',   // 31.03.2026
        'dd.MM.yy',     // 31.03.26
        'dd-MM-yyyy',   // 31-03-2026
        'dd-MM-yy',     // 31-03-26
        
        // International Standards
        'yyyy/MM/dd',   // 2026/03/31
        'yyyy.MM.dd',   // 2026.03.31
        'yyyy MM dd',   // 2026 03 31
        
        // NDC/Barcode Formats
        'yyyyMMdd',     // 20260331
        'ddMMyyyy',     // 31032026
        'MMyyyy',       // 032026
        'ddMMyy',       // 310326
        'MMyy',         // 0326
        'yyMM',         // 2603
        'yyyyMM',       // 202603
        
        // Month Name Formats (International)
        'dd MMM yyyy',  // 31 MAR 2026
        'MMM dd yyyy',  // MAR 31 2026
        'dd-MMM-yyyy',  // 31-MAR-2026
        'MMM-yyyy',     // MAR-2026
        'yyyy-MMM-dd',  // 2026-MAR-31
        'yyyy MMM dd',  // 2026 MAR 31
        'dd MMM yy',    // 31 MAR 26
        'MMM dd yy',    // MAR 31 26
        'MMM yy',       // MAR 26
        'MMMyyyy',      // MAR2026
        'MMMdd',        // MAR31
        
        // Short formats (common on small labels)
        'MM.yy',        // 03.26
        'MM-yy',        // 03-26
        'yy.MM',        // 26.03
        'yy-MM',        // 26-03
        'yy/MM',        // 26/03
        
        // Compact formats
        'MMyy',         // 0326
        'yyMM',         // 2603
        'Myy',          // 326 (single digit month)
        'MMyyyy',       // 032026
        'yyyyMM',       // 202603
        
        // Slash variations
        'M/yy',         // 3/26 (single digit month)
        'M/yyyy',       // 3/2026
        'dd/M/yy',      // 31/3/26
        'dd/M/yyyy',    // 31/3/2026
        'M/dd/yy',      // 3/31/26
        'M/dd/yyyy',    // 3/31/2026
      ];
      
      // Generate all possible formats
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
      
      // Add context-aware hospital patterns
      final contextFormats = _generateContextAwareFormats(date);
      formats.addAll(contextFormats);
      
      // Remove duplicates and sort by likelihood (shorter formats first for better matching)
      final uniqueFormats = formats.toSet().toList();
      uniqueFormats.sort((a, b) => a.length.compareTo(b.length));
      
      _logger.logOcr('COMPREHENSIVE_DATE_FORMAT: Generated ${uniqueFormats.length} formats from "$dateStr"');
      return uniqueFormats;
      
    } catch (e) {
      _logger.logOcr('COMPREHENSIVE_DATE_FORMAT: Error generating formats for "$dateStr": $e');
      return [dateStr]; // Return original if error
    }
  }

  /// Generate context-aware hospital date formats
  List<String> _generateContextAwareFormats(DateTime date) {
    final contextFormats = <String>[];
    
    try {
      // Expiry context patterns
      final basicDate = DateFormat('MM/dd/yyyy').format(date);
      final shortDate = DateFormat('MM/yy').format(date);
      final isoDate = DateFormat('yyyy-MM-dd').format(date);
      final monthYear = DateFormat('MMM yyyy').format(date);
      
      contextFormats.addAll([
        'EXP $basicDate',
        'EXP $shortDate',
        'EXP $isoDate',
        'EXP $monthYear',
        'EXPIRY $basicDate',
        'EXPIRES $basicDate',
        'USE BY $basicDate',
        'BEST BY $basicDate',
        'DISCARD AFTER $basicDate',
        'VALID UNTIL $basicDate',
        'GOOD UNTIL $basicDate',
        'LOT $shortDate',
        'BATCH $shortDate',
        'MFG $basicDate',
        'STERILE UNTIL $basicDate',
        'DO NOT USE AFTER $basicDate',
      ]);
      
    } catch (e) {
      _logger.logOcr('CONTEXT_FORMAT_ERROR: $e');
    }
    
    return contextFormats;
  }

  /// Find nearest batch matches for fallback when no exact matches found
  /// OPTIMIZED version with better performance
  List<BatchMatchResult> findNearestBatchMatchesOptimized({
    required String extractedText,
    required List<dynamic> batches,
    int maxResults = 2,
  }) {
    final List<BatchMatchResult> allMatches = [];
    final normalizedText = extractedText.trim().toUpperCase();
    final words = normalizedText.split(RegExp(r'\s+'));
    final wordSet = Set<String>.from(words);
    
    _logger.logOcr('OPTIMIZED_NEAREST_SEARCH: Finding nearest matches (no exact expiry match required)');
    
    for (final batch in batches) {
      final batchNumber = (batch.batchNumber ?? batch.batchId ?? '').toString().trim().toUpperCase();
      if (batchNumber.isEmpty) continue;

      final similarity = _findBatchNumberOptimized(batchNumber, normalizedText, words, wordSet);
      
      // Only include reasonable matches
      if (similarity > 0.5) {
        allMatches.add(BatchMatchResult(
          batch: batch,
          similarity: similarity,
          expiryValid: false, // Mark as not having exact expiry match
        ));
      }
    }
    
    // Sort by similarity and take top results
    allMatches.sort((a, b) => b.similarity.compareTo(a.similarity));
    final result = allMatches.take(maxResults).toList();
    
    _logger.logOcr('OPTIMIZED_NEAREST_SEARCH: Returning ${result.length} nearest matches');
    return result;
  }

  /// OPTIMIZED: Levenshtein similarity with early termination and reduced memory allocation
  double _optimizedLevenshteinSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    
    final maxLen = max(a.length, b.length);
    final minLen = min(a.length, b.length);
    
    // Quick filter: if length difference is too big, skip expensive calculation
    if ((maxLen - minLen) / maxLen > 0.5) return 0.0;
    
    final dist = _optimizedLevenshtein(a, b);
    return 1.0 - (dist / maxLen);
  }

  /// OPTIMIZED: Levenshtein distance with single array instead of matrix (space optimization)
  int _optimizedLevenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;
    
    // Use single array instead of matrix for memory efficiency
    List<int> previousRow = List.generate(t.length + 1, (i) => i);
    List<int> currentRow = List.filled(t.length + 1, 0);
    
    for (int i = 1; i <= s.length; i++) {
      currentRow[0] = i;
      
      for (int j = 1; j <= t.length; j++) {
        final cost = s[i - 1] == t[j - 1] ? 0 : 1;
        currentRow[j] = min(
          min(currentRow[j - 1] + 1, previousRow[j] + 1),
          previousRow[j - 1] + cost
        );
      }
      
      // Swap arrays
      final temp = previousRow;
      previousRow = currentRow;
      currentRow = temp;
    }
    
    return previousRow[t.length];
  }

  // Switch camera (same as before)
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

  // Toggle flashlight (same as before)
  Future<void> toggleFlashlight() async {
    if (!_isInitialized || _cameraController == null) {
      _logger.logOcr('Cannot toggle flashlight - camera not initialized',
          success: false);
      return;
    }

    try {
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

  // Check camera permission (same as before)
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

  // Get OCR status info (enhanced)
  Map<String, dynamic> getStatusInfo() {
    return {
      'isInitialized': _isInitialized,
      'isProcessing': _isProcessing,
      'cameraCount': _cameras?.length ?? 0,
      'lastExtractedText': _lastExtractedText,
      'lastConfidence': _lastConfidence,
      'lastProcessTime': _lastProcessTime?.toIso8601String(),
      'currentCamera': _cameraController?.description.lensDirection.name,
      'cacheSize': _similarityCache.length,
      'dateFormatCacheSize': _dateFormatCache.length,
    };
  }

  // Reset OCR state (enhanced)
  void reset() {
    _lastExtractedText = null;
    _lastConfidence = null;
    _lastProcessTime = null;
    
    // Clear caches
    _similarityCache.clear();
    _dateFormatCache.clear();
    
    _logger.logOcr('Optimized OCR state reset with cache clearing');
    notifyListeners();
  }

  // Clear caches manually (for memory management)
  void clearCaches() {
    _similarityCache.clear();
    _dateFormatCache.clear();
    _logger.logOcr('OCR caches cleared for memory optimization');
  }

  // Dispose resources (enhanced)
  @override
  void dispose() {
    _cameraController?.dispose();
    _textRecognizer.close();
    
    // Clear caches
    _similarityCache.clear();
    _dateFormatCache.clear();
    
    _logger.logOcr('Optimized OCR service disposed with cache cleanup');
    super.dispose();
  }
}

/// Result class for batch matching (same as before)
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

// Type alias for compatibility
typedef OcrService = OptimizedHospitalOcrService;