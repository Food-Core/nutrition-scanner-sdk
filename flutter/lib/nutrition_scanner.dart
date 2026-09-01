/// Nutrition Scanner — Flutter SDK.
///
/// Scan a photo of a food nutrition label and get structured nutrient values
/// (energy, fat, carbohydrates, proteins, salt, …) per 100 g and per serving.
///
/// ```dart
/// final scanner = NutritionScannerClient(apiKey: 'nls_...');
/// final result = await scanner.scanPath(photo.path); // XFile.path works
/// if (result.foundTable) {
///   print(result.energyKcal100g?.value); // 449.0
/// }
/// ```
///
/// Auto capture: feed [AutoCaptureDetector] with the camera package's image
/// stream; pair with `ScannerOverlay` (scanner_overlay.dart) for the standard
/// viewfinder UI. See the package README for the full wiring example.
library nutrition_scanner;

export 'nutrition_scanner_widget.dart';
export 'scanner_overlay.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Base URL of the production Nutrition Scanner API.
const String kDefaultBaseUrl =
    'https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app';

/// Thrown when the API rejects a scan request.
///
/// Common [status] values:
///
/// | status | meaning | what to do |
/// |---|---|---|
/// | 400 | The upload could not be decoded as an image | Fix the input |
/// | 401 | Missing, invalid, or revoked API key / token | Check credentials |
/// | 403 | Signed-in user's email is not verified | Prompt verification |
/// | 429 / 5xx | Service busy or transient failure | Retry with backoff |
///
/// Note: a photo **without** a nutrition table does NOT throw — it returns a
/// [ScanResult] with empty [ScanResult.entities]. Treat that as "reposition
/// and retake", not as an error.
class ScanException implements Exception {
  /// HTTP status code returned by the API (see the table above).
  final int status;

  /// Human-readable explanation from the API (safe to log; usually also safe
  /// to show to the user).
  final String message;

  ScanException(this.status, this.message);

  /// True for errors worth retrying with backoff (rate limits and 5xx).
  bool get isRetryable => status == 429 || status >= 500;

  @override
  String toString() => 'ScanException($status): $message';
}

/// One nutrient value extracted from the label.
///
/// Example: for a label line "Energy 449 kcal", the `energy_kcal_100g`
/// nutriment is `Nutriment(text: '449kcal', value: 449.0, unit: 'kcal',
/// score: 0.999)`.
class Nutriment {
  /// The raw text exactly as read from the label, e.g. `'449kcal'` or
  /// `'12,5 g'`. Always present; use it as a fallback display when [value]
  /// could not be parsed.
  final String text;

  /// Model confidence for this value, `0.0`–`1.0`. Typical good reads are
  /// above `0.95`; consider flagging values below ~`0.8` for user review.
  final double score;

  /// The parsed numeric value, e.g. `449.0` for `'449kcal'`. `null` when the
  /// text could not be parsed into a number (rare — show [text] instead).
  /// "Less than" amounts (`<1g`) parse to the printed bound (`1.0`); check
  /// [text] to preserve the qualifier.
  final double? value;

  /// The parsed unit: `'kcal'`, `'kj'`, `'g'`, `'mg'`, `'µg'` or `'%'`.
  /// `null` when the label printed no unit or parsing failed.
  final String? unit;

  Nutriment.fromJson(Map<String, dynamic> json)
      : text = json['text'] as String? ?? '',
        score = (json['score'] as num?)?.toDouble() ?? 0,
        value = (json['value'] as num?)?.toDouble(),
        unit = json['unit'] as String?;

  @override
  String toString() => 'Nutriment($text, value: $value $unit, score: $score)';
}

/// A single labeled text span the model found on the label — the fine-grained
/// view behind [ScanResult.nutriments]. Most apps only need `nutriments`;
/// entities are useful for debugging or custom aggregation (e.g. when a label
/// prints the same nutrient twice).
class ScanEntity {
  /// The nutrient label, e.g. `'ENERGY_KCAL_100G'`, `'PROTEINS_SERVING'`,
  /// `'SERVING_SIZE'`.
  final String label;

  /// The text span as read from the image, e.g. `'449kcal'`.
  final String text;

