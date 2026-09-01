# Nutrition Scanner — Web SDK

Zero-dependency ES module. This is the same logic our production web app
runs, packaged for reuse.

## Install

Copy [`nutrition-scanner.js`](nutrition-scanner.js) into your project (or
serve it from your assets) and import it:

```js
import { NutritionScanner, AutoCapture } from "./nutrition-scanner.js";
```

## Authentication

```js
// With a platform API key (create/revoke in the web app's settings):
const scanner = new NutritionScanner({ apiKey: "nls_..." });

// Or with a signed-in Firebase user (what our own web app does):
const scanner = new NutritionScanner({
  getToken: () => firebaseAuth.currentUser.getIdToken(),
});
```

⚠️ An API key in browser source is visible to anyone. Fine for internal
tools; for public products proxy through your backend (see
[../README.md](../README.md#api-key-security)).

## Manual capture

```js
const input = document.querySelector("input[type=file]");
input.onchange = async () => {
  const result = await scanner.scan(input.files[0]);
  console.log(result.nutriments.energy_kcal_100g); // {value: 449, unit: "kcal", ...}
};
```

`scan()` accepts any `Blob`/`File` (JPEG/PNG/WEBP/HEIC), re-encodes to JPEG
≤2000 px when the browser can decode it, and returns the parsed response.
Failures throw `ScanError` with `.status` (see the error table in
[../README.md](../README.md#api-contract)).

## Auto capture

```js
const video = document.querySelector("video"); // needs autoplay playsinline muted
const auto = new AutoCapture(video, scanner, {
  onStatus: (msg) => (statusEl.textContent = msg),
  onResult: (result, capturedBlob) => showResults(result),
  onError: (err) => (statusEl.textContent = err.message),
});
await auto.start(); // asks for camera permission, begins watching
// ...
auto.stop(); // on cancel/unmount — releases the camera
```

Behavior (per the [shared spec](../README.md#auto-capture-algorithm)): waits
1 s, samples frames 4×/s, and fires one scan when the frame is steady and
sharp. Stillness is judged against an **adaptive bar** calibrated to the
device's own noise floor, so it works on shaky sensors without tuning. When
no table is found it tells the user to reposition and re-arms; it gives up
after 6 attempts.

Freeze-frame UX (recommended): use `onCapture(blob)` to swap the live video
for the captured still (the user knows they can move), and `onResume()` to
show the video again when another attempt is needed.

All thresholds can be overridden via the options object: `settleMs`,
`sampleMs`, `stableSamples`, `motionStable` (adaptive floor), `motionCeil`
(adaptive cap), `motionRearm`, `sharpnessMin`, `maxAttempts`,
`captureWidth` — defaults in `AUTO_DEFAULTS` match the production web app.

## Viewfinder overlay

`AutoCapture` ships a built-in overlay: corner brackets framing the shot, an
animated horizontal scan line with **"Analyzing label…"** while the scan is
in flight, in-frame status text, and a **flash toggle** (rendered only when
the device camera supports torch — Android Chrome mostly; iOS Safari doesn't
expose it). It mounts on the video's parent element.

```js
new AutoCapture(video, scanner, {
  ui: {
    enabled: true,        // false = render nothing
    brackets: true,
    scanLine: true,
    statusText: true,
    flashButton: true,    // hidden automatically when unsupported
    analyzingText: "Analyzing label…",
  },
  ...
});
```

Manual torch control is also available: `auto.torchSupported` and
`await auto.setTorch(true|false)`. `auto.captureFrame()` gives a manual
shutter (returns a JPEG Blob without scanning).

## API reference

| Export | Description |
|---|---|
| `NutritionScanner({apiKey, getToken, baseUrl})` | API client |
| `scanner.scan(blob) → Promise<Result>` | One extraction call |
| `AutoCapture(video, scanner, opts)` | Stability-gated capture controller |
| `auto.start() / auto.stop()` | Camera lifecycle |
| `ScanError` | Error with `.status` |
| `normalizeImage(blob, maxWidth?, quality?)` | Standalone JPEG re-encoder |
| `AUTO_DEFAULTS` / `UI_DEFAULTS` | Default thresholds / overlay options |
| `auto.captureFrame(maxWidth?)` | Manual shutter → JPEG Blob |
| `auto.torchSupported` / `auto.setTorch(on)` | Flash control |

Camera access requires HTTPS (or localhost) and a user-granted permission.
