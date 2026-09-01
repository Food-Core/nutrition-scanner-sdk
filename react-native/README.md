# Nutrition Scanner — React Native / Expo SDK

Status: **reference implementation** — implements the API contract and the
auto-capture spec; not yet exercised on physical devices.

## Install

Copy `src/` into your app (or add this folder as a workspace package).
Auto capture additionally needs `expo-sensors` and a camera component
(`expo-camera` shown below). Manual capture has zero dependencies.

## Manual capture

```tsx
import { NutritionScanner } from "@food-core/nutrition-scanner";
import * as ImageManipulator from "expo-image-manipulator";

const scanner = new NutritionScanner({ apiKey: "nls_..." });

async function scanPhoto(uri: string) {
  // Recommended: bake rotation + shrink before upload.
  const jpeg = await ImageManipulator.manipulateAsync(
    uri,
    [{ resize: { width: 1600 } }],
    { compress: 0.85, format: ImageManipulator.SaveFormat.JPEG }
  );
  return scanner.scanUri(jpeg.uri);
}
```

Works with `expo-image-picker` (gallery) and `expo-camera` (shutter button)
alike — anything that yields a file URI.

## Auto capture

Stability is detected with the **accelerometer** (RN can't cheaply sample
camera frames in JS); the OS autofocus locks once the phone is still, so a
steady phone is a sharp photo in practice.

```tsx
import { CameraView } from "expo-camera";
import { NutritionScanner } from "@food-core/nutrition-scanner";
import { useAutoCapture } from "@food-core/nutrition-scanner/src/useAutoCapture";

const scanner = new NutritionScanner({ apiKey: "nls_..." });

function ScanScreen() {
  const cameraRef = useRef<CameraView>(null);
  const [status, setStatus] = useState("");

  const auto = useAutoCapture({
    scanner,
    takePicture: () => cameraRef.current!.takePictureAsync({ quality: 0.85 }),
    onStatus: setStatus,
    onResult: (result) => navigation.navigate("Results", { result }),
    onError: (e) => setStatus(e.message),
  });

  return (
    <View style={{ flex: 1 }}>
      <CameraView ref={cameraRef} style={{ flex: 1 }} onCameraReady={auto.start} />
      <Text>{status}</Text>
      <Button title="Cancel" onPress={auto.stop} />
    </View>
  );
}
```

### Options (all optional)

| Option | Default | Meaning |
|---|---|---|
| `stableMs` | 900 | How long the phone must be still before the shutter fires |
| `jitterThreshold` | 0.03 g | Floor of the adaptive stillness bar |
| `jitterCeil` | 0.1 g | Cap of the adaptive stillness bar |
| `rearmThreshold` | 0.2 g | Movement that re-arms after an empty result |
| `settleMs` | 1000 | Grace period after start |
| `maxAttempts` | 6 | Attempts per session before giving up |

## Viewfinder overlay

`ScannerOverlay` renders the standard scanner chrome over your camera view:
corner brackets, an animated scan line + **"Analyzing label…"** while a scan
runs, status text, and a flash button. Everything is a prop; `visible={false}`
renders nothing.

```tsx
import { ScannerOverlay } from "@food-core/nutrition-scanner/src/ScannerOverlay";

const [analyzing, setAnalyzing] = useState(false);
const [flashOn, setFlashOn] = useState(false);

<View style={{ flex: 1 }}>
  <CameraView ref={cameraRef} style={StyleSheet.absoluteFill} enableTorch={flashOn} />
  <ScannerOverlay
    analyzing={analyzing}
    status={status}
    flashOn={flashOn}
    onToggleFlash={() => setFlashOn((v) => !v)}
    // brackets / showFlash / analyzingText / visible are all configurable
  />
</View>
```

Set `analyzing={true}` while your `takePicture → scanUri` call is in flight.

## Auth & security

`{ apiKey }` or `{ getToken }` (Firebase ID token) — see
[../README.md](../README.md#api-key-security) before shipping a key inside a
public app binary.

## Errors

`scanUri` throws `ScanError` with `.status`; empty `entities` is a normal
"no table in frame" outcome, not an error.