  /// Model confidence for this span, `0.0`–`1.0`.
  final double score;

  ScanEntity.fromJson(Map<String, dynamic> json)
      : label = json['label'] as String? ?? '',
        text = json['text'] as String? ?? '',
        score = (json['score'] as num?)?.toDouble() ?? 0;

  @override
  String toString() => 'ScanEntity($label: $text, score: $score)';
}

/// The result of one scan.
///
/// Check [foundTable] first: an image without a nutrition table returns a
/// result with no entities — a normal outcome (ask the user to retake), not
/// an error.
class ScanResult {
  /// Every labeled span the model detected. Empty when the image contained no
  /// nutrition table.
  final List<ScanEntity> entities;

  /// The best candidate per nutrient, keyed `'<nutrient>_100g'` /
  /// `'<nutrient>_serving'` plus `'serving_size'` — e.g.
  /// `'energy_kcal_100g'`, `'proteins_serving'`. Which keys are present
  /// depends on what the label prints. Common ones have typed getters:
  /// [energyKcal100g], [proteins100g], [fat100g], and friends.
  final Map<String, Nutriment> nutriments;

  /// Number of words the OCR engine detected in the image — useful for
  /// diagnostics (a sharp label photo typically yields 50+).
  final int wordsDetected;

  /// True when served from the server-side result cache (an identical label
  /// was scanned before). Values match a fresh scan; latency ~1 s. Caching
  /// is controlled per API key in the web app's settings.
  final bool cached;

  ScanResult.fromJson(Map<String, dynamic> json)
      : entities = ((json['entities'] as List?) ?? const [])
            .map((e) => ScanEntity.fromJson(e as Map<String, dynamic>))
            .toList(),
        nutriments = (json['nutriments'] as Map<String, dynamic>? ?? const {})
            .map((k, v) =>
                MapEntry(k, Nutriment.fromJson(v as Map<String, dynamic>))),
        wordsDetected = json['words_detected'] as int? ?? 0,
        cached = json['cached'] as bool? ?? false;

  /// True when the image contained a readable nutrition table. False means
  /// "reposition and retake" — not a failure.
  bool get foundTable => entities.isNotEmpty;

  /// Energy in kcal per 100 g, when the label prints it.
  Nutriment? get energyKcal100g => nutriments['energy_kcal_100g'];

  /// Energy in kJ per 100 g, when the label prints it.
  Nutriment? get energyKj100g => nutriments['energy_kj_100g'];

  /// Total fat per 100 g, when the label prints it.
  Nutriment? get fat100g => nutriments['fat_100g'];

  /// Saturated fat per 100 g, when the label prints it.
  Nutriment? get saturatedFat100g => nutriments['saturated_fat_100g'];

  /// Carbohydrates per 100 g, when the label prints it.
  Nutriment? get carbohydrates100g => nutriments['carbohydrates_100g'];

  /// Sugars per 100 g, when the label prints it.
  Nutriment? get sugars100g => nutriments['sugars_100g'];

  /// Proteins per 100 g, when the label prints it.
  Nutriment? get proteins100g => nutriments['proteins_100g'];

  /// Salt per 100 g, when the label prints it.
  Nutriment? get salt100g => nutriments['salt_100g'];

  /// The serving size printed on the label (e.g. `51 g`), when present.
  Nutriment? get servingSize => nutriments['serving_size'];

  @override
  String toString() =>
      'ScanResult(${entities.length} entities, ${nutriments.keys.toList()})';
}

/// Client for the Nutrition Scanner API.
///
/// Authenticate with an API key created in the web app's settings:
///
/// ```dart
/// final scanner = NutritionScannerClient(apiKey: 'nls_...');
/// ```
///
/// Accepted inputs: JPEG, PNG, WEBP, and HEIC (iPhone photos work as-is).
/// For best speed and accuracy, send the nutrition table filling the frame at
/// 1200–2000 px on the long side. A scan typically takes 3–4 s; the default
/// [timeout] allows 60 s to survive rare service cold starts.
class NutritionScannerClient {
  /// Platform API key (`nls_…`). Keep it out of source control; for shipped
  /// consumer apps prefer proxying through your own backend.
  final String? apiKey;

