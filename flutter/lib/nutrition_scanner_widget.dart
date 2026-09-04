/// All-in-one scanner widget. Drop [NutritionScanner] into your tree and get
/// a working label scanner — camera, auto-capture, viewfinder overlay,
/// freeze-frame, flash, scanning and retry flow are all handled internally.
///
/// ```dart
/// NutritionScanner(
///   apiKey: 'nls_...',
///   onResult: (result) => Navigator.pop(context, result),
/// )
/// ```
library nutrition_scanner_widget;

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'label_check.dart';
import 'nutrition_scanner.dart';

/// A complete nutrition-label scanner in one widget.
///
/// Owns the whole pipeline: opens the back camera (correct YUV format for
/// detection), watches the preview for a steady + sharp frame, auto-captures,
/// freezes the frame while showing the "Analyzing label…" animation, calls
/// the API, and either delivers a [ScanResult] via [onResult] or guides the
/// user to reposition and retries. Also handles app backgrounding, a manual
/// shutter button, and the flash toggle.
///
/// Minimal use:
/// ```dart
/// NutritionScanner(
///   apiKey: 'nls_...',
///   onResult: (result) => Navigator.pop(context, result),
/// )
/// ```
///
/// The widget fills whatever space it is given — typically the body of a
/// full-screen route.
class NutritionScanner extends StatefulWidget {
  /// Platform API key (`nls_…`). Alternative: pass a preconfigured [client].
  final String? apiKey;

  /// Preconfigured API client (custom baseUrl/timeout/getToken). Overrides
  /// [apiKey] when provided.
  final NutritionScannerClient? client;

  /// Called exactly once with a successful scan. Typically pops the route:
  /// `onResult: (r) => Navigator.pop(context, r)`. The widget freezes on the
  /// scanned photo after this fires.
  final void Function(ScanResult result) onResult;

  /// Optional: called on scan/camera errors (e.g. [ScanException], camera
  /// permission failures) after the widget has already shown the user a
  /// friendly status and resumed scanning where possible.
  final void Function(Object error)? onError;

  /// Auto-capture when the phone is steady and the image is sharp
  /// (default). When false, only the manual shutter button scans.
  final bool autoCapture;

  /// Master switch for the viewfinder overlay (brackets, scan line, status,
  /// flash). When false, only the raw preview and shutter button render.
  final bool showOverlay;

  /// Corner-bracket framing box.
  final bool brackets;

  /// Flash (torch) toggle button.
  final bool showFlash;

  /// Manual shutter button at the bottom of the view.
  final bool showCaptureButton;

  /// Text shown with the scan-line animation while a scan is in flight.
  final String analyzingText;

  /// Auto-capture attempts per session before the user is told to use the
  /// manual shutter.
  final int maxAttempts;

  /// Camera resolution. [ResolutionPreset.high] (default) balances OCR
  /// quality and upload size.
  final ResolutionPreset resolution;

  /// On-device label intelligence (ML Kit, offline): verify the photo shows a
  /// nutrition label before spending an API call, and crop it to the text
  /// region for better OCR accuracy. Disable to skip both.
  final bool smartCapture;

  /// Upload the text-region crop instead of the full frame (needs
  /// [smartCapture]). More pixels per character → fewer OCR misreads.
  final bool cropToLabel;

  /// Reject auto-captures whose photo shows no nutrition keywords (needs
  /// [smartCapture]) — the user is told to aim at the label instead of
  /// wasting a scan. Manual shutter presses are never rejected.
  final bool requireNutritionText;

  /// Override the keyword list used by [requireNutritionText]
  /// (defaults to [kDefaultNutritionKeywords], multi-language).
  final List<String>? nutritionKeywords;

  /// Detector threshold overrides (stillness/sharpness/text gate). Leave null
  /// for the spec defaults.
  final AutoCaptureTuning? tuning;

  const NutritionScanner({
    super.key,
    this.apiKey,
    this.client,
    required this.onResult,
    this.onError,
    this.autoCapture = true,
    this.showOverlay = true,
    this.brackets = true,
    this.showFlash = true,
    this.showCaptureButton = true,
    this.analyzingText = 'Analyzing label…',
    this.maxAttempts = 6,
    this.resolution = ResolutionPreset.high,
    this.smartCapture = true,
    this.cropToLabel = true,
    this.requireNutritionText = true,
    this.nutritionKeywords,
    this.tuning,
  }) : assert(apiKey != null || client != null, 'Provide apiKey or client.');

  @override
  State<NutritionScanner> createState() => _NutritionScannerState();
}

