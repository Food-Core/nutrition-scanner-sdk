# Nutrition Scanner — Flutter SDK

Status: **reference implementation** — implements the API contract and the
[auto-capture spec](../README.md#auto-capture-algorithm); not yet exercised
on physical devices.

## Install

Add this folder as a path dependency:

```yaml
dependencies:
  nutrition_scanner:
    path: ../sdk/flutter
  camera: ^0.11.0   # only needed for auto capture
```

## Manual capture

```dart
import 'package:nutrition_scanner/nutrition_scanner.dart';

final scanner = NutritionScannerClient(apiKey: 'nls_...');

// From camera / image_picker (XFile.path), a File, or raw bytes:
final result = await scanner.scanPath(photo.path);
// ... or scanner.scanFile(File(...)) / scanner.scanBytes(Uint8List)

if (result.foundTable) {
  print(result.energyKcal100g?.value);   // 449.0 — typed getters for common
  print(result.proteins100g?.unit);      // 'g'     nutrients, or use
  print(result.nutriments['sugars_serving']); //     the full map by key
} else {
  // Normal outcome for a photo without a nutrition table — retake.
}
```

All public types (`ScanResult`, `Nutriment`, `ScanEntity`, `ScanException`,
`AutoCaptureDetector`, `ScannerOverlay`) carry full dartdoc — hover any
symbol in your IDE for field meanings, value ranges, and error semantics.
Errors throw `ScanException` with `.status` and an `.isRetryable` helper.
Keep uploads at 1200–2000 px on the long side.

## Auto capture

`AutoCaptureDetector` consumes the `camera` package's preview stream (the
Y/luminance plane) and fires `onTrigger` when the frame has been steady and
sharp for 3 consecutive samples:

```dart
late CameraController controller;
late AutoCaptureDetector detector;

detector = AutoCaptureDetector(
  onStatus: (msg) => setState(() => status = msg),
  onTrigger: () async {
    await controller.stopImageStream();
    final photo = await controller.takePicture();
    final result = await scanner.scanFile(File(photo.path));
    if (result.foundTable) {
      showResults(result);
    } else {
      await controller.startImageStream(_feed);
      detector.rearmAfterEmptyResult(); // waits for a reposition, then retries
    }
  },
);

void _feed(CameraImage frame) => detector.addFrame(
  frame.planes[0].bytes, frame.width, frame.height, frame.planes[0].bytesPerRow,
);

await controller.startImageStream(_feed);
```

Thresholds are constructor parameters with the spec defaults: the stillness
bar is adaptive (`motionStable = 10` floor, `motionCeil = 25` cap — see the
[spec](../README.md#auto-capture-algorithm)), plus `sharpnessMin = 8`,
`stableSamples = 2`, `motionRearm = 30`, `maxAttempts = 6`, `settle`,
`sampleEvery`. Recommended UX: freeze the preview on the captured photo
while scanning so the user knows they can move.

## Complete scan screen (copy-paste)

Camera preview that auto-captures when steady and returns a `ScanResult` —
overlay, freeze-frame, flash, and retry flow included:

```dart
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:nutrition_scanner/nutrition_scanner.dart';
import 'package:nutrition_scanner/scanner_overlay.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.onResult});

  /// Called once with the successful scan; pop the screen or show results.
  final void Function(ScanResult result) onResult;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final scanner = NutritionScannerClient(apiKey: 'nls_...');
  CameraController? camera;
  late final AutoCaptureDetector detector = AutoCaptureDetector(
    onStatus: (msg) => setState(() => status = msg),
    onTrigger: _captureAndScan,
  );

  String status = '';
  bool analyzing = false;
  bool flashOn = false;
  File? frozenFrame; // captured still shown while analyzing

  @override
  void initState() {
    super.initState();
    _openCamera();
  }

  Future<void> _openCamera() async {
    final cameras = await availableCameras();
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    camera = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
      // yuv420 on BOTH platforms so frame.planes[0] is the luma plane the
      // detector expects (iOS would otherwise default to BGRA).
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await camera!.initialize();
    await camera!.startImageStream(_feedDetector);
    if (mounted) setState(() {});
  }

  void _feedDetector(CameraImage frame) => detector.addFrame(
        frame.planes[0].bytes,
        frame.width,
        frame.height,
        frame.planes[0].bytesPerRow,
      );

  Future<void> _captureAndScan() async {
    final cam = camera;
    if (cam == null) return;
    try {
      await cam.stopImageStream();
      final photo = await cam.takePicture();
      setState(() {
        frozenFrame = File(photo.path); // freeze: user can move their hand
        analyzing = true;
      });
      final result = await scanner.scanPath(photo.path);
      if (!mounted) return;
      if (result.foundTable) {
        widget.onResult(result);
        return;
      }
      await _resumePreview(); // nothing found — wait for a reposition
      detector.rearmAfterEmptyResult();
    } on ScanException catch (e) {
      if (!mounted) return;
      await _resumePreview();
      detector.rearmAfterEmptyResult();
      setState(() => status = e.message);
    }
  }

  Future<void> _resumePreview() async {
    setState(() {
      analyzing = false;
      frozenFrame = null;
    });
    await camera?.startImageStream(_feedDetector);
  }

  @override
  void dispose() {
    camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = camera;
    if (cam == null || !cam.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(fit: StackFit.expand, children: [
      CameraPreview(cam),
      if (frozenFrame != null) Image.file(frozenFrame!, fit: BoxFit.cover),
      ScannerOverlay(
        analyzing: analyzing,
        status: status,
        flashOn: flashOn,
        onToggleFlash: () async {
          flashOn = !flashOn;
          await cam.setFlashMode(flashOn ? FlashMode.torch : FlashMode.off);
          setState(() {});
        },
      ),
    ]);
  }
}
```

Use it: `ScanScreen(onResult: (r) => Navigator.pop(context, r))`.
Don't forget `NSCameraUsageDescription` in Info.plist (iOS); the camera
plugin needs `minSdkVersion 21` on Android.

## Viewfinder overlay

`ScannerOverlay` (in `lib/scanner_overlay.dart`) stacks the standard scanner
chrome over your `CameraPreview`: corner brackets, an animated scan line +
**"Analyzing label…"** while a scan runs, status text, and a flash button.
Everything is a constructor flag; `visible: false` renders nothing.

```dart
Stack(children: [
  CameraPreview(controller),
  ScannerOverlay(
    analyzing: analyzing,
    status: status,
    flashOn: flashOn,
    onToggleFlash: () async {
      flashOn = !flashOn;
      await controller.setFlashMode(flashOn ? FlashMode.torch : FlashMode.off);
      setState(() {});
    },
    // brackets / showFlash / analyzingText / visible are all configurable
  ),
]);
```

Set `analyzing: true` while your `takePicture → scanFile` call is in flight.

## Auth & security

`apiKey:` or `getToken:` (async Firebase ID token). Read
[../README.md](../README.md#api-key-security) before embedding a key in a
published app.
