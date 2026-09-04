# Nutrition Scanner SDKs

Official client SDKs for the **Nutrition Label Scanner API** — point a camera
at any food nutrition label and get structured nutrient data back in seconds:

```json
{
  "energy_kcal_100g": {"value": 449.0, "unit": "kcal", "score": 0.999},
  "fat_100g":         {"value": 16.6,  "unit": "g",    "score": 0.999},
  "proteins_100g":    {"value": 4.1,   "unit": "g",    "score": 0.999}
}
```

Under the hood: Google Cloud Vision OCR + the Open Food Facts
[nutrition-extractor](https://huggingface.co/openfoodfacts/nutrition-extractor)
model (LayoutLMv3), served from our infrastructure. Typical scan: **3–4 s**.

## Platforms

Every SDK offers the same two capture modes — **manual** (send an image) and
**auto capture** (watch the live camera and scan automatically at the ideal
moment, no shutter button):

| Platform | Directory | Auto-capture mechanism | Status |
|---|---|---|---|
| Web (browser JS, zero deps) | [web/](web/) | Frame differencing | **Production** — powers our own web app |
| React Native / Expo | [react-native/](react-native/) | Accelerometer stability | Reference implementation |
| Flutter | [flutter/](flutter/) | Camera stream luma analysis | Reference implementation |
| Android (Kotlin, CameraX) | [android/](android/) | ImageAnalysis analyzer | Reference implementation |
| iOS (Swift, AVFoundation) | [ios/](ios/) | Sample-buffer delegate | Reference implementation |
| Python (server-side) | [python/](python/) | n/a (manual only) | **Production** |

*Reference implementation* = implements the exact API contract and algorithm
spec, reviewed but not yet exercised on physical devices. Test before
shipping; issues and PRs welcome.

## Getting an API key

1. Create an account at **https://nutrition-scanner-web-riiqvjsmkq-uc.a.run.app**
   (email verification required).
2. Open **API keys** in the app and generate a key (`nls_…`). It's shown once —
   store it safely. Keys can be revoked instantly from the same screen.

Interactive API docs (Swagger):
**https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app/docs**

## 60-second quickstart

```bash
curl -H "X-API-Key: nls_..." -F "image=@label.jpg" \
  https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app/extract
```

Or with the web SDK:

```js
import { NutritionScanner } from "./web/nutrition-scanner.js";
const scanner = new NutritionScanner({ apiKey: "nls_..." });
const result = await scanner.scan(file);
```

Each platform directory has a full README with install steps, manual + auto
capture examples, options, and error handling.

## API contract

Base URL: `https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app`

### `POST /extract`

Multipart form upload, field name `image` (JPEG, PNG, WEBP, or HEIC — iPhone
photos work as-is).

| Header | Value |
|---|---|
| `X-API-Key` | Your `nls_…` key |

Response `200`:

```json
{
  "entities": [
    {"label": "ENERGY_KCAL_100G", "text": "449kcal", "score": 0.999}
  ],
  "nutriments": {
    "energy_kcal_100g": {"text": "449kcal", "score": 0.999, "value": 449.0, "unit": "kcal"},
    "proteins_100g":    {"text": "4.1g",    "score": 0.999, "value": 4.1,   "unit": "g"}
  },
  "words_detected": 102
}
```

`nutriments` keys follow `<nutrient>_(100g|serving)`, plus `serving_size`.
The complete nutrient vocabulary: energy (kJ and kcal), fat, saturated fat,
trans fat, cholesterol, carbohydrates, sugars, added sugars, fiber, proteins,
salt, sodium, calcium, iron, potassium, vitamin D — per 100g and per serving,
whichever the label prints. An image with **no nutrition table** returns
`entities: []`; treat that as "reposition and retry", not an error.

Notes on values:

- Responses may include `"cached": true` — the extraction was served from the
  server-side result cache (an identical label was scanned before). Values
  are identical to a fresh scan; latency is ~1 s. Whether caching applies is
  controlled **per API key** in the web app's settings.
- "less than" amounts (e.g. `<1g`) parse to the printed bound
  (`value: 1.0`) with the raw `text` (`"< 1g"`) preserving the qualifier.

Errors:

| Status | Meaning | Client behavior |
|---|---|---|
| 400 | Not a decodable image | Fix the upload |
| 401 | Missing/invalid/revoked key | Check the key |
| 429/5xx | Transient | Retry with backoff |

Typical latency is 3–4 s warm; allow a 60 s timeout to survive rare cold
starts.

### Capture guidelines (all platforms)

- Photograph the nutrition table itself, upright, filling most of the frame.
- Send **1200–2000 px** on the long side, JPEG quality ~0.85. Bigger wastes
  upload time (the server downscales past 2000 px); smaller hurts OCR.
- Bake EXIF rotation into pixels before upload (re-encode via canvas/bitmap).

## Auto-capture algorithm

All camera SDKs implement this spec:

1. Open the camera, wait **1000 ms** for exposure/focus to settle.
2. Every **250 ms**, downsample the current frame to ~**64×48 grayscale**.
3. Compute:
   - **motion** = mean absolute luma difference vs. the previous sample,
     **after subtracting each frame's mean luma** — cancels auto-exposure
     flicker, which otherwise reads as motion
   - **sharpness** = mean horizontal+vertical neighbor gradient
4. **Adaptive stillness bar**: track the last ~16 motion values; the phone
   counts as still when `motion < clamp(noiseFloor × 1.6, 10, 25)` where
   `noiseFloor` is the smallest recent motion. This self-calibrates to each
   device's sensor noise and focus hunting — never hard-code a fixed bar.
5. **Text gate**: count gradient sign-flips per sample row; a row with ≥6
   strong flips reads as a text line. Require **≥8 text rows** before any
   capture — a steady hand aimed at a desk or wall never fires. (The React
   Native reference uses the accelerometer and cannot see frames, so it
   skips this gate; use the platform's text detector there if needed.)
6. When still, sharp, **and text is present** for **2 consecutive samples** → capture
   one full-resolution frame (≤ 2000 px JPEG) and call `/extract`. **Freeze
   the UI on the captured still** while scanning so the user knows they can
   move their hand.
7. If the result has entities → done. If empty → resume the live preview,
   *disarm*, tell the user to reposition, and re-arm only after
   **motion > 30** (a deliberate move) followed by stillness again.
8. Stop after **6 attempts** per session; offer manual capture. Do **not**
   force-capture on a timer — users find surprise captures worse than
   waiting (validated in testing).

Sampling stays on-device and costs nothing; only step 5 hits the API.

### Customization

Every SDK exposes these as constructor options / parameters:

| Option | Default | Meaning |
|---|---|---|
| `settleMs` | 1000 | Camera warm-up before sampling starts |
| `sampleMs` | 250 | Sampling interval |
| `stableSamples` | 2 | Consecutive still+sharp samples required |
| `motionStable` | 10 | Floor of the adaptive stillness bar |
| `motionCeil` | 25 | Cap of the adaptive stillness bar |
| `motionRearm` | 30 | Motion that re-arms after an empty result |
| `sharpnessMin` | 8 | Minimum sharpness (edge energy) |
| `textRowsMin` | 8 | Text rows required before capturing (0 disables the text gate) |
| `textCrossings` / `textEdge` | 6 / 16 | What counts as a text row (flips per row / flip magnitude) |
| `maxAttempts` | 6 | Scans per session before giving up |
| callbacks | — | `onStatus`, `onResult`/`onTrigger`, `onError`; web also `onCapture`/`onResume` for freeze-frame UX |
| `ui` / overlay | shown | Viewfinder overlay: corner brackets, animated scan line + "Analyzing label…" while scanning, in-frame status, flash toggle. Every element toggleable; hide entirely (`ui.enabled=false` on web, `visible=false` / `isHidden` on mobile); analyzing text customizable |

(React Native uses accelerometer equivalents: `jitterThreshold`/`jitterCeil`
in g instead of motion values, `stableMs` instead of `stableSamples`.)

## API key security

API keys are bearer credentials. For **server-side** use, keep them in your
secret store. For **shipped mobile/web apps**, an embedded key can be lifted
from the binary — acceptable for internal tools; for production consumer
apps, proxy scans through your own backend or issue per-user keys you can
revoke individually.

## License

[MIT](LICENSE)
