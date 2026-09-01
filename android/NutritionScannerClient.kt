/**
 * Nutrition Scanner — Android SDK (Kotlin).
 *
 * Manual capture:
 *   val client = NutritionScannerClient(apiKey = "nls_...")
 *   val result = client.scan(file)          // call from a background thread/coroutine
 *
 * Auto capture: see AutoCaptureAnalyzer.kt (CameraX ImageAnalysis).
 *
 * Dependency: com.squareup.okhttp3:okhttp:4.x, org.json (bundled in Android).
 */
package com.foodcore.nutritionscanner

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

const val DEFAULT_BASE_URL = "https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app"

class ScanException(val status: Int, message: String) : Exception(message)

data class Nutriment(
    val text: String,
    val score: Double,
    val value: Double?,
    val unit: String?,
)

data class ScanResult(
    val nutriments: Map<String, Nutriment>,
    val entityCount: Int,
    val wordsDetected: Int,
    /** True when served from the server-side result cache (an identical
     *  label was scanned before). Values match a fresh scan; latency ~1 s. */
    val cached: Boolean,
    val rawJson: JSONObject,
) {
    val foundTable get() = entityCount > 0
}

class NutritionScannerClient(
    private val apiKey: String? = null,
    /** Alternative to apiKey: supplies a Firebase ID token of a verified user. */
    private val tokenProvider: (() -> String)? = null,
    private val baseUrl: String = DEFAULT_BASE_URL,
    timeoutSeconds: Long = 60,
) {
    init {
        require(apiKey != null || tokenProvider != null) { "Provide apiKey or tokenProvider." }
    }

    private val http = OkHttpClient.Builder()
        .callTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .build()

    /** Blocking — call from Dispatchers.IO. JPEG/PNG/HEIC accepted; keep the long side 1200-2000 px. */
    fun scan(image: File): ScanResult =
        scan(image.readBytes(), image.name)

    fun scan(imageBytes: ByteArray, filename: String = "label.jpg"): ScanResult {
        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart(
                "image", filename,
                imageBytes.toRequestBody("application/octet-stream".toMediaType())
            )
            .build()
        val request = Request.Builder()
            .url("$baseUrl/extract")
            .apply {
                if (apiKey != null) header("X-API-Key", apiKey)
                else header("Authorization", "Bearer ${tokenProvider!!()}")
            }
            .post(body)
            .build()

        http.newCall(request).execute().use { response ->
            val text = response.body?.string() ?: "{}"
            if (!response.isSuccessful) {
                val detail = runCatching { JSONObject(text).optString("detail") }
                    .getOrNull().takeUnless { it.isNullOrEmpty() }
                throw ScanException(response.code, detail ?: "HTTP ${response.code}")
            }
            val json = JSONObject(text)
            val nutriments = buildMap {
                val n = json.optJSONObject("nutriments") ?: JSONObject()
                for (key in n.keys()) {
                    val v = n.getJSONObject(key)
                    put(
                        key,
                        Nutriment(
                            text = v.optString("text"),
                            score = v.optDouble("score", 0.0),
                            value = if (v.has("value")) v.optDouble("value") else null,
                            unit = v.optString("unit").ifEmpty { null },
                        )
                    )
                }
            }
            return ScanResult(
                nutriments = nutriments,
                entityCount = json.optJSONArray("entities")?.length() ?: 0,
                wordsDetected = json.optInt("words_detected"),
                cached = json.optBoolean("cached", false),
                rawJson = json,
            )
        }
    }
}
