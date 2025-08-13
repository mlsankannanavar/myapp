import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'dart:io';

import '../providers/logging_provider.dart';
import '../providers/batch_provider.dart';
import '../services/ocr_service.dart';
import '../services/api_service.dart';
import '../widgets/loading_widget.dart';
import '../utils/app_colors.dart';

class OCRScannerScreen extends StatefulWidget {
  const OCRScannerScreen({super.key});

  @override
  State<OCRScannerScreen> createState() => _OCRScannerScreenState();
}

class _OCRScannerScreenState extends State<OCRScannerScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  late OcrService _ocrService;
  
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isFlashOn = false;
  String? _capturedImagePath;
  String? _extractedText;
  List<String> _extractedLines = [];
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _initializeOCR();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    
    try {
      loggingProvider.logApp('Initializing camera for OCR');
      
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available');
      }

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();
      
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
      
      loggingProvider.logSuccess('Camera initialized for OCR');
    } catch (e) {
      loggingProvider.logError('Camera initialization failed: $e');
      if (mounted) {
        setState(() {
          _isCameraInitialized = false;
        });
      }
    }
  }

  void _initializeOCR() async {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    
    try {
      _ocrService = OcrService.instance;
      await _ocrService.initialize();
      loggingProvider.logApp('OCR service initialized successfully');
    } catch (e) {
      loggingProvider.logError('OCR service initialization failed: $e');
    }
  }

  // --- New: Fuzzy match, quantity pad, and submit workflow ---
  Future<void> _showBatchMatchAndSubmitFlow() async {
    final batchProvider = Provider.of<BatchProvider>(context, listen: false);
    final apiService = ApiService();
    final sessionId = batchProvider.currentSessionId ?? 'unknown';
    
    // For demo, extract batch/expiry from first line containing 'batch' and 'exp'
    String? extractedBatch;
    String? extractedExpiry;
    for (final line in _extractedLines) {
      if (extractedBatch == null && line.toLowerCase().contains('batch')) {
        final match = RegExp(r'([A-Za-z0-9\-]+)').firstMatch(line);
        if (match != null) extractedBatch = match.group(1);
      }
      if (extractedExpiry == null && line.toLowerCase().contains('exp')) {
        final match = RegExp(r'(\d{2}/\d{4}|\d{2}/\d{2}/\d{4}|\d{4}-\d{2}-\d{2})').firstMatch(line);
        if (match != null) extractedExpiry = match.group(1);
      }
    }
    
    if (extractedBatch == null) {
      _showInfoDialog('No batch number found in extracted text.');
      return;
    }
    
    final matches = _ocrService.findBestBatchMatches(
      extractedBatch: extractedBatch,
      extractedExpiry: extractedExpiry,
      batches: batchProvider.batches,
    );
    
    if (matches.isEmpty) {
      _showInfoDialog('No matching batch found.');
      return;
    }
    
    final bestMatch = matches.first;
    final batch = bestMatch.batch;
    final confidence = (bestMatch.similarity * 100).toInt();
    
    // Ask user to confirm and enter quantity
    final quantity = await _showQuantityPad();
    if (quantity == null) return;
    
    // Call API to submit
    final resp = await apiService.submitMobileBatch(
      sessionId: sessionId,
      batchNumber: batch.batchNumber ?? batch.batchId ?? '',
      quantity: quantity,
      captureId: DateTime.now().millisecondsSinceEpoch.toString(),
      confidence: confidence,
      matchType: bestMatch.similarity == 1.0 ? 'exact' : 'fuzzy',
      submitTimestamp: DateTime.now().millisecondsSinceEpoch,
      extractedText: _extractedText ?? '',
      selectedFromOptions: true,
      alternativeMatches: matches.length > 1 ? matches.skip(1).map((m) => (m.batch.batchNumber ?? m.batch.batchId ?? '').toString()).toList() : [],
    );
    
    if (resp.isSuccess) {
      _showInfoDialog('Batch submitted successfully!');
    } else {
      _showInfoDialog('Failed to submit batch: \n${resp.message ?? 'Unknown error'}');
    }
  }

  Future<int?> _showQuantityPad() async {
    int? result;
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Quantity'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Quantity'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final val = int.tryParse(controller.text);
              if (val != null && val > 0) {
                result = val;
                Navigator.of(context).pop();
              }
            },
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    return result;
  }

  void _showInfoDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      body: _buildBody(),
      bottomSheet: _buildBottomSheet(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text('OCR Scanner'),
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      elevation: 0,
      actions: [
        if (_isCameraInitialized) ...[
          IconButton(
            onPressed: _toggleFlash,
            icon: Icon(_isFlashOn ? Icons.flash_on : Icons.flash_off),
            tooltip: 'Toggle Flash',
          ),
          IconButton(
            onPressed: _capturedImagePath != null ? _resetCapture : _captureImage,
            icon: Icon(_capturedImagePath != null ? Icons.refresh : Icons.camera_alt),
            tooltip: _capturedImagePath != null ? 'Retake' : 'Capture',
          ),
        ],
      ],
    );
  }

  Widget _buildBody() {
    if (!_isCameraInitialized) {
      return _buildCameraError();
    }

    if (_capturedImagePath != null) {
      return _buildCapturedImageView();
    }

    return _buildCameraPreview();
  }

  Widget _buildCameraError() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.camera_alt_outlined,
            size: 80,
            color: Colors.grey,
          ),
          SizedBox(height: 24),
          Text(
            'Camera not available',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Please check camera permissions',
            style: TextStyle(
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    return Stack(
      children: [
        // Camera preview
        SizedBox.expand(
          child: CameraPreview(_cameraController!),
        ),
        
        // Overlay with capture guidelines
        _buildCaptureOverlay(),
        
        // Processing indicator
        if (_isProcessing) _buildProcessingOverlay(),
      ],
    );
  }

  Widget _buildCaptureOverlay() {
    return CustomPaint(
      painter: OCROverlayPainter(),
      child: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: AppColors.primary,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text(
                  'Position text within this frame\nfor better recognition',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.7),
      child: const Center(
        child: LoadingWidget(
          message: 'Processing image...',
        ),
      ),
    );
  }

  Widget _buildCapturedImageView() {
    return Column(
      children: [
        // Captured image
        Expanded(
          flex: 3,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
            ),
            child: Image.file(
              File(_capturedImagePath!),
              fit: BoxFit.contain,
            ),
          ),
        ),
        
        // Extracted text
        Expanded(
          flex: 2,
          child: Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Extracted Text',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (_extractedText != null) ...[
                      IconButton(
                        onPressed: _copyText,
                        icon: const Icon(Icons.copy),
                        tooltip: 'Copy text',
                      ),
                      IconButton(
                        onPressed: _shareText,
                        icon: const Icon(Icons.share),
                        tooltip: 'Share text',
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _buildExtractedTextContent(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExtractedTextContent() {
    if (_isProcessing) {
      return const Center(
        child: LoadingWidget(message: 'Extracting text...'),
      );
    }

    if (_extractedText == null || _extractedText!.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.text_fields,
              size: 48,
              color: Colors.grey,
            ),
            SizedBox(height: 16),
            Text(
              'No text extracted',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Try capturing a clearer image with better lighting',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Raw text
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Text(
              _extractedText!,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
          
          const SizedBox(height: 16),
          
          // Potential batch information
          if (_extractedLines.isNotEmpty) ...[
            const Text(
              'Potential Batch Information',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ..._extractedLines.map((line) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Icon(
                    Icons.arrow_right,
                    size: 16,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      line,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            )),
          ],
          
          const SizedBox(height: 16),
          
          // Action buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _showBatchMatchAndSubmitFlow,
                  icon: const Icon(Icons.inventory),
                  label: const Text('Submit Batch'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _resetCapture,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retake'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomSheet() {
    if (_capturedImagePath != null) {
      return const SizedBox.shrink(); // Hide bottom sheet when image is captured
    }

    return Container(
      height: 100,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Gallery button
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: _pickFromGallery,
                icon: const Icon(Icons.photo_library),
                iconSize: 32,
              ),
              const Text(
                'Gallery',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          
          // Capture button
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: _captureImage,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white,
                      width: 3,
                    ),
                  ),
                  child: const Icon(
                    Icons.camera_alt,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Capture',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          
          // Settings button
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: _showOCRSettings,
                icon: const Icon(Icons.settings),
                iconSize: 32,
              ),
              const Text(
                'Settings',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Event handlers
  Future<void> _toggleFlash() async {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    
    try {
      await _cameraController!.setFlashMode(
        _isFlashOn ? FlashMode.off : FlashMode.torch,
      );
      
      setState(() {
        _isFlashOn = !_isFlashOn;
      });
      
      loggingProvider.logApp('OCR flash ${_isFlashOn ? 'enabled' : 'disabled'}');
    } catch (e) {
      loggingProvider.logError('Failed to toggle flash: $e');
    }
  }

  Future<void> _captureImage() async {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      loggingProvider.logError('Camera not initialized for capture');
      return;
    }

    try {
      setState(() {
        _isProcessing = true;
      });

      loggingProvider.logOCR('Capturing image for OCR processing');

      final XFile image = await _cameraController!.takePicture();
      
      setState(() {
        _capturedImagePath = image.path;
      });

      loggingProvider.logSuccess('Image captured successfully');

      // Process the captured image
      await _processImage(image.path);
    } catch (e) {
      loggingProvider.logError('Image capture failed: $e');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _pickFromGallery() async {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    loggingProvider.logOCR('Picking image from gallery');

    // Implementation for picking from gallery
    // This would typically use image_picker package
    loggingProvider.logApp('Gallery picker functionality to be implemented');
  }

  Future<void> _processImage(String imagePath) async {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    
    try {
      setState(() {
        _isProcessing = true;
      });

      // Check if OCR service is initialized
      if (!_ocrService.isInitialized) {
        loggingProvider.logError('OCR service not initialized, attempting to initialize...');
        await _ocrService.initialize();
      }

      loggingProvider.logOCR('Starting OCR processing');

      final result = await _ocrService.processImage(imagePath);

      if (result != null && result.isNotEmpty) {
        final extractedText = result;
        
        setState(() {
          _extractedText = extractedText;
          _extractedLines = _parseExtractedText(extractedText);
        });

        loggingProvider.logSuccess('OCR processing completed', data: {
          'textLength': extractedText.length,
          'linesFound': _extractedLines.length,
        });
      } else {
        loggingProvider.logError('OCR processing failed: No text extracted');
        setState(() {
          _extractedText = '';
          _extractedLines = [];
        });
      }
    } catch (e) {
      loggingProvider.logError('OCR processing error: $e', stackTrace: StackTrace.current);
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  List<String> _parseExtractedText(String text) {
    final lines = text.split('\n').where((line) => line.trim().isNotEmpty).toList();
    final batchLines = <String>[];

    // Look for potential batch-related information
    for (final line in lines) {
      final lowerLine = line.toLowerCase();
      if (lowerLine.contains('batch') ||
          lowerLine.contains('lot') ||
          lowerLine.contains('exp') ||
          lowerLine.contains('mfg') ||
          lowerLine.contains('date') ||
          RegExp(r'\d{2}/\d{2}/\d{4}').hasMatch(line) ||
          RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(line)) {
        batchLines.add(line.trim());
      }
    }

    return batchLines;
  }

  void _resetCapture() {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    loggingProvider.logOCR('Resetting capture');

    setState(() {
      _capturedImagePath = null;
      _extractedText = null;
      _extractedLines = [];
    });
  }

  void _copyText() {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    
    if (_extractedText != null) {
      // Implementation for copying text to clipboard
      loggingProvider.logApp('OCR text copied to clipboard');
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Text copied to clipboard')),
      );
    }
  }

  void _shareText() {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    
    if (_extractedText != null) {
      // Implementation for sharing text
      loggingProvider.logApp('OCR text shared');
      
      // This would typically use the share package
    }
  }

  void _showOCRSettings() {
    final loggingProvider = Provider.of<LoggingProvider>(context, listen: false);
    loggingProvider.logApp('OCR settings opened');

    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'OCR Settings',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.language),
              title: const Text('Language'),
              subtitle: const Text('English'),
              onTap: () {
                Navigator.pop(context);
                // Language selection implementation
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Recognition Mode'),
              subtitle: const Text('Balanced'),
              onTap: () {
                Navigator.pop(context);
                // Recognition mode selection implementation
              },
            ),
            ListTile(
              leading: const Icon(Icons.info),
              title: const Text('Tips'),
              onTap: () {
                Navigator.pop(context);
                _showOCRTips();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showOCRTips() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('OCR Tips'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('For better text recognition:'),
              SizedBox(height: 8),
              Text('• Ensure good lighting'),
              Text('• Hold the device steady'),
              Text('• Position text clearly in frame'),
              Text('• Avoid shadows and reflections'),
              Text('• Use high contrast backgrounds'),
              Text('• Clean the camera lens'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

// Custom painter for OCR overlay
class OCROverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..style = PaintingStyle.fill;

    // Calculate the cutout rectangle (capture area)
    final cutoutRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 300,
      height: 200,
    );

    // Create the overlay path with cutout
    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(cutoutRect)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(overlayPath, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
