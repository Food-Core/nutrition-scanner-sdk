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

final result = await scanner.scanFile(File(photo.path));
if (result.foundTable) {
  final kcal = result.nutriments['energy_kcal_100g'];
  print('${kcal?.value} ${kcal?.unit}');   // 449.0 kcal
} else {
  // Normal outcome for a photo without a nutrition table — retake.
}
```

Also available: `scanBytes(Uint8List)`. Errors throw `ScanException` with
`.status` (see [../README.md](../README.md#api-contract)). Keep uploads at
1200–2000 px on the long side.

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
