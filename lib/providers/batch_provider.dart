import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/batch_model.dart';
import '../services/api_service.dart';
import '../services/logging_service.dart';
import '../utils/constants.dart';
import '../utils/log_level.dart';

enum BatchLoadingState { idle, loading, loaded, error }

class BatchProvider extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  final LoggingService _logger = LoggingService();
  
  Box<Map<dynamic, dynamic>>? _batchBox;
  List<BatchModel> _batches = [];
  BatchLoadingState _loadingState = BatchLoadingState.idle;
  String? _currentSessionId;
  String? _errorMessage;
  DateTime? _lastLoadTime;
  Duration? _lastLoadDuration;
  bool _isInitialized = false;
  
  // Statistics
  int _totalScans = 0;
  int _successfulSubmissions = 0;
  int _errorCount = 0;

  // Getters
  List<BatchModel> get batches => List.unmodifiable(_batches);
  BatchLoadingState get loadingState => _loadingState;
  String? get currentSessionId => _currentSessionId;
  String? get errorMessage => _errorMessage;
  DateTime? get lastLoadTime => _lastLoadTime;
  Duration? get lastLoadDuration => _lastLoadDuration;
  bool get isInitialized => _isInitialized;
  bool get isLoading => _loadingState == BatchLoadingState.loading;
  bool get hasError => _loadingState == BatchLoadingState.error;
  bool get hasBatches => _batches.isNotEmpty && _currentSessionId != null;
  bool get hasSession => _currentSessionId != null;
  int get batchCount => _batches.length;
  
  // Dynamic statistics
  int get totalScans => _totalScans;
  int get successfulSubmissions => _successfulSubmissions;
  int get errorCount => _errorCount;

  // Filtered getters
  List<BatchModel> get expiredBatches => _batches.where((batch) => batch.isExpired).toList();
  List<BatchModel> get validBatches => _batches.where((batch) => !batch.isExpired).toList();
  List<BatchModel> get batchesExpiringSoon => _batches.where((batch) {
    final days = batch.daysUntilExpiry;
    return days >= 0 && days <= 30;
  }).toList();

  BatchProvider() {
    _initializeProvider();
  }

  // Initialize the provider
  Future<void> _initializeProvider() async {
    try {
      _logger.logApp('Initializing BatchProvider');
      
      // Initialize Hive box for batch storage
      _batchBox = await Hive.openBox<Map<dynamic, dynamic>>(Constants.batchDataBoxKey);
      
      // Load cached batches
      await _loadCachedBatches();
      
      _isInitialized = true;
      _logger.logApp('BatchProvider initialized successfully',
          data: {'cachedBatchCount': _batches.length});
      
      notifyListeners();
    } catch (e, stackTrace) {
      _logger.logError('Failed to initialize BatchProvider',
          error: e, stackTrace: stackTrace);
    }
  }

  // Retry loading batches
  Future<void> retryLoadBatches() async {
    if (_currentSessionId != null) {
      await loadBatchesForSession(_currentSessionId!, forceRefresh: true);
    } else {
      _logger.logApp('Cannot retry batch loading - no session ID',
          level: LogLevel.warning);
    }
  }

  // Refresh batches for current session
  Future<void> refreshBatches() async {
    if (_currentSessionId != null) {
      await loadBatchesForSession(_currentSessionId!, forceRefresh: true);
    } else {
      _logger.logApp('Cannot refresh batches - no current session',
          level: LogLevel.warning);
    }
  }

  // Clear session and batches
  void clearSession() {
    _batches = [];
    _currentSessionId = null;
    _errorMessage = null;
    _loadingState = BatchLoadingState.idle;
    _logger.logApp('Session cleared');
    notifyListeners();
  }

  // Statistics methods
  void incrementScanCount() {
    _totalScans++;
    _logger.logApp('Scan count incremented', data: {'totalScans': _totalScans});
    notifyListeners();
  }

  void incrementSuccessCount() {
    _successfulSubmissions++;
    _logger.logApp('Success count incremented', data: {'successfulSubmissions': _successfulSubmissions});
    notifyListeners();
  }

  void incrementErrorCount() {
    _errorCount++;
    _logger.logApp('Error count incremented', data: {'errorCount': _errorCount});
    notifyListeners();
  }

  // Load batches for a specific session
  Future<void> loadBatchesForSession(String sessionId, {bool forceRefresh = false}) async {
    if (isLoading && !forceRefresh) {
      _logger.logApp('Batch loading already in progress');
      return;
    }

    _setLoadingState(BatchLoadingState.loading);
    _clearError();
    _currentSessionId = sessionId;

    final stopwatch = Stopwatch()..start();

    try {
      _logger.logApp('Loading batches for session', data: {'sessionId': sessionId});

      final response = await _apiService.getFilteredBatches(sessionId);
      
      if (response.isSuccess && response.data != null) {
        _batches = response.data!;
        _lastLoadTime = DateTime.now();
        _lastLoadDuration = stopwatch.elapsed;
        
        // Cache the batches
        await _cacheBatches();
        
        _setLoadingState(BatchLoadingState.loaded);
        _logger.logApp('Batches loaded successfully',
            data: {
              'sessionId': sessionId,
              'count': _batches.length,
              'duration': _lastLoadDuration!.inMilliseconds,
            });
      } else {
        _setErrorMessage(response.message ?? 'Failed to load batches');
        _setLoadingState(BatchLoadingState.error);
        _logger.logError('Failed to load batches: ${response.message}');
      }
    } catch (e, stackTrace) {
      _setErrorMessage('Network error: $e');
      _setLoadingState(BatchLoadingState.error);
      _logger.logError('Batch loading error', error: e, stackTrace: stackTrace);
    } finally {
      stopwatch.stop();
      notifyListeners();
    }
  }

  // Search batches
  List<BatchModel> searchBatches(String query) {
    if (query.isEmpty) return _batches;

    final lowerQuery = query.toLowerCase();
    return _batches.where((batch) {
      return batch.batchId.toLowerCase().contains(lowerQuery) ||
             (batch.productName?.toLowerCase().contains(lowerQuery) ?? false) ||
             (batch.lotNumber?.toLowerCase().contains(lowerQuery) ?? false) ||
             (batch.manufacturer?.toLowerCase().contains(lowerQuery) ?? false);
    }).toList();
  }

  // Filter batches by expiry status
  List<BatchModel> getBatchesByExpiryStatus({
    bool? expired,
    bool? expiringSoon,
    int? daysThreshold,
  }) {
    return _batches.where((batch) {
      if (expired != null && batch.isExpired != expired) return false;
      
      if (expiringSoon != null) {
        final days = batch.daysUntilExpiry;
        final isSoon = days >= 0 && days <= (daysThreshold ?? 30);
        if (isSoon != expiringSoon) return false;
      }
      
      return true;
    }).toList();
  }

  // Get batch by ID
  BatchModel? getBatchById(String batchId) {
    try {
      return _batches.firstWhere((batch) => batch.batchId == batchId);
    } catch (e) {
      _logger.logApp('Batch not found',
          level: LogLevel.warning,
          data: {'batchId': batchId});
      return null;
    }
  }

  // Add or update batch (for OCR results)
  void addOrUpdateBatch(BatchModel batch) {
    final existingIndex = _batches.indexWhere((b) => b.batchId == batch.batchId);
    
    if (existingIndex >= 0) {
      _batches[existingIndex] = batch;
      _logger.logApp('Batch updated',
          data: {'batchId': batch.batchId, 'sessionId': batch.sessionId});
    } else {
      _batches.add(batch);
      _logger.logApp('Batch added',
          data: {'batchId': batch.batchId, 'sessionId': batch.sessionId});
    }
    
    _cacheBatches();
    notifyListeners();
  }

  // Clear batches
  void clearBatches() {
    _batches.clear();
    _currentSessionId = null;
    _clearError();
    _setLoadingState(BatchLoadingState.idle);
    _batchBox?.clear();
    
    _logger.logApp('Batches cleared');
    notifyListeners();
  }

  // Cache batches to local storage
  Future<void> _cacheBatches() async {
    if (_batchBox == null) return;

    try {
      final batchData = <String, Map<String, dynamic>>{};
      for (final batch in _batches) {
        batchData[batch.batchId] = batch.toMap();
      }
      
      await _batchBox!.put(_currentSessionId ?? 'default', {
        'batches': batchData,
        'sessionId': _currentSessionId,
        'cachedAt': DateTime.now().millisecondsSinceEpoch,
      });
      
      _logger.logApp('Batches cached successfully',
          data: {'sessionId': _currentSessionId, 'count': _batches.length});
    } catch (e, stackTrace) {
      _logger.logError('Failed to cache batches',
          error: e, stackTrace: stackTrace);
    }
  }

  // Load cached batches
  Future<void> _loadCachedBatches() async {
    if (_batchBox == null) return;

    try {
      final cachedData = _batchBox!.values.toList();
      
      for (final data in cachedData) {
        final sessionData = Map<String, dynamic>.from(data);
        final batchesData = sessionData['batches'] as Map<String, dynamic>?;
        
        if (batchesData != null) {
          final sessionId = sessionData['sessionId'] as String?;
          final cachedAt = DateTime.fromMillisecondsSinceEpoch(
            sessionData['cachedAt'] as int
          );
          
          // Only load if cached within last 24 hours
          if (DateTime.now().difference(cachedAt).inHours < 24) {
            final batches = batchesData.entries.map((entry) {
              return BatchModel.fromMap(Map<String, dynamic>.from(entry.value));
            }).toList();
            
            if (sessionId != null) {
              _batches.addAll(batches);
              _currentSessionId = sessionId;
            }
          }
        }
      }
      
      if (_batches.isNotEmpty) {
        _setLoadingState(BatchLoadingState.loaded);
        _logger.logApp('Cached batches loaded',
            data: {'count': _batches.length, 'sessionId': _currentSessionId});
      }
    } catch (e, stackTrace) {
      _logger.logError('Failed to load cached batches',
          error: e, stackTrace: stackTrace);
    }
  }

  // Private helper methods
  void _setLoadingState(BatchLoadingState state) {
    if (_loadingState != state) {
      final oldState = _loadingState;
      _loadingState = state;
      
      _logger.logApp('Batch loading state changed',
          data: {
            'from': oldState.name,
            'to': state.name,
            'sessionId': _currentSessionId,
          });
      
      notifyListeners();
    }
  }

  void _setErrorMessage(String? message) {
    _errorMessage = message;
    notifyListeners();
  }

  void _clearError() {
    _errorMessage = null;
  }

  // Statistics
  Map<String, int> getBatchStatistics() {
    return {
      'total': _batches.length,
      'expired': expiredBatches.length,
      'valid': validBatches.length,
      'expiringSoon': batchesExpiringSoon.length,
    };
  }

  Map<String, List<BatchModel>> groupBatchesByStatus() {
    return {
      'expired': expiredBatches,
      'expiringSoon': batchesExpiringSoon,
      'valid': validBatches.where((batch) => 
        !batchesExpiringSoon.contains(batch)
      ).toList(),
    };
  }

  // Performance monitoring
  void logBatchOperation(String operation, Duration duration, {
    Map<String, dynamic>? additionalData,
  }) {
    _logger.logApp('Batch operation: $operation',
        data: {
          'operation': operation,
          'duration': duration.inMilliseconds,
          'batchCount': _batches.length,
          'sessionId': _currentSessionId,
          ...?additionalData,
        });
  }

  // Additional getters for filtered data
  List<BatchModel> get allBatches => batches;
  
  List<BatchModel> get recentBatches {
    final sorted = _batches.toList()
      ..sort((a, b) => b.scannedAt.compareTo(a.scannedAt));
    return sorted.take(10).toList();
  }
  
  List<BatchModel> get favoriteBatches => 
    _batches.where((batch) => batch.isFavorite).toList();
  
  int get totalScannedBatches => _batches.length;

  // Load batch history (alias for loadBatches)
  Future<void> loadBatchHistory() async {
    await loadBatches();
  }

  // Toggle favorite status
  Future<void> toggleFavorite(String batchId) async {
    try {
      final batchIndex = _batches.indexWhere((batch) => batch.id == batchId);
      if (batchIndex != -1) {
        final batch = _batches[batchIndex];
        final updatedBatch = BatchModel(
          id: batch.id,
          batchId: batch.batchId,
          sessionId: batch.sessionId,
          productName: batch.productName,
          manufacturingDate: batch.manufacturingDate,
          expiryDate: batch.expiryDate,
          batchNumber: batch.batchNumber,
          lotNumber: batch.lotNumber,
          manufacturer: batch.manufacturer,
          status: batch.status,
          isFavorite: !batch.isFavorite,
          scannedAt: batch.scannedAt,
          additionalInfo: batch.additionalInfo,
          createdAt: batch.createdAt,
          updatedAt: DateTime.now(),
        );
        
        _batches[batchIndex] = updatedBatch;
        await _saveBatchToLocal(updatedBatch);
        notifyListeners();
        
        _logOperation('Toggled favorite status', 
          level: LogLevel.info,
          additionalData: {
            'batchId': batchId,
            'isFavorite': updatedBatch.isFavorite,
          });
      }
    } catch (e) {
      _logger.logError('Failed to toggle favorite', error: e);
    }
  }

  // Process batch from QR scan
  Future<void> processBatch(String qrData) async {
    try {
      _logger.logQRScan('Processing QR data: $qrData');
      
      // Check if this is a session ID first (starts with medha- or session_)
      if ((qrData.startsWith('medha-') || qrData.startsWith('session_')) && qrData.length > 8) {
        // This is a session ID - set it and load batches
        _currentSessionId = qrData;
        _logger.logApp('Session ID set from QR scan', data: {'sessionId': qrData});
        
        // Load batches for this session from API
        await loadBatchesForSession(qrData);
        return;
      }
      
      // Try to parse as JSON for batch data
      Map<String, dynamic>? jsonData;
      try {
        jsonData = Map<String, dynamic>.from(
          const JsonDecoder().convert(qrData)
        );
      } catch (e) {
        // If not JSON, treat as simple batch ID
        jsonData = {'batch_id': qrData};
      }
      
      final sessionId = _currentSessionId ?? _generateSessionId();
      _currentSessionId ??= sessionId;
      
      final batch = BatchModel.fromJson(jsonData, sessionId);
      await addBatch(batch);
      
    } catch (e) {
      _logger.logError('Failed to process QR batch', error: e);
      rethrow;
    }
  }

  // Create batch from OCR data
  Future<void> createBatchFromOCR(String extractedText, List<String> extractedLines) async {
    try {
      _logger.logOCR('Creating batch from OCR data');
      
      // Parse OCR data to extract batch information
      final batchData = _parseOCRData(extractedText, extractedLines);
      
      final sessionId = _currentSessionId ?? _generateSessionId();
      _currentSessionId ??= sessionId;
      
      final batch = BatchModel.fromJson(batchData, sessionId);
      await addBatch(batch);
      
    } catch (e) {
      _logger.logError('Failed to create batch from OCR', error: e);
      rethrow;
    }
  }

  // Parse OCR data to extract batch information
  Map<String, dynamic> _parseOCRData(String text, List<String> lines) {
    final data = <String, dynamic>{};
    
    for (final line in lines) {
      final normalizedLine = line.toLowerCase().trim();
      
      // Extract batch number
      if (normalizedLine.contains('batch') || normalizedLine.contains('lot')) {
        final batchMatch = RegExp(r'(?:batch|lot)\s*[:#]?\s*([a-zA-Z0-9\-_]+)', 
          caseSensitive: false).firstMatch(line);
        if (batchMatch != null) {
          data['batch_id'] = batchMatch.group(1);
          data['batch_number'] = batchMatch.group(1);
        }
      }
      
      // Extract product name
      if (normalizedLine.contains('product') || normalizedLine.contains('name')) {
        final productMatch = RegExp(r'(?:product|name)\s*[:#]?\s*(.+)', 
          caseSensitive: false).firstMatch(line);
        if (productMatch != null) {
          data['product_name'] = productMatch.group(1)?.trim();
        }
      }
      
      // Extract manufacturing date
      if (normalizedLine.contains('mfg') || normalizedLine.contains('manufactured')) {
        final dateMatch = RegExp(r'(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})', 
          caseSensitive: false).firstMatch(line);
        if (dateMatch != null) {
          data['manufacturing_date'] = dateMatch.group(1);
        }
      }
      
      // Extract expiry date
      if (normalizedLine.contains('exp') || normalizedLine.contains('expiry')) {
        final dateMatch = RegExp(r'(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})', 
          caseSensitive: false).firstMatch(line);
        if (dateMatch != null) {
          data['expiry_date'] = dateMatch.group(1);
        }
      }
      
      // Extract manufacturer
      if (normalizedLine.contains('manufacturer') || normalizedLine.contains('company')) {
        final mfgMatch = RegExp(r'(?:manufacturer|company)\s*[:#]?\s*(.+)', 
          caseSensitive: false).firstMatch(line);
        if (mfgMatch != null) {
          data['manufacturer'] = mfgMatch.group(1)?.trim();
        }
      }
    }
    
    // If no batch ID found, generate one
    if (data['batch_id'] == null) {
      data['batch_id'] = 'OCR_${DateTime.now().millisecondsSinceEpoch}';
    }
    
    return data;
  }

  // Export batch data
  Future<void> exportBatchData() async {
    try {
      _logger.logApp('Exporting batch data');
      
      // Create CSV content
      final csvContent = StringBuffer();
      csvContent.writeln('ID,Batch ID,Product Name,Manufacturing Date,Expiry Date,Status,Scanned At');
      
      for (final batch in _batches) {
        csvContent.writeln([
          batch.id,
          batch.batchId,
          batch.productName ?? '',
          batch.manufacturingDate ?? '',
          batch.expiryDate ?? '',
          batch.status ?? '',
          batch.scannedAt.toIso8601String(),
        ].map((field) => '"$field"').join(','));
      }
      
      // You would typically save this to a file or share it
      // For now, just log it
      _logger.logApp('Batch data exported successfully', 
        level: LogLevel.success,
        additionalData: {
          'batchCount': _batches.length,
          'csvLength': csvContent.length,
        });
        
    } catch (e) {
      _logger.logError('Failed to export batch data', error: e);
      rethrow;
    }
  }

  // Clear all batches
  Future<void> clearAllBatches() async {
    try {
      _batches.clear();
      await _batchBox?.clear();
      notifyListeners();
      
      _logger.logApp('All batches cleared', level: LogLevel.warning);
    } catch (e) {
      _logger.logError('Failed to clear batches', error: e);
      rethrow;
    }
  }

  // Auto backup settings
  bool _isAutoBackupEnabled = false;
  bool get isAutoBackupEnabled => _isAutoBackupEnabled;
  
  void setAutoBackup(bool enabled) {
    _isAutoBackupEnabled = enabled;
    notifyListeners();
  }

  // Load batches method that takes no parameters (for compatibility)
  Future<void> loadBatches() async {
    final sessionId = _currentSessionId ?? _generateSessionId();
    _currentSessionId ??= sessionId;
    await loadBatchesForSession(sessionId);
  }

  // Generate session ID
  String _generateSessionId() {
    return 'medha-${DateTime.now().millisecondsSinceEpoch}';
  }

  // Add batch method
  Future<void> addBatch(BatchModel batch) async {
    try {
      _batches.add(batch);
      await _saveBatchToLocal(batch);
      notifyListeners();
      
      _logOperation('Batch added successfully',
          level: LogLevel.success,
          additionalData: {
            'batchId': batch.id,
            'sessionId': batch.sessionId,
          });
    } catch (e) {
      _logger.logError('Failed to add batch', error: e);
      rethrow;
    }
  }

  // Save batch to local storage
  Future<void> _saveBatchToLocal(BatchModel batch) async {
    try {
      await _batchBox?.put(batch.id, batch.toMap());
    } catch (e) {
      _logger.logError('Failed to save batch to local storage', error: e);
    }
  }

  // Save all batches to local storage
  Future<void> _saveBatchesToLocal() async {
    try {
      if (_batchBox != null) {
        for (final batch in _batches) {
          await _batchBox!.put(batch.id, batch.toMap());
        }
      }
    } catch (e) {
      _logger.logError('Failed to save batches to local storage', error: e);
    }
  }

  // Log operation helper
  void _logOperation(String message, {
    LogLevel level = LogLevel.info,
    Map<String, dynamic>? additionalData,
  }) {
    _logger.logApp(message,
        level: level,
        additionalData: {
          'batchCount': _batches.length,
          'sessionId': _currentSessionId,
          ...?additionalData,
        });
  }

  @override
  void dispose() {
    _batchBox?.close();
    _logger.logApp('BatchProvider disposed');
    super.dispose();
  }
}
