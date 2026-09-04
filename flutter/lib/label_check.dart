/// On-device label intelligence (ML Kit text recognition, runs offline).
///
/// Used by the scanner after capture, before the API call, to:
/// 1. **Verify** the photo actually shows a nutrition label (nutrient
///    keywords present) — avoids spending an API call on a desk or a novel.
/// 2. **Auto-crop** to the text region — the label is uploaded at full
///    resolution instead of label-plus-background, which measurably improves
///    OCR digit accuracy (and with it, cache hit rates).
library label_check;

import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

/// Nutrient words (lowercase substrings) that mark a photo as a nutrition
/// label. Multi-language by default; override via [LabelIntelligence.keywords].
const List<String> kDefaultNutritionKeywords = [
  // English
  'nutrition', 'calories', 'energy', 'protein', 'carbohydrate', 'fat',
  'sugars', 'serving', 'sodium', 'fiber', 'fibre', 'kcal',
  // French
  'valeurs', 'énergie', 'protéines', 'glucides', 'matières grasses', 'sel',
  // German
  'nährwerte', 'energie', 'eiweiß', 'kohlenhydrate', 'fett', 'zucker', 'salz',
  // Spanish / Italian / Portuguese
  'valor', 'energía', 'proteínas', 'grasas', 'azúcares', 'valori',
  'proteine', 'carboidrati', 'grassi', 'zuccheri', 'proteínas', 'açúcares',
];

/// Result of [LabelIntelligence.analyze].
class LabelCheck {
  /// True when at least [LabelIntelligence.minKeywords] nutrient keywords
  /// were recognized in the photo.
  final bool hasNutritionText;

  /// Everything the on-device recognizer read (useful for debugging).
  final String recognizedText;

  /// The photo cropped to its text region — upload this instead of the
  /// original for better OCR accuracy. Null when cropping was skipped
  /// (text already fills the frame, too little text, or decoding failed).
  final File? croppedFile;

  const LabelCheck({
    required this.hasNutritionText,
    required this.recognizedText,
    this.croppedFile,
  });
}

/// Wraps ML Kit's on-device Latin text recognizer (a few MB, offline,
/// ~100 ms per photo). Create once, [close] when done.
class LabelIntelligence {
  final List<String> keywords;

  /// Distinct keywords required to call a photo a nutrition label.
  final int minKeywords;

  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  LabelIntelligence({List<String>? keywords, this.minKeywords = 2})
      : keywords = keywords ?? kDefaultNutritionKeywords;

  /// Recognize text in the photo at [path]; when [crop] is true also produce
  /// a text-region crop (written next to the original as `<path>.crop.jpg`).
  /// Never throws for recognition/cropping problems — degrades to
  /// `hasNutritionText: false` / `croppedFile: null`.
  Future<LabelCheck> analyze(String path, {bool crop = true}) async {
    RecognizedText recognized;
    try {
      recognized =
          await _recognizer.processImage(InputImage.fromFilePath(path));
    } catch (_) {
      return const LabelCheck(hasNutritionText: false, recognizedText: '');
    }

    final text = recognized.text.toLowerCase();
    final found = keywords.where(text.contains).toSet();
    final isLabel = found.length >= minKeywords;

    File? cropped;
    if (crop && isLabel && recognized.blocks.isNotEmpty) {
      cropped = await _cropToText(path, recognized);
    }
    return LabelCheck(
      hasNutritionText: isLabel,
      recognizedText: recognized.text,
      croppedFile: cropped,
    );
  }

  Future<File?> _cropToText(String path, RecognizedText recognized) async {
    try {
      var left = double.infinity, top = double.infinity;
      var right = 0.0, bottom = 0.0;
      for (final block in recognized.blocks) {
        final box = block.boundingBox;
        if (box.left < left) left = box.left;
        if (box.top < top) top = box.top;
        if (box.right > right) right = box.right;
        if (box.bottom > bottom) bottom = box.bottom;
      }
      if (right <= left || bottom <= top) return null;

      final bytes = await File(path).readAsBytes();
      var decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      // ML Kit works in display orientation; make pixels match.
      decoded = img.bakeOrientation(decoded);

      // Expand by a 5% margin and clamp.
      final marginX = decoded.width * 0.05;
      final marginY = decoded.height * 0.05;
      final x = (left - marginX).clamp(0, decoded.width - 1).toInt();
      final y = (top - marginY).clamp(0, decoded.height - 1).toInt();
      final w = (right - left + 2 * marginX)
          .clamp(1, decoded.width - x)
          .toInt();
      final h = (bottom - top + 2 * marginY)
          .clamp(1, decoded.height - y)
          .toInt();

      // Skip pointless crops: text already fills the frame, or the region is
      // suspiciously small (likely stray text, not the label).
      final areaRatio = (w * h) / (decoded.width * decoded.height);
      if (areaRatio > 0.85 || areaRatio < 0.08) return null;

      final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
      final out = File('$path.crop.jpg');
      await out.writeAsBytes(img.encodeJpg(cropped, quality: 90));
      return out;
    } catch (_) {
      return null;
    }
  }

  void close() {
    _recognizer.close();
  }
}
