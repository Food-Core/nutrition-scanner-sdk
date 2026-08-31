/// Nutrition Scanner — Flutter SDK.
///
/// Manual capture:
///   final scanner = NutritionScannerClient(apiKey: 'nls_...');
///   final result = await scanner.scanFile(File(photo.path));
///
/// Auto capture: feed [AutoCaptureDetector] with the camera package's
/// image stream; it fires [onTrigger] when the frame is steady and sharp.
library nutrition_scanner;

import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'dart:convert';

const String kDefaultBaseUrl =
    'https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app';

class ScanException implements Exception {
  final int status;
  final String message;
  ScanException(this.status, this.message);
  @override
  String toString() => 'ScanException($status): $message';
}

class Nutriment {
  final String text;
  final double score;
  final double? value;
  final String? unit;
  Nutriment.fromJson(Map<String, dynamic> json)
      : text = json['text'] as String? ?? '',
        score = (json['score'] as num?)?.toDouble() ?? 0,
        value = (json['value'] as num?)?.toDouble(),
        unit = json['unit'] as String?;
}

class ScanResult {
  final List<Map<String, dynamic>> entities;
  final Map<String, Nutriment> nutriments;
  final int wordsDetected;
  ScanResult.fromJson(Map<String, dynamic> json)
      : entities = List<Map<String, dynamic>>.from(json['entities'] ?? const []),
        nutriments = (json['nutriments'] as Map<String, dynamic>? ?? const {})
            .map((k, v) => MapEntry(k, Nutriment.fromJson(v as Map<String, dynamic>))),
        wordsDetected = json['words_detected'] as int? ?? 0;

  bool get foundTable => entities.isNotEmpty;
}

class NutritionScannerClient {
  final String? apiKey;
  final Future<String> Function()? getToken;
  final String baseUrl;
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

  /// Scan a local image file (JPEG/PNG/HEIC). Keep the long side at
  /// 1200-2000 px for best speed/accuracy.
  Future<ScanResult> scanFile(File image) =>
      scanBytes(image.readAsBytesSync(), filename: image.uri.pathSegments.last);

  Future<ScanResult> scanBytes(Uint8List bytes,
      {String filename = 'label.jpg'}) async {
    final request = http.MultipartRequest(
        'POST', Uri.parse('$baseUrl/extract'))
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
    return ScanResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}

/// Stability/sharpness detector for the `camera` package's image stream.
///
/// Wire-up (see README for the full example):
///   controller.startImageStream((frame) {
///     detector.addFrame(frame.planes[0].bytes,
///         frame.width, frame.height, frame.planes[0].bytesPerRow);
///   });
/// When [onTrigger] fires: stop the stream, take a picture, scan it, and call
/// [rearmAfterEmptyResult] if the scan found nothing.
class AutoCaptureDetector {
  final void Function() onTrigger;
  final void Function(String status)? onStatus;

  final int stableSamples;
  /// Floor of the adaptive stillness threshold.
  final double motionStable;

  /// The adaptive stillness threshold never exceeds this.
  final double motionCeil;
  final double motionRearm;
  final double sharpnessMin;
  final int maxAttempts;
  final Duration sampleEvery;
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
  int attempts = 0;
  bool _armed = true;
  bool paused = false;

  static const int _w = 64, _h = 48;

  /// Feed the luminance (Y) plane of each preview frame.
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
      paused = true; // caller resumes via rearmAfterEmptyResult or a new detector
      onTrigger();
    }
  }

  /// Call after a scan that found no nutrition table: requires a deliberate
  /// reposition (big motion) before the next attempt.
  void rearmAfterEmptyResult() {
    _armed = false;
    paused = false;
    onStatus?.call(attempts >= maxAttempts
        ? 'No nutrition table found — capture manually.'
        : 'No nutrition table found — aim at the label, then hold steady.');
  }
}
