/**
 * Nutrition Scanner — Web SDK (ES module, zero dependencies).
 *
 * Manual capture:
 *   const scanner = new NutritionScanner({ apiKey: "nls_..." });
 *   const result = await scanner.scan(fileOrBlob);
 *
 * Auto capture (stability-gated, one API call per good hold):
 *   const auto = new AutoCapture(videoElement, scanner, {
 *     onStatus: (msg) => ...,
 *     onResult: (result, blob) => ...,
 *     onError: (err) => ...,
 *   });
 *   await auto.start();  // opens the camera and begins watching
 *   auto.stop();
 */

const DEFAULT_BASE_URL = "https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app";

export class NutritionScanner {
  /**
   * @param {Object} options
   * @param {string} [options.apiKey]  Platform API key (nls_…).
   * @param {() => Promise<string>} [options.getToken]  Alternative: returns a
   *        Firebase ID token of a signed-in, email-verified user.
   * @param {string} [options.baseUrl]
   */
  constructor({ apiKey, getToken, baseUrl = DEFAULT_BASE_URL } = {}) {
    if (!apiKey && !getToken) throw new Error("Provide apiKey or getToken.");
    this.apiKey = apiKey;
    this.getToken = getToken;
    this.baseUrl = baseUrl.replace(/\/$/, "");
  }

  async _headers() {
    if (this.apiKey) return { "X-API-Key": this.apiKey };
    return { Authorization: `Bearer ${await this.getToken()}` };
  }

  /**
   * Scan one image. Re-encodes to JPEG ≤2000px when the browser can decode it
   * (bakes EXIF rotation, shrinks upload); otherwise sends original bytes.
   * @param {Blob|File} image
   * @returns {Promise<{entities: Array, nutriments: Object, words_detected: number}>}
   */
  async scan(image) {
    const blob = await normalizeImage(image);
    const form = new FormData();
    form.append("image", blob, "label.jpg");
    const response = await fetch(`${this.baseUrl}/extract`, {
      method: "POST",
      headers: await this._headers(),
      body: form,
    });
    if (!response.ok) {
      const detail = (await response.json().catch(() => ({}))).detail;
      throw new ScanError(response.status, detail || `HTTP ${response.status}`);
    }
    return response.json();
  }
}

export class ScanError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "ScanError";
    this.status = status;
  }
}

export async function normalizeImage(blob, maxWidth = 2000, quality = 0.87) {
  try {
    const bitmap = await createImageBitmap(blob);
    const scale = Math.min(1, maxWidth / bitmap.width);
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return await new Promise((resolve, reject) =>
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("encode failed"))), "image/jpeg", quality)
    );
  } catch {
    return blob; // format the browser can't decode — the server copes
  }
}

/** Defaults follow the shared auto-capture spec in sdk/README.md. */
export const AUTO_DEFAULTS = {
  settleMs: 1000, // camera warm-up before sampling starts
  sampleMs: 250, // sampling interval
  stableSamples: 2, // consecutive still+sharp samples required
  motionStable: 10, // floor of the adaptive stillness threshold
  motionCeil: 25, // adaptive threshold never exceeds this
  motionRearm: 30, // motion above this re-arms after an empty result
  sharpnessMin: 8, // mean neighbor gradient below this = blurry
  maxAttempts: 6, // scans per session before giving up
  captureWidth: 1600, // long side of the captured JPEG
};

export class AutoCapture {
  /**
   * @param {HTMLVideoElement} video  Element to attach the camera stream to.
   * @param {NutritionScanner} scanner
   * @param {Object} callbacks  { onStatus, onResult, onError } + option overrides.
   */
  constructor(
    video,
    scanner,
    {
      onStatus = () => {},
      onResult = () => {},
      onError = () => {},
      /** Fires with the captured Blob right before scanning — ideal for
       *  freezing the UI (show the still instead of the live feed). */
      onCapture = () => {},
      /** Fires when the live feed should resume after an empty result. */
      onResume = () => {},
      ...options
    } = {}
  ) {
    this.video = video;
    this.scanner = scanner;
    this.onStatus = onStatus;
    this.onResult = onResult;
    this.onError = onError;
    this.onCapture = onCapture;
    this.onResume = onResume;
    this.options = { ...AUTO_DEFAULTS, ...options };
    this._reset();
  }

  _reset() {
    this.stream = null;
    this.timer = null;
    this.prevLuma = null;
    this.stillCount = 0;
    this.attempts = 0;
    this.armed = true;
    this.busy = false;
    this.motionHistory = [];
  }