  /// Alternative to [apiKey]: supplies a Firebase ID token of a signed-in,
  /// email-verified user (used by first-party apps).
  final Future<String> Function()? getToken;

  /// API origin. Leave as [kDefaultBaseUrl] unless pointed at a staging
  /// deployment.
  final String baseUrl;

  /// Per-request timeout. Keep generous (default 60 s): the service can take
  /// ~30 s on a rare cold start, while warm scans finish in 3–4 s.
  final Duration timeout;

  NutritionScannerClient({
    this.apiKey,
    this.getToken,
    this.baseUrl = kDefaultBaseUrl,
    this.timeout = const Duration(seconds: 60),
  }) : assert(apiKey != null || getToken != null,
            'Provide apiKey or getToken.');

  Future<Map<String, String>> _headers() async {
    if (apiKey != null) return {'X-API-Key': apiKey!};
    return {'Authorization': 'Bearer ${await getToken!()}'};
  }

  /// Scan an image by file path.
  ///
  /// Works directly with the `camera` / `image_picker` plugins:
  /// ```dart
  /// final photo = await controller.takePicture(); // XFile
  /// final result = await scanner.scanPath(photo.path);
  /// ```
  ///
  /// Throws [ScanException] on API errors; returns a [ScanResult] with
  /// `foundTable == false` when the photo has no nutrition table.
  Future<ScanResult> scanPath(String path) => scanFile(File(path));

  /// Scan an image [File]. See [scanPath] for behavior and errors.
  Future<ScanResult> scanFile(File image) => scanBytes(
        image.readAsBytesSync(),
        filename: image.uri.pathSegments.isNotEmpty
            ? image.uri.pathSegments.last
            : 'label.jpg',
      );

  /// Scan raw image bytes (JPEG/PNG/WEBP/HEIC). Use this when the image never
  /// touches disk (e.g. in-memory processing). See [scanPath] for behavior.
  Future<ScanResult> scanBytes(Uint8List bytes,
      {String filename = 'label.jpg'}) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/extract'))
      ..headers.addAll(await _headers())
      ..files.add(http.MultipartFile.fromBytes('image', bytes,
          filename: filename));
    final streamed = await request.send().timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) {
      String detail = 'HTTP ${response.statusCode}';
      try {
        detail = (jsonDecode(response.body)['detail'] as String?) ?? detail;
      } catch (_) {}
      throw ScanException(response.statusCode, detail);
    }
    return ScanResult.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }
}

/// Stability/sharpness detector implementing the shared auto-capture spec:
/// fires [onTrigger] when the camera preview has been *steady* and *sharp*
/// for [stableSamples] consecutive samples, so the app can take one photo and
/// scan it — no shutter button needed.
///
/// Wire-up with the `camera` package:
/// ```dart
/// controller.startImageStream((frame) => detector.addFrame(
///   frame.planes[0].bytes, frame.width, frame.height,
///   frame.planes[0].bytesPerRow,
/// ));
/// ```
/// When [onTrigger] fires: stop the stream, `takePicture()`, scan it, and
/// call [rearmAfterEmptyResult] if the scan found nothing.
class AutoCaptureDetector {
  /// Fires when the frame has been steady and sharp — take the photo now.
  /// The detector pauses itself until [rearmAfterEmptyResult] (or a new
  /// detector) resumes it.
  final void Function() onTrigger;

  /// Guidance messages for the user ("Hold steady…", "Too blurry…").
  final void Function(String status)? onStatus;

  /// Consecutive still+sharp samples required before triggering.
  final int stableSamples;

  /// Floor of the adaptive stillness threshold (mean luma diff, 0–255).
  final double motionStable;

  /// The adaptive stillness threshold never exceeds this.
  final double motionCeil;

  /// Motion above this re-arms the detector after an empty result
  /// (interpreted as "the user deliberately repositioned").
  final double motionRearm;

  /// Minimum sharpness (mean neighbor gradient) — below is "too blurry".
  final double sharpnessMin;

  /// Attempts per session before suggesting manual capture.
  final int maxAttempts;

  /// Sampling interval; frames arriving faster are skipped.
  final Duration sampleEvery;

  /// Camera warm-up before the first sample.
  final Duration settle;

