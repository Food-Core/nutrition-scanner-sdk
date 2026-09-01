# Nutrition Scanner — Flutter SDK

Scan food nutrition labels with the camera and get structured nutrient data.
One widget does everything; every public type has full dartdoc (hover in the
IDE for field meanings, ranges, and error semantics).

Status: **reference implementation** — passes `dart analyze` clean; not yet
exercised on physical devices. Test before shipping.

## Install

```yaml
dependencies:
  nutrition_scanner:
    git:
      url: https://github.com/Food-Core/nutrition-scanner-sdk.git
      path: flutter
```

Platform setup (required by the bundled `camera` plugin):
- iOS: add `NSCameraUsageDescription` to Info.plist
- Android: `minSdkVersion 21`

## Quickstart — the whole scanner is one widget

```dart
import 'package:nutrition_scanner/nutrition_scanner.dart';

final result = await Navigator.push<ScanResult>(
  context,
  MaterialPageRoute(
    builder: (context) => Scaffold(
      body: NutritionScanner(
        apiKey: 'nls_...',
        onResult: (result) => Navigator.pop(context, result),
      ),
    ),
  ),
);

if (result != null) {
  print(result.energyKcal100g?.value);  // 449.0
  print(result.proteins100g?.unit);     // 'g'
}
```

That's the entire integration. `NutritionScanner` internally handles:

- opening the back camera with the correct format, and releasing/reopening it
  when the app is backgrounded
- **auto capture** — watches the preview and fires when the phone is steady
  and the image is sharp (adaptive to each device's sensor)
- the **viewfinder overlay** — corner brackets, animated scan line +
  "Analyzing label…", status guidance, flash toggle
- **freeze-frame** — shows the captured photo while scanning so the user
  knows they can move their hand
- the API call, the "no table found → reposition and retry" flow, and a
  manual shutter button as fallback

### Configuration (all optional)

```dart
NutritionScanner(
  apiKey: 'nls_...',            // or client: NutritionScannerClient(...)
  onResult: (r) => ...,          // required
  onError: (e) => ...,           // errors, after the widget already handled UX
  autoCapture: true,             // false = manual shutter only
  showOverlay: true,             // master switch for all viewfinder chrome
  brackets: true,
  showFlash: true,
  showCaptureButton: true,
  analyzingText: 'Analyzing label…',
  maxAttempts: 6,
  resolution: ResolutionPreset.high,
)
```

## Scanning without the camera (gallery picks, server images)

```dart
final scanner = NutritionScannerClient(apiKey: 'nls_...');

final result = await scanner.scanPath(picked.path); // XFile.path works
// also: scanner.scanFile(File(...)) / scanner.scanBytes(Uint8List)

if (result.foundTable) {
  result.energyKcal100g?.value;          // typed getters for common nutrients
  result.nutriments['sugars_serving'];   // full map for everything else
} else {
  // No nutrition table in the image — a normal outcome, not an error.
}
```

Errors throw `ScanException` (`.status`, `.message`, `.isRetryable`):
401 bad/revoked key, 400 undecodable image, 429/5xx retry with backoff.
Images: JPEG/PNG/WEBP/HEIC, best at 1200–2000 px on the long side.

## Advanced: compose it yourself

If the prebuilt widget doesn't fit (custom camera stack, custom chrome), the
pieces it is built from are exported individually:

- `NutritionScannerClient` — the API client
- `AutoCaptureDetector` — feed it preview frames, it fires `onTrigger` when
  steady + sharp (all thresholds are documented constructor params)
- `ScannerOverlay` — the viewfinder chrome as a standalone widget

Read `nutrition_scanner_widget.dart` as the reference wiring.

## Auth & security

`apiKey:` or a `client:` with `getToken:` (Firebase ID token). Read
[../README.md](../README.md#api-key-security) before embedding a key in a
published app.