  /** Opens the rear camera and starts watching for a steady, sharp frame. */
  async start() {
    this._reset();
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "environment", width: { ideal: 1920 } },
    });
    this.video.srcObject = this.stream;
    await this.video.play().catch(() => {});
    this.onStatus("Point the camera at the nutrition table…");
    setTimeout(() => {
      if (this.stream) this.timer = setInterval(() => this._tick(), this.options.sampleMs);
    }, this.options.settleMs);
  }

  stop() {
    clearInterval(this.timer);
    this.stream?.getTracks().forEach((t) => t.stop());
    this._reset();
  }

  _sample() {
    const w = 64, h = 48;
    const canvas = (this._canvas ??= document.createElement("canvas"));
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(this.video, 0, 0, w, h);
    const rgba = ctx.getImageData(0, 0, w, h).data;
    const luma = new Float32Array(w * h);
    for (let i = 0; i < w * h; i++) {
      luma[i] = 0.299 * rgba[4 * i] + 0.587 * rgba[4 * i + 1] + 0.114 * rgba[4 * i + 2];
    }
    return { luma, w, h };
  }

  _tick() {
    if (this.busy || !this.video.videoWidth) return;
    const { motionStable, motionCeil, motionRearm, sharpnessMin, stableSamples, maxAttempts } = this.options;
    const sample = this._sample();
    let motion = 255;
    if (this.prevLuma) {
      // Brightness-compensated diff: auto-exposure flicker isn't motion.
      let meanPrev = 0, meanCur = 0;
      for (let i = 0; i < sample.luma.length; i++) {
        meanPrev += this.prevLuma[i];
        meanCur += sample.luma[i];
      }
      meanPrev /= sample.luma.length;
      meanCur /= sample.luma.length;
      let sum = 0;
      for (let i = 0; i < sample.luma.length; i++) {
        sum += Math.abs(sample.luma[i] - meanCur - (this.prevLuma[i] - meanPrev));
      }
      motion = sum / sample.luma.length;
    }
    this.prevLuma = sample.luma;

    // Adaptive stillness bar: every camera has a different noise floor
    // (sensor noise, focus hunting), so "still" means "close to the quietest
    // this session has been", clamped to [motionStable, motionCeil].
    this.motionHistory.push(motion);
    if (this.motionHistory.length > 16) this.motionHistory.shift();
    const noiseFloor = Math.min(...this.motionHistory);
    const stillBar = Math.min(motionCeil, Math.max(motionStable, noiseFloor * 1.6));

    if (!this.armed) {
      if (motion > motionRearm && this.attempts < maxAttempts) {
        this.armed = true;
        this.onStatus("Hold steady over the nutrition table…");
      }
      return;
    }
    if (motion >= stillBar) {
      this.stillCount = 0;
      this.onStatus("Hold the phone still…");
      return;
    }
    let sharp = 0, n = 0;
    const { luma, w, h } = sample;
    for (let y = 0; y < h - 1; y++) {
      for (let x = 0; x < w - 1; x++) {
        const i = y * w + x;
        sharp += Math.abs(luma[i] - luma[i + 1]) + Math.abs(luma[i] - luma[i + w]);
        n++;
      }
    }
    if (sharp / n < sharpnessMin) {
      this.stillCount = 0;
      this.onStatus("Too blurry — move a little closer or improve the light…");
      return;
    }
    this.stillCount++;
    this.onStatus("Hold steady…");
    if (this.stillCount >= stableSamples) this._capture();
  }

  async _capture() {
    this.busy = true;
    this.attempts++;
    this.stillCount = 0;
    try {
      const scale = Math.min(1, this.options.captureWidth / this.video.videoWidth);
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(this.video.videoWidth * scale);
      canvas.height = Math.round(this.video.videoHeight * scale);
      canvas.getContext("2d").drawImage(this.video, 0, 0, canvas.width, canvas.height);
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.87));
      this.onCapture(blob); // freeze the UI on the captured still
      this.onStatus("Captured — scanning…");
      const result = await this.scanner.scan(blob);
      if ((result.entities || []).length > 0) {
        this.onResult(result, blob);
        this.stop();
        return;
      }
      this.armed = false;
      this.onResume(); // show the live feed again for another attempt
      this.onStatus(
        this.attempts >= this.options.maxAttempts
          ? "No nutrition table found — capture manually."
          : "No nutrition table found — aim at the label, then hold steady."
      );
    } catch (err) {
      this.armed = false;
      this.onResume();
      this.onError(err);
    } finally {
      this.busy = false;
    }
  }
}
