import 'package:flutter/foundation.dart';
import '../models/log_entry_model.dart';
import '../services/logging_service.dart';

class LoggingProvider extends ChangeNotifier {
  final LoggingService _loggingService = LoggingService();
  
  List<LogEntry> _filteredLogs = [];
  String _searchQuery = '';
  LogLevel? _levelFilter;
  String? _categoryFilter;
  bool _autoScroll = true;
  bool _showOnlyErrors = false;

  // Getters
  List<LogEntry> get logs => _loggingService.logs;
  List<LogEntry> get filteredLogs => _filteredLogs.isNotEmpty ? _filteredLogs : logs;
  int get logCount => logs.length;
  bool get hasLogs => logs.isNotEmpty;
  bool get hasErrors => _loggingService.hasErrors;
  bool get hasNewErrors => _loggingService.hasNewErrors;
  String get searchQuery => _searchQuery;
  LogLevel? get levelFilter => _levelFilter;
  String? get categoryFilter => _categoryFilter;
  bool get autoScroll => _autoScroll;
  bool get showOnlyErrors => _showOnlyErrors;
  bool get isInitialized => _loggingService.isInitialized;

  LoggingProvider() {
    _initializeLogging();
    _loggingService.addListener(_onLogsUpdated);
  }

  Future<void> _initializeLogging() async {
    await _loggingService.initialize();
    _applyFilters();
    notifyListeners();
  }

  void _onLogsUpdated() {
    _applyFilters();
    notifyListeners();
  }

  // Log methods
  void logApiRequest(String method, String url, {
    Map<String, String>? headers,
    dynamic body,
  }) {
    _loggingService.logApiRequest(method, url, headers: headers, body: body);
  }

  void logApiResponse(String method, String url, int statusCode, Duration duration, {
    Map<String, String>? headers,
    dynamic body,
  }) {
    _loggingService.logApiResponse(method, url, statusCode, duration,
        headers: headers, body: body);
  }

  void logQrScan(String message, {String? qrData, bool success = true}) {
    _loggingService.logQrScan(message, qrData: qrData, success: success);
  }

  void logOcr(String message, {
    String? extractedText,
    double? confidence,
    bool success = true,
  }) {
    _loggingService.logOcr(message,
        extractedText: extractedText, confidence: confidence, success: success);
  }

  void logError(String message, {
    Object? error,
    StackTrace? stackTrace,
    String category = 'ERROR',
  }) {
    _loggingService.logError(message,
        error: error, stackTrace: stackTrace, category: category);
  }

  void logApp(String message, {
    LogLevel level = LogLevel.info,
    Map<String, dynamic>? data,
  }) {
    _loggingService.logApp(message, level: level, data: data);
  }

  void logNetwork(String message, {
    LogLevel level = LogLevel.info,
    Map<String, dynamic>? data,
  }) {
    _loggingService.logNetwork(message, level: level, data: data);
  }

  // Filtering methods
  void setSearchQuery(String query) {
    _searchQuery = query;
    _applyFilters();
    notifyListeners();
  }

  void setLevelFilter(LogLevel? level) {
    _levelFilter = level;
    _applyFilters();
    notifyListeners();
  }

  void setCategoryFilter(String? category) {
    _categoryFilter = category;
    _applyFilters();
    notifyListeners();
  }

  void setShowOnlyErrors(bool showOnly) {
    _showOnlyErrors = showOnly;
    if (showOnly) {
      _levelFilter = LogLevel.error;
    } else {
      _levelFilter = null;
    }
    _applyFilters();
    notifyListeners();
  }

  void clearFilters() {
    _searchQuery = '';
    _levelFilter = null;
    _categoryFilter = null;
    _showOnlyErrors = false;
    _applyFilters();
    notifyListeners();
  }

  void _applyFilters() {
    List<LogEntry> filtered = List.from(logs);

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      filtered = _loggingService.searchLogs(_searchQuery);
    }

    // Apply level filter
    if (_levelFilter != null) {
      filtered = filtered.where((log) => log.level == _levelFilter).toList();
    }

    // Apply category filter
    if (_categoryFilter != null && _categoryFilter!.isNotEmpty) {
      filtered = filtered.where((log) => log.category == _categoryFilter).toList();
    }

    // Apply error-only filter
    if (_showOnlyErrors) {
      filtered = filtered.where((log) => log.level == LogLevel.error).toList();
    }

    _filteredLogs = filtered;
  }

  // Auto-scroll management
  void setAutoScroll(bool autoScroll) {
    _autoScroll = autoScroll;
    notifyListeners();
  }

  void toggleAutoScroll() {
    _autoScroll = !_autoScroll;
    notifyListeners();
  }

  // Export functionality
  Future<void> exportLogs({List<LogEntry>? specificLogs}) async {
    await _loggingService.exportLogs(specificLogs: specificLogs);
  }

  Future<void> exportFilteredLogs() async {
    await _loggingService.exportLogs(specificLogs: filteredLogs);
  }

  // Clear logs
  void clearLogs() {
    _loggingService.clearLogs();
  }

  // Statistics
  Map<LogLevel, int> getLogCountByLevel() {
    return _loggingService.getLogCountByLevel();
  }

  Map<String, int> getLogCountByCategory() {
    return _loggingService.getLogCountByCategory();
  }

  // Get recent logs
  List<LogEntry> getRecentLogs(int minutes) {
    return _loggingService.getRecentLogs(minutes);
  }

  // Get logs by time range
  List<LogEntry> getLogsByTimeRange(DateTime start, DateTime end) {
    return _loggingService.getLogsByTimeRange(start, end);
  }

  // Get available categories
  List<String> getAvailableCategories() {
    return logs.map((log) => log.category).toSet().toList()..sort();
  }

  // Performance logging
  void logPerformance(String operation, Duration duration, {
    Map<String, dynamic>? additionalData,
  }) {
    _loggingService.logPerformance(operation, duration,
        additionalData: additionalData);
  }

  // Settings
  void setMaxLogs(int maxLogs) {
    _loggingService.setMaxLogs(maxLogs);
  }

  void setEnableLogging(bool enable) {
    _loggingService.setEnableLogging(enable);
  }

  int get maxLogs => _loggingService.maxLogs;
  bool get enableLogging => _loggingService.enableLogging;

  @override
  void dispose() {
    _loggingService.removeListener(_onLogsUpdated);
    super.dispose();
  }
}
