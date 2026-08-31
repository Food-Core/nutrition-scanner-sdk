# Nutrition Scanner — Android SDK (Kotlin)

Status: **reference implementation** — implements the API contract and the
[auto-capture spec](../README.md#auto-capture-algorithm); not yet exercised
on physical devices.

## Install

Copy the two Kotlin files into your app (package
`com.foodcore.nutritionscanner`) and add:

```kotlin
dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // Auto capture only:
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")
}
```

## Manual capture

```kotlin
val client = NutritionScannerClient(apiKey = "nls_...")

// From any picker/shutter result, on a background dispatcher:
lifecycleScope.launch(Dispatchers.IO) {
    try {
        val result = client.scan(photoFile)
        if (result.foundTable) {
            val kcal = result.nutriments["energy_kcal_100g"]
            // kcal?.value == 449.0, kcal?.unit == "kcal"
        } else {
            // Normal "no table in frame" outcome — ask the user to retake.
        }
    } catch (e: ScanException) {
        // e.status: 401 bad key, 403 unverified user, 400 bad image, 5xx retry
    }
}
```

Keep uploads at 1200–2000 px on the long side (downscale with your image
loader before `scan`).

## Auto capture

`AutoCaptureAnalyzer` plugs into CameraX's `ImageAnalysis` and fires when the
preview is steady and sharp; you then take one full-res photo and scan it:

```kotlin
val analyzer = AutoCaptureAnalyzer(
    onStatus = { msg -> runOnUiThread { statusView.text = msg } },
    onTrigger = {
        imageCapture.takePicture(outputOptions, executor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    lifecycleScope.launch(Dispatchers.IO) {
                        val result = client.scan(photoFile)
                        if (result.foundTable) showResults(result)
                        else analyzer.rearmAfterEmptyResult()
                    }
                }
                override fun onError(e: ImageCaptureException) =
                    analyzer.rearmAfterEmptyResult()
            })
    },
)

val analysis = ImageAnalysis.Builder()
    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
    .build()
    .also { it.setAnalyzer(cameraExecutor, analyzer) }

cameraProvider.bindToLifecycle(this, cameraSelector, preview, imageCapture, analysis)
```

Thresholds are constructor parameters with the spec defaults: the stillness
bar is adaptive (`motionStable = 10.0` floor, `motionCeil = 25.0` cap — see
the [spec](../README.md#auto-capture-algorithm)), plus `sharpnessMin = 8.0`,
`stableSamples = 2`, `motionRearm = 30.0`, `maxAttempts = 6`,
`settleMs = 1000`, `sampleEveryMs = 250`. Recommended UX: freeze the preview
on the captured photo while scanning so the user knows they can move.

## Auth & security

`apiKey =` or `tokenProvider =` (returns a Firebase ID token). Read
[../README.md](../README.md#api-key-security) before shipping a key inside a
public APK.
