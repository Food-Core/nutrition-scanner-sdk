# Nutrition Scanner — iOS SDK (Swift)

Status: **reference implementation** — implements the API contract and the
[auto-capture spec](../README.md#auto-capture-algorithm); not yet exercised
on physical devices. No third-party dependencies.

## Install

Copy the two Swift files into your app target. Add
`NSCameraUsageDescription` to Info.plist for auto capture.

## Manual capture

```swift
let client = NutritionScannerClient(apiKey: "nls_...")

// From a picker/shutter UIImage — resize to ≤2000 px, JPEG-encode, scan:
let data = image.jpegData(compressionQuality: 0.85)!
let result = try await client.scan(imageData: data)

if result.foundTable {
    let kcal = result.nutriments["energy_kcal_100g"]
    print(kcal?.value ?? 0, kcal?.unit ?? "")   // 449.0 kcal
} else {
    // Normal "no table in frame" outcome — ask the user to retake.
}
```

HEIC data from the camera is accepted as-is (the server transcodes), but
JPEG after a resize uploads faster. Errors throw `ScanError.http(status:detail:)`
(401 bad key, 403 unverified user, 400 bad image, 5xx retry).

## Auto capture

`AutoCaptureController` is an `AVCaptureVideoDataOutputSampleBufferDelegate`
that fires `onTrigger` when the preview is steady and sharp; you then capture
one full-res photo and scan it:

```swift
let auto = AutoCaptureController()
auto.onStatus = { msg in DispatchQueue.main.async { self.statusLabel.text = msg } }
auto.onTrigger = { [weak self] in
    self?.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self!)
}

// Session setup (once):
let videoOutput = AVCaptureVideoDataOutput()
videoOutput.setSampleBufferDelegate(auto, queue: DispatchQueue(label: "autocapture"))
session.addOutput(videoOutput)   // alongside your AVCapturePhotoOutput + preview layer

// In your AVCapturePhotoCaptureDelegate:
func photoOutput(_ output: AVCapturePhotoOutput,
                 didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard let data = photo.fileDataRepresentation() else { return auto.rearmAfterEmptyResult() }
    Task {
        do {
            let result = try await client.scan(imageData: data)
            if result.foundTable { await showResults(result) }
            else { auto.rearmAfterEmptyResult() }   // waits for reposition, retries
        } catch {
            auto.rearmAfterEmptyResult()
        }
    }
}
```

Thresholds are public properties with the spec defaults: the stillness bar
is adaptive (`motionStable = 10` floor, `motionCeil = 25` cap — see the
[spec](../README.md#auto-capture-algorithm)), plus `sharpnessMin = 8`,
`stableSamples = 2`, `motionRearm = 30`, `maxAttempts = 6`, `settle = 1.0`,
`sampleEvery = 0.25`. Recommended UX: freeze the preview on the captured
photo while scanning so the user knows they can move.

## Viewfinder overlay

`ScannerOverlayView` draws the standard scanner chrome over your preview
layer: corner brackets, an animated scan line + **"Analyzing label…"** while
a scan runs, status text, and a flash button (toggles the torch by default,
or assign `onToggleFlash`). All configurable; `showsBrackets` /
`showsFlashButton` / `analyzingText` properties, `isHidden = true` hides all.

```swift
let overlay = ScannerOverlayView(frame: previewContainer.bounds)
overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
previewContainer.addSubview(overlay)

auto.onStatus = { msg in DispatchQueue.main.async { overlay.setStatus(msg) } }
auto.onTrigger = { [weak self] in
    DispatchQueue.main.async { overlay.setAnalyzing(true) }
    self?.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self!)
    // after client.scan(...) completes: overlay.setAnalyzing(false)
}
```

## Auth & security

`apiKey:` or `tokenProvider:` (async Firebase ID token). Read
[../README.md](../README.md#api-key-security) before shipping a key inside a
public app binary.