  AutoCaptureDetector({
    required this.onTrigger,
    this.onStatus,
    this.stableSamples = 2,
    this.motionStable = 10,
    this.motionCeil = 25,
    this.motionRearm = 30,
    this.sharpnessMin = 8,
    this.maxAttempts = 6,
    this.sampleEvery = const Duration(milliseconds: 250),
    this.settle = const Duration(milliseconds: 1000),
  });

  final List<double> _motionHistory = [];
  final DateTime _startedAt = DateTime.now();
  DateTime _lastSample = DateTime.fromMillisecondsSinceEpoch(0);
  Float32List? _previous;
  int _stillCount = 0;

  /// Scan attempts made this session (read-only).
  int attempts = 0;

  bool _armed = true;

  /// True while a triggered capture is being processed by the app. Set back
  /// to false via [rearmAfterEmptyResult] to continue watching.
  bool paused = false;

  static const int _w = 64, _h = 48;

  /// Feed the luminance (Y) plane of each preview frame from
  /// `startImageStream`.
  void addFrame(Uint8List yPlane, int width, int height, int bytesPerRow) {
    final now = DateTime.now();
    if (paused ||
        now.difference(_startedAt) < settle ||
        now.difference(_lastSample) < sampleEvery) {
      return;
    }
    _lastSample = now;

    // Downsample the Y plane to 64x48.
    final sample = Float32List(_w * _h);
    for (var y = 0; y < _h; y++) {
      final srcY = (y * height / _h).floor();
      for (var x = 0; x < _w; x++) {
        final srcX = (x * width / _w).floor();
        sample[y * _w + x] = yPlane[srcY * bytesPerRow + srcX].toDouble();
      }
    }

    double motion = 255;
    if (_previous != null) {
      // Brightness-compensated diff: auto-exposure flicker isn't motion.
      var meanPrev = 0.0, meanCur = 0.0;
      for (var i = 0; i < sample.length; i++) {
        meanPrev += _previous![i];
        meanCur += sample[i];
      }
      meanPrev /= sample.length;
      meanCur /= sample.length;
      var sum = 0.0;
      for (var i = 0; i < sample.length; i++) {
        sum += ((sample[i] - meanCur) - (_previous![i] - meanPrev)).abs();
      }
      motion = sum / sample.length;
    }
    _previous = sample;

    // Adaptive stillness bar: "still" means "close to the quietest this
    // session has been", clamped to [motionStable, motionCeil].
    _motionHistory.add(motion);
    if (_motionHistory.length > 16) _motionHistory.removeAt(0);
    final noiseFloor = _motionHistory.reduce(math.min);
    final stillBar =
        math.min(motionCeil, math.max(motionStable, noiseFloor * 1.6));

    if (!_armed) {
      if (motion > motionRearm && attempts < maxAttempts) {
        _armed = true;
        onStatus?.call('Hold steady over the nutrition table…');
      }
      return;
    }
    if (motion >= stillBar) {
      _stillCount = 0;
      onStatus?.call('Hold the phone still…');
      return;
    }

    var sharp = 0.0;
    var n = 0;
    for (var y = 0; y < _h - 1; y++) {
      for (var x = 0; x < _w - 1; x++) {
        final i = y * _w + x;
        sharp += (sample[i] - sample[i + 1]).abs() +
            (sample[i] - sample[i + _w]).abs();
        n++;
      }
    }
    if (sharp / n < sharpnessMin) {
      _stillCount = 0;
      onStatus?.call('Too blurry — move closer or improve the light…');
      return;
    }

    _stillCount++;
    onStatus?.call('Hold steady…');
    if (_stillCount >= stableSamples) {
      _stillCount = 0;
      attempts++;
      paused = true; // caller resumes via rearmAfterEmptyResult
      onTrigger();
    }
  }

  /// Call after a scan that found no nutrition table: resumes watching, but
  /// requires a deliberate reposition (big motion) before the next attempt.
  void rearmAfterEmptyResult() {
    _armed = false;
    paused = false;
    onStatus?.call(attempts >= maxAttempts
        ? 'No nutrition table found — capture manually.'
        : 'No nutrition table found — aim at the label, then hold steady.');
  }
}
