import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/batch_model.dart';
import '../models/api_response_model.dart';
import '../services/api_service.dart';
import '../services/logging_service.dart';
import '../utils/constants.dart';

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
  bool get hasBatches => _batches.isNotEmpty;
  int get batchCount => _batches.length;

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

  // Load batches for a session
  Future<void> loadBatches(String sessionId, {bool forceRefresh = false}) async {
    if (_currentSessionId == sessionId && !forceRefresh && _batches.isNotEmpty) {
      _logger.logApp('Using cached batches for session',
          data: {'sessionId': sessionId, 'count': _batches.length});
      return;
    }

    _setLoadingState(BatchLoadingState.loading);
    _currentSessionId = sessionId;
    _clearError();

    final stopwatch = Stopwatch()..start();
    
    try {
      _logger.logApp('Loading batches for session',
          data: {'sessionId': sessionId, 'forceRefresh': forceRefresh});

      final response = await _apiService.getFilteredBatches(sessionId);
      stopwatch.stop();
      
      _lastLoadDuration = stopwatch.elapsed;
      _lastLoadTime = DateTime.now();

      if (response.isSuccess && response.data != null) {
        _batches = response.data!;
        await _cacheBatches();
        _setLoadingState(BatchLoadingState.loaded);
        
        _logger.logApp('Batches loaded successfully',
            level: LogLevel.success,
            data: {
              'sessionId': sessionId,
              'batchCount': _batches.length,
              'duration': stopwatch.elapsed.inMilliseconds,
              'expiredCount': expiredBatches.length,
              'expiringSoonCount': batchesExpiringSoon.length,
            });
      } else {
        _setError(response.error ?? 'Failed to load batches');
        _setLoadingState(BatchLoadingState.error);
        
        _logger.logApp('Failed to load batches',
            level: LogLevel.error,
            data: {
              'sessionId': sessionId,
              'error': response.error,
              'statusCode': response.statusCode,
              'duration': stopwatch.elapsed.inMilliseconds,
            });
      }
    } catch (e, stackTrace) {
      stopwatch.stop();
      _lastLoadDuration = stopwatch.elapsed;
      _setError('Unexpected error: ${e.toString()}');
      _setLoadingState(BatchLoadingState.error);
      
      _logger.logError('Exception while loading batches',
          error: e, stackTrace: stackTrace);
    }
  }

  // Retry loading batches
  Future<void> retryLoadBatches() async {
    if (_currentSessionId != null) {
      await loadBatches(_currentSessionId!, forceRefresh: true);
    } else {
      _logger.logApp('Cannot retry batch loading - no session ID',
          level: LogLevel.warning);
    }
  }

  // Refresh batches for current session
  Future<void> refreshBatches() async {
    if (_currentSessionId != null) {
      await loadBatches(_currentSessionId!, forceRefresh: true);
    } else {
      _logger.logApp('Cannot refresh batches - no current session',
          level: LogLevel.warning);
    }
  }

  // Search batches
  List<BatchModel> searchBatches(String query) {
    if (query.isEmpty) return batches;

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

  void _setError(String error) {
    _errorMessage = error;
    _logger.logApp('Batch provider error set',
        level: LogLevel.error,
        data: {'error': error});
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

  @override
  void dispose() {
    _batchBox?.close();
    _logger.logApp('BatchProvider disposed');
    super.dispose();
  }
}
