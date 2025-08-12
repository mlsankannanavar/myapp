class BatchModel {
  final String batchId;
  final String sessionId;
  final String? productName;
  final String? manufacturingDate;
  final String? expiryDate;
  final String? lotNumber;
  final String? manufacturer;
  final Map<String, dynamic>? additionalInfo;
  final DateTime createdAt;
  final DateTime? updatedAt;

  BatchModel({
    required this.batchId,
    required this.sessionId,
    this.productName,
    this.manufacturingDate,
    this.expiryDate,
    this.lotNumber,
    this.manufacturer,
    this.additionalInfo,
    DateTime? createdAt,
    this.updatedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  // Factory constructor from JSON
  factory BatchModel.fromJson(Map<String, dynamic> json, String sessionId) {
    return BatchModel(
      batchId: json['batch_id']?.toString() ?? '',
      sessionId: sessionId,
      productName: json['product_name']?.toString(),
      manufacturingDate: json['manufacturing_date']?.toString(),
      expiryDate: json['expiry_date']?.toString(),
      lotNumber: json['lot_number']?.toString(),
      manufacturer: json['manufacturer']?.toString(),
      additionalInfo: json['additional_info'] as Map<String, dynamic>?,
      createdAt: json['created_at'] != null 
          ? DateTime.parse(json['created_at']) 
          : DateTime.now(),
      updatedAt: json['updated_at'] != null 
          ? DateTime.parse(json['updated_at']) 
          : null,
    );
  }

  // Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'batch_id': batchId,
      'session_id': sessionId,
      'product_name': productName,
      'manufacturing_date': manufacturingDate,
      'expiry_date': expiryDate,
      'lot_number': lotNumber,
      'manufacturer': manufacturer,
      'additional_info': additionalInfo,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  // Convert to Map for local storage
  Map<String, dynamic> toMap() {
    return {
      'batchId': batchId,
      'sessionId': sessionId,
      'productName': productName,
      'manufacturingDate': manufacturingDate,
      'expiryDate': expiryDate,
      'lotNumber': lotNumber,
      'manufacturer': manufacturer,
      'additionalInfo': additionalInfo,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt?.millisecondsSinceEpoch,
    };
  }

  // Factory constructor from Map (local storage)
  factory BatchModel.fromMap(Map<String, dynamic> map) {
    return BatchModel(
      batchId: map['batchId'] ?? '',
      sessionId: map['sessionId'] ?? '',
      productName: map['productName'],
      manufacturingDate: map['manufacturingDate'],
      expiryDate: map['expiryDate'],
      lotNumber: map['lotNumber'],
      manufacturer: map['manufacturer'],
      additionalInfo: map['additionalInfo'] != null 
          ? Map<String, dynamic>.from(map['additionalInfo']) 
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt']),
      updatedAt: map['updatedAt'] != null 
          ? DateTime.fromMillisecondsSinceEpoch(map['updatedAt']) 
          : null,
    );
  }

  // Helper methods
  bool get isExpired {
    if (expiryDate == null) return false;
    try {
      final expiry = DateTime.parse(expiryDate!);
      return expiry.isBefore(DateTime.now());
    } catch (e) {
      return false;
    }
  }

  int get daysUntilExpiry {
    if (expiryDate == null) return -1;
    try {
      final expiry = DateTime.parse(expiryDate!);
      final difference = expiry.difference(DateTime.now());
      return difference.inDays;
    } catch (e) {
      return -1;
    }
  }

  String get expiryStatus {
    if (expiryDate == null) return 'Unknown';
    final days = daysUntilExpiry;
    if (days < 0) return 'Expired';
    if (days == 0) return 'Expires Today';
    if (days <= 30) return 'Expires in $days days';
    return 'Valid';
  }

  bool get hasCompleteInfo {
    return batchId.isNotEmpty &&
           productName != null &&
           expiryDate != null &&
           lotNumber != null;
  }

  String get displayName {
    if (productName != null && productName!.isNotEmpty) {
      return productName!;
    }
    if (lotNumber != null && lotNumber!.isNotEmpty) {
      return 'Lot: $lotNumber';
    }
    return 'Batch: $batchId';
  }

  // Copy with method
  BatchModel copyWith({
    String? batchId,
    String? sessionId,
    String? productName,
    String? manufacturingDate,
    String? expiryDate,
    String? lotNumber,
    String? manufacturer,
    Map<String, dynamic>? additionalInfo,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return BatchModel(
      batchId: batchId ?? this.batchId,
      sessionId: sessionId ?? this.sessionId,
      productName: productName ?? this.productName,
      manufacturingDate: manufacturingDate ?? this.manufacturingDate,
      expiryDate: expiryDate ?? this.expiryDate,
      lotNumber: lotNumber ?? this.lotNumber,
      manufacturer: manufacturer ?? this.manufacturer,
      additionalInfo: additionalInfo ?? this.additionalInfo,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() {
    return 'BatchModel(batchId: $batchId, sessionId: $sessionId, productName: $productName, expiryDate: $expiryDate)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BatchModel &&
           other.batchId == batchId &&
           other.sessionId == sessionId;
  }

  @override
  int get hashCode => batchId.hashCode ^ sessionId.hashCode;
}
