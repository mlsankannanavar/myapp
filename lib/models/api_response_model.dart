class ApiResponse<T> {
  final bool success;
  final T? data;
  final String? message;
  final String? error;
  final int? statusCode;
  final Map<String, String>? headers;
  final Duration? duration;

  ApiResponse({
    required this.success,
    this.data,
    this.message,
    this.error,
    this.statusCode,
    this.headers,
    this.duration,
  });

  factory ApiResponse.success({
    required T data,
    String? message,
    int? statusCode,
    Map<String, String>? headers,
    Duration? duration,
  }) {
    return ApiResponse(
      success: true,
      data: data,
      message: message,
      statusCode: statusCode,
      headers: headers,
      duration: duration,
    );
  }

  factory ApiResponse.error({
    required String error,
    String? message,
    int? statusCode,
    Map<String, String>? headers,
    Duration? duration,
  }) {
    return ApiResponse(
      success: false,
      error: error,
      message: message,
      statusCode: statusCode,
      headers: headers,
      duration: duration,
    );
  }

  factory ApiResponse.fromHttpResponse(
    http.Response response,
    Duration duration, {
    T Function(Map<String, dynamic>)? parser,
  }) {
    final headers = Map<String, String>.from(response.headers);
    
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        if (parser != null && response.body.isNotEmpty) {
          final jsonData = json.decode(response.body);
          final data = parser(jsonData);
          return ApiResponse.success(
            data: data,
            statusCode: response.statusCode,
            headers: headers,
            duration: duration,
          );
        } else {
          return ApiResponse.success(
            data: response.body as T,
            statusCode: response.statusCode,
            headers: headers,
            duration: duration,
          );
        }
      } catch (e) {
        return ApiResponse.error(
          error: 'Failed to parse response: $e',
          statusCode: response.statusCode,
          headers: headers,
          duration: duration,
        );
      }
    } else {
      String errorMessage;
      try {
        final errorData = json.decode(response.body);
        errorMessage = errorData['message'] ?? errorData['error'] ?? 'Request failed';
      } catch (e) {
        errorMessage = 'Request failed with status ${response.statusCode}';
      }
      
      return ApiResponse.error(
        error: errorMessage,
        statusCode: response.statusCode,
        headers: headers,
        duration: duration,
      );
    }
  }

  bool get isSuccess => success;
  bool get isError => !success;
  bool get hasData => data != null;

  String get statusText {
    if (statusCode == null) return 'Unknown';
    
    switch (statusCode!) {
      case 200: return 'OK';
      case 201: return 'Created';
      case 400: return 'Bad Request';
      case 401: return 'Unauthorized';
      case 403: return 'Forbidden';
      case 404: return 'Not Found';
      case 500: return 'Internal Server Error';
      case 502: return 'Bad Gateway';
      case 503: return 'Service Unavailable';
      case 504: return 'Gateway Timeout';
      default: return 'HTTP $statusCode';
    }
  }

  String get displayMessage {
    if (success) {
      return message ?? 'Request completed successfully';
    } else {
      return error ?? message ?? 'Request failed';
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'success': success,
      'data': data,
      'message': message,
      'error': error,
      'statusCode': statusCode,
      'headers': headers,
      'duration': duration?.inMilliseconds,
    };
  }

  @override
  String toString() {
    return 'ApiResponse(success: $success, statusCode: $statusCode, message: ${displayMessage})';
  }
}

// Specialized response for batch data
class BatchListResponse extends ApiResponse<List<BatchModel>> {
  BatchListResponse({
    required bool success,
    List<BatchModel>? data,
    String? message,
    String? error,
    int? statusCode,
    Map<String, String>? headers,
    Duration? duration,
  }) : super(
    success: success,
    data: data,
    message: message,
    error: error,
    statusCode: statusCode,
    headers: headers,
    duration: duration,
  );

  factory BatchListResponse.fromApiResponse(ApiResponse<Map<String, dynamic>> response) {
    if (response.isError) {
      return BatchListResponse(
        success: false,
        error: response.error,
        message: response.message,
        statusCode: response.statusCode,
        headers: response.headers,
        duration: response.duration,
      );
    }

    try {
      final data = response.data!;
      final batchesData = data['batches'] as Map<String, dynamic>?;
      final sessionId = data['session_id'] ?? 'unknown';
      
      if (batchesData == null) {
        return BatchListResponse(
          success: true,
          data: [],
          message: 'No batches found',
          statusCode: response.statusCode,
          headers: response.headers,
          duration: response.duration,
        );
      }

      final batches = batchesData.entries.map((entry) {
        final batchData = entry.value as Map<String, dynamic>;
        batchData['batch_id'] = entry.key;
        return BatchModel.fromJson(batchData, sessionId);
      }).toList();

      return BatchListResponse(
        success: true,
        data: batches,
        message: 'Batches loaded successfully',
        statusCode: response.statusCode,
        headers: response.headers,
        duration: response.duration,
      );
    } catch (e) {
      return BatchListResponse(
        success: false,
        error: 'Failed to parse batch data: $e',
        statusCode: response.statusCode,
        headers: response.headers,
        duration: response.duration,
      );
    }
  }

  int get batchCount => data?.length ?? 0;
  bool get hasBatches => batchCount > 0;
  List<BatchModel> get batches => data ?? [];
}