class _NutritionScannerState extends State<NutritionScanner>
    with WidgetsBindingObserver {
  late final NutritionScannerClient _client =
      widget.client ?? NutritionScannerClient(apiKey: widget.apiKey!);
  late final AutoCaptureDetector _detector = AutoCaptureDetector(
    maxAttempts: widget.maxAttempts,
    stableSamples: widget.tuning?.stableSamples ?? 2,
    motionStable: widget.tuning?.motionStable ?? 10,
    motionCeil: widget.tuning?.motionCeil ?? 25,
    motionRearm: widget.tuning?.motionRearm ?? 30,
    sharpnessMin: widget.tuning?.sharpnessMin ?? 8,
    textRowsMin: widget.tuning?.textRowsMin ?? 8,
    textCrossings: widget.tuning?.textCrossings ?? 6,
    textEdge: widget.tuning?.textEdge ?? 16,
    onStatus: (message) {
      if (mounted && !_done) setState(() => _status = message);
    },
    onTrigger: () => _scanPhoto(auto: true),
  );
  late final LabelIntelligence _intel =
      LabelIntelligence(keywords: widget.nutritionKeywords);

  CameraController? _camera;
  String _status = '';
  String? _fatalError;
  bool _analyzing = false;
  bool _flashOn = false;
  bool _busy = false;
  bool _done = false;
  File? _frozen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _openCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.smartCapture) _intel.close();
    _camera?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera when backgrounded; reopen on return.
    if (_done) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _camera?.dispose();
      _camera = null;
    } else if (state == AppLifecycleState.resumed && _camera == null) {
      _openCamera();
    }
  }

  Future<void> _openCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        back,
        widget.resolution,
        enableAudio: false,
        // yuv420 on both platforms so planes[0] is the luma plane the
        // detector needs (iOS would otherwise default to BGRA).
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await camera.initialize();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      _camera = camera;
      if (widget.autoCapture) await camera.startImageStream(_feedDetector);
      setState(() => _status = 'Point the camera at the nutrition table…');
    } catch (error) {
      if (mounted) {
        setState(
            () => _fatalError = 'Camera unavailable — check permissions.');
      }
      widget.onError?.call(error);
    }
  }

  void _feedDetector(CameraImage frame) => _detector.addFrame(
        frame.planes[0].bytes,
        frame.width,
        frame.height,
        frame.planes[0].bytesPerRow,
      );

  Future<void> _scanPhoto({required bool auto}) async {
    final camera = _camera;
    if (camera == null || _busy || _done) return;
    _busy = true;
    try {
      if (camera.value.isStreamingImages) await camera.stopImageStream();
      final photo = await camera.takePicture();
      if (!mounted) return;
      setState(() {
        _frozen = File(photo.path); // freeze: the user can move their hand
        _analyzing = true;
      });

      // On-device intelligence: verify it's a label + crop to the text
      // region before spending the API call.
      var uploadPath = photo.path;
      if (widget.smartCapture) {
        final check =
            await _intel.analyze(photo.path, crop: widget.cropToLabel);
        if (!mounted) return;
        if (auto && widget.requireNutritionText && !check.hasNutritionText) {
          await _resumePreview();
          _detector.rearmAfterEmptyResult();
          setState(() => _status =
              "That doesn't look like a nutrition label — aim at the table.");
          return;
        }
        if (check.croppedFile != null) uploadPath = check.croppedFile!.path;
      }

      final result = await _client.scanPath(uploadPath);
      if (!mounted) return;
      if (result.foundTable) {
        setState(() {
          _analyzing = false;
          _done = true;
          _status = '';
        });
        widget.onResult(result);
        return;
      }
      await _resumePreview();
      if (auto) {
        _detector.rearmAfterEmptyResult();
      } else {
        setState(() =>
            _status = 'No nutrition table found — aim at the label and retry.');
      }
    } catch (error) {
      if (!mounted) return;
      await _resumePreview();
      _detector.rearmAfterEmptyResult();
      setState(() => _status = error is ScanException
          ? error.message
          : 'Scan failed — check your connection and retry.');
      widget.onError?.call(error);
    } finally {
      _busy = false;
    }
  }

  Future<void> _resumePreview() async {
    setState(() {
      _analyzing = false;
      _frozen = null;
    });
    final camera = _camera;
    if (camera != null &&
        widget.autoCapture &&
        !camera.value.isStreamingImages) {
      await camera.startImageStream(_feedDetector);
    }
  }

  Future<void> _toggleFlash() async {
    final camera = _camera;
    if (camera == null) return;
    _flashOn = !_flashOn;
    await camera.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_fatalError!, textAlign: TextAlign.center),
        ),
      );
    }
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(fit: StackFit.expand, children: [
      CameraPreview(camera),
      if (_frozen != null) Image.file(_frozen!, fit: BoxFit.cover),
      if (widget.showOverlay)
        ScannerOverlay(
          brackets: widget.brackets,
          analyzing: _analyzing,
          analyzingText: widget.analyzingText,
          status: _status,
          showFlash: widget.showFlash,
          flashOn: _flashOn,
          onToggleFlash: _toggleFlash,
        ),
      if (widget.showCaptureButton && !_analyzing && !_done)
        Align(
          alignment: const Alignment(0, 0.78),
          child: GestureDetector(
            onTap: () => _scanPhoto(auto: false),
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
                color: Colors.white24,
              ),
            ),
          ),
        ),
    ]);
  }
}

/// Threshold overrides for the auto-capture detector inside
/// [NutritionScanner]. All values default to the shared spec; see the repo
/// README for what each knob does.
class AutoCaptureTuning {
  final int stableSamples;
  final double motionStable;
  final double motionCeil;
  final double motionRearm;
  final double sharpnessMin;
  final int textRowsMin;
  final int textCrossings;
  final double textEdge;

  const AutoCaptureTuning({
    this.stableSamples = 2,
    this.motionStable = 10,
    this.motionCeil = 25,
    this.motionRearm = 30,
    this.sharpnessMin = 8,
    this.textRowsMin = 8,
    this.textCrossings = 6,
    this.textEdge = 16,
  });
}
