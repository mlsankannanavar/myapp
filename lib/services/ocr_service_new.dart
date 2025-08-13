import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'logging_service.dart';
import '../utils/log_level.dart';

class OCRService {
  static final LoggingService _logger = LoggingService();
  late TextRecognizer _textRecognizer;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    try {
      _textRecognizer = TextRecognizer();
      _isInitialized = true;
      _logger.logApp('OCR Service initialized successfully');
    } catch (e) {
      _logger.logError('Failed to initialize OCR Service', error: e);
      rethrow;
    }
  }

  Future<String?> processImage(String imagePath) async {
    final startTime = DateTime.now();
    
    if (!_isInitialized) {
      _logger.logError('OCR_NOT_INITIALIZED: OCR Service not initialized');
      throw Exception('OCR Service not initialized');
    }

    try {
      _logger.logOcr('OCR_START: Beginning image processing');
      _logger.logOcr('OCR_IMAGE_PATH: Processing image: $imagePath');
      
      final inputImage = InputImage.fromFilePath(imagePath);
      _logger.logOcr('OCR_INPUT_CREATED: InputImage created successfully');
      
      final recognizedText = await _textRecognizer.processImage(inputImage);
      
      final processingTime = DateTime.now().difference(startTime).inMilliseconds;
      final extractedText = recognizedText.text;
      
      _logger.logOcr('OCR_COMPLETE: Text extraction completed in ${processingTime}ms');
      _logger.logOcr('OCR_TEXT_LENGTH: Extracted ${extractedText.length} characters');
      _logger.logOcr('OCR_EXTRACTED_TEXT: Raw extracted text: "$extractedText"');
      
      // Log text blocks for better understanding
      _logger.logOcr('OCR_BLOCKS: Found ${recognizedText.blocks.length} text blocks');
      for (int i = 0; i < recognizedText.blocks.length; i++) {
        final block = recognizedText.blocks[i];
        _logger.logOcr('OCR_BLOCK_${i + 1}: "${block.text.trim()}"');
      }
      
      _logger.logApp('OCR processing completed successfully', 
          level: LogLevel.success,
          data: {
            'charactersExtracted': extractedText.length,
            'processingTime': processingTime,
            'blocksFound': recognizedText.blocks.length,
          });
      
      return extractedText;
      
    } catch (e) {
      final errorTime = DateTime.now().difference(startTime).inMilliseconds;
      _logger.logError('OCR_ERROR: Processing failed after ${errorTime}ms - $e', error: e);
      _logger.logError('OCR_IMAGE_PATH_ERROR: Failed image: $imagePath');
      return null;
    }
  }

  Future<List<String>> processImageLines(String imagePath) async {
    if (!_isInitialized) {
      throw Exception('OCR Service not initialized');
    }

    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final recognizedText = await _textRecognizer.processImage(inputImage);
      
      final lines = recognizedText.blocks
        .expand((block) => block.lines)
        .map((line) => line.text.trim())
        .where((text) => text.isNotEmpty)
        .toList();
      
      _logger.logApp('OCR processing completed: ${lines.length} lines extracted');
      return lines;
    } catch (e) {
      _logger.logError('OCR line processing failed', error: e);
      return [];
    }
  }

  Future<String?> extractTextFromImage(String imagePath) async {
    return await processImage(imagePath);
  }

  void dispose() {
    if (_isInitialized) {
      _textRecognizer.close();
      _isInitialized = false;
      _logger.logApp('OCR Service disposed');
    }
  }
}
