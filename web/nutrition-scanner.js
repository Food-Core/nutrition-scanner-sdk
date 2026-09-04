/**
 * Nutrition Scanner — Web SDK (ES module, zero dependencies).
 *
 * Manual capture:
 *   const scanner = new NutritionScanner({ apiKey: "nls_..." });
 *   const result = await scanner.scan(fileOrBlob);
 *
 * Auto capture with built-in viewfinder UI (corner brackets, animated scan
 * line + "Analyzing label…" while scanning, flash toggle):
 *   const auto = new AutoCapture(videoElement, scanner, {
 *     onStatus: (msg) => ...,
 *     onCapture: (blob) => ...,       // freeze your UI on the captured still
 *     onResume: () => ...,            // live feed resumes for another attempt
 *     onResult: (result, blob) => ...,
 *     onError: (err) => ...,
 *     ui: { enabled: true, flashButton: true, analyzingText: "Analyzing label…" },
 *   });
 *   await auto.start();  // opens the camera and begins watching
 *   auto.stop();
 */

const DEFAULT_BASE_URL = "https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app";

export class NutritionScanner {
  /**
   * @param {Object} options
   * @param {string} [options.apiKey]  Platform API key (nls_…).
   * @param {(forceRefresh: boolean) => Promise<string>} [options.getToken]
   *        Alternative: returns a Firebase ID token of a signed-in,
   *        email-verified user. Called with `true` when the SDK retries a
   *        401/403 (stale claims) — pass it through to getIdToken(force).
   * @param {string} [options.baseUrl]
   * @param {Object|(() => Object)} [options.extraHeaders]  Additional request
   *        headers (object, or a function evaluated per request) — e.g.
   *        {"X-Scan-Cache": "0"} to bypass server-side result caching.
   */
  constructor({ apiKey, getToken, baseUrl = DEFAULT_BASE_URL, extraHeaders } = {}) {
    if (!apiKey && !getToken) throw new Error("Provide apiKey or getToken.");
    this.apiKey = apiKey;
    this.getToken = getToken;
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.extraHeaders = extraHeaders;
  }

  async _headers(forceRefresh = false) {
    const extra =
      typeof this.extraHeaders === "function"
        ? this.extraHeaders()
        : this.extraHeaders || {};
    if (this.apiKey) return { "X-API-Key": this.apiKey, ...extra };
    return { Authorization: `Bearer ${await this.getToken(forceRefresh)}`, ...extra };
  }

  /**
   * Scan one image. Re-encodes to JPEG ≤2000px when the browser can decode it
   * (bakes EXIF rotation, shrinks upload); otherwise sends original bytes.
   * Retries once with a force-refreshed token on 401/403 (stale user claims).
   * @param {Blob|File} image
   * @returns {Promise<{entities: Array, nutriments: Object, words_detected: number, cached?: boolean}>}
   *          `cached: true` = served from the server-side result cache.
   */
  async scan(image) {
    const blob = await normalizeImage(image);
    const post = async (forceRefresh) => {
      const form = new FormData();
      form.append("image", blob, "label.jpg");
      return fetch(`${this.baseUrl}/extract`, {
        method: "POST",
        headers: await this._headers(forceRefresh),
        body: form,
      });
    };
    let response = await post(false);
    if ((response.status === 401 || response.status === 403) && this.getToken) {
      response = await post(true);
    }
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

/** Defaults follow the shared auto-capture spec in the repo README. */
export const AUTO_DEFAULTS = {
  settleMs: 1000, // camera warm-up before sampling starts
  sampleMs: 250, // sampling interval
  stableSamples: 2, // consecutive still+sharp samples required
  motionStable: 10, // floor of the adaptive stillness threshold
  motionCeil: 25, // adaptive threshold never exceeds this
  motionRearm: 30, // motion above this re-arms after an empty result
  sharpnessMin: 8, // mean neighbor gradient below this = blurry
  textRowsMin: 8, // sample rows that must look like text lines (0 disables)
  textCrossings: 6, // gradient sign-flips per row to count as a text row
  textEdge: 16, // minimum gradient magnitude for a flip to count
  maxAttempts: 6, // scans per session before giving up
  cropToText: true, // upload only the text-dense region (better OCR accuracy)
  captureWidth: 1600, // long side of the captured JPEG
  debug: false, // append [m/s/t] metrics to every status message (tuning)
};

/** Viewfinder UI defaults — set `ui: { enabled: false }` to render nothing. */
export const UI_DEFAULTS = {
  enabled: true, // master switch for the built-in overlay
  brackets: true, // corner-bracket framing box
  scanLine: true, // animated line while analyzing
  statusText: true, // status messages inside the viewfinder
  flashButton: true, // torch toggle (shown only when the device supports it)
  analyzingText: "Analyzing label…",
};

const OVERLAY_STYLE_ID = "nls-overlay-style";
const OVERLAY_CSS = `
.nls-overlay{position:absolute;inset:0;pointer-events:none;z-index:5;
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;}
.nls-corner{position:absolute;width:min(36px,10%);height:min(36px,10%);
  border:0 solid rgba(255,255,255,.92);border-radius:2px;}
.nls-tl{top:12%;left:12%;border-top-width:3px;border-left-width:3px;}
.nls-tr{top:12%;right:12%;border-top-width:3px;border-right-width:3px;}
.nls-bl{bottom:12%;left:12%;border-bottom-width:3px;border-left-width:3px;}
.nls-br{bottom:12%;right:12%;border-bottom-width:3px;border-right-width:3px;}
.nls-scanline{position:absolute;left:14%;right:14%;height:2px;top:14%;display:none;
  background:linear-gradient(90deg,transparent,rgba(255,255,255,.95),transparent);
  box-shadow:0 0 8px rgba(255,255,255,.7);
  animation:nls-scan 2.2s ease-in-out infinite alternate;}
@keyframes nls-scan{from{top:14%}to{top:calc(86% - 2px)}}
.nls-status{position:absolute;bottom:4%;left:4%;right:4%;text-align:center;
  color:#fff;font-size:15px;line-height:1.35;
  text-shadow:0 1px 4px rgba(0,0,0,.85);}
.nls-flash{position:absolute;top:10px;right:10px;pointer-events:auto;
  width:42px;height:42px;border:none;border-radius:50%;cursor:pointer;
  background:#000;display:none;align-items:center;justify-content:center;}
.nls-flash svg{fill:#fff;display:block;margin:auto;}
.nls-flash[aria-pressed="true"] svg{fill:#ffd60a;}
`;

export class AutoCapture {
  /**
   * @param {HTMLVideoElement} video  Element to attach the camera stream to.
   *        The overlay mounts on video.parentElement (made position:relative).
   * @param {NutritionScanner} scanner
   * @param {Object} callbacks  { onStatus, onCapture, onResume, onResult,
   *        onError, ui } + threshold overrides (see AUTO_DEFAULTS).
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
      ui = {},
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
    this.ui = { ...UI_DEFAULTS, ...ui };
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
    this.torchOn = false;
  }

  /** Opens the rear camera and starts watching for a steady, sharp frame. */
  async start() {
    this._reset();
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "environment", width: { ideal: 1920 } },
    });
    this.video.srcObject = this.stream;
    await this.video.play().catch(() => {});
    if (this.ui.enabled) this._mountOverlay();
    this._status("Point the camera at the nutrition table…");
    setTimeout(() => {
      if (this.stream) this.timer = setInterval(() => this._tick(), this.options.sampleMs);
    }, this.options.settleMs);
  }

  stop() {
    clearInterval(this.timer);
    if (this.torchOn) this.setTorch(false).catch(() => {});
    this.stream?.getTracks().forEach((t) => t.stop());
    this._unmountOverlay();
    this._reset();
  }

  /** Manual shutter: returns one full-res JPEG Blob without scanning it.
   *  Pass a {sx, sy, sw, sh} rect (video pixels) to capture a sub-region. */
  async captureFrame(maxWidth = this.options.captureWidth, rect = null) {
    if (!this.video.videoWidth) return null;
    const sx = rect ? rect.sx : 0;
    const sy = rect ? rect.sy : 0;
    const sw = rect ? rect.sw : this.video.videoWidth;
    const sh = rect ? rect.sh : this.video.videoHeight;
    const scale = Math.min(1, maxWidth / sw);
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(sw * scale);
    canvas.height = Math.round(sh * scale);
    canvas
      .getContext("2d")
      .drawImage(this.video, sx, sy, sw, sh, 0, 0, canvas.width, canvas.height);
    return new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.87));
  }

  /** Locate the text-dense region of the current frame (video pixels), or
   *  null when text spans the frame / there is too little of it. Same
   *  stroke-transition analysis as the text gate, at higher resolution. */
  _textCropRect() {
    const w = 128, h = 96;
    const video = this.video;
    if (!video.videoWidth) return null;
    const canvas = (this._cropCanvas ??= document.createElement("canvas"));
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(video, 0, 0, w, h);
    const rgba = ctx.getImageData(0, 0, w, h).data;
    const luma = new Float32Array(w * h);
    for (let i = 0; i < w * h; i++) {
      luma[i] = 0.299 * rgba[4 * i] + 0.587 * rgba[4 * i + 1] + 0.114 * rgba[4 * i + 2];
    }
    const edge = this.options.textEdge;
    // Thresholds scale with the doubled sample resolution.
    const rowBar = this.options.textCrossings * 2;
    const strong = new Uint8Array(w * h);
    const textyRow = new Uint8Array(h);
    let textyCount = 0;
    for (let y = 0; y < h; y++) {
      let crossings = 0, prevSign = 0;
      for (let x = 0; x < w - 1; x++) {
        const i = y * w + x;
        const dx = luma[i + 1] - luma[i];
        if (Math.abs(dx) >= edge) {
          strong[i] = 1;
          const sign = dx > 0 ? 1 : -1;
          if (prevSign !== 0 && sign !== prevSign) crossings++;
          prevSign = sign;
        }
      }
      if (crossings >= rowBar) {
        textyRow[y] = 1;
        textyCount++;
      }
    }
    if (textyCount < this.options.textRowsMin * 2) return null;
    let y0 = 0, y1 = h - 1;
    while (y0 < h && !textyRow[y0]) y0++;
    while (y1 > y0 && !textyRow[y1]) y1--;
    // Column bounds: strokes within the texty band.
    const colBar = Math.max(2, Math.round((y1 - y0) * 0.06));
    let x0 = -1, x1 = -1;
    for (let x = 0; x < w; x++) {
      let hits = 0;
      for (let y = y0; y <= y1; y++) hits += strong[y * w + x];
      if (hits >= colBar) {
        if (x0 === -1) x0 = x;
        x1 = x;
      }
    }
    if (x0 === -1 || x1 <= x0) return null;
    // Margin, map to video pixels, sanity-check the area.
    const mx = w * 0.06, my = h * 0.06;
    const fx0 = Math.max(0, x0 - mx) / w;
    const fy0 = Math.max(0, y0 - my) / h;
    const fx1 = Math.min(w, x1 + 1 + mx) / w;
    const fy1 = Math.min(h, y1 + 1 + my) / h;
    const area = (fx1 - fx0) * (fy1 - fy0);
    if (area > 0.9 || area < 0.12) return null;
    return {
      sx: Math.round(fx0 * video.videoWidth),
      sy: Math.round(fy0 * video.videoHeight),
      sw: Math.round((fx1 - fx0) * video.videoWidth),
      sh: Math.round((fy1 - fy0) * video.videoHeight),
    };
  }

  /** True when the device camera supports a torch (mostly Android Chrome). */
  get torchSupported() {
    const track = this.stream?.getVideoTracks()[0];
    return Boolean(track?.getCapabilities?.().torch);
  }

  async setTorch(on) {
    const track = this.stream?.getVideoTracks()[0];
    if (!track) return;
    await track.applyConstraints({ advanced: [{ torch: on }] });
    this.torchOn = on;
    if (this._flashBtn) this._flashBtn.setAttribute("aria-pressed", String(on));
  }

  // ---------- overlay ----------

  _mountOverlay() {
    if (!document.getElementById(OVERLAY_STYLE_ID)) {
      const style = document.createElement("style");
      style.id = OVERLAY_STYLE_ID;
      style.textContent = OVERLAY_CSS;
      document.head.appendChild(style);
    }
    const parent = this.video.parentElement;
    if (!parent) return;
    if (getComputedStyle(parent).position === "static") {
      parent.style.position = "relative";
    }
    const overlay = document.createElement("div");
    overlay.className = "nls-overlay";
    if (this.ui.brackets) {
      for (const corner of ["tl", "tr", "bl", "br"]) {
        const el = document.createElement("div");
        el.className = `nls-corner nls-${corner}`;
        overlay.appendChild(el);
      }
    }
    if (this.ui.scanLine) {
      this._scanline = document.createElement("div");
      this._scanline.className = "nls-scanline";
      overlay.appendChild(this._scanline);
    }
    if (this.ui.statusText) {
      this._statusEl = document.createElement("div");
      this._statusEl.className = "nls-status";
      overlay.appendChild(this._statusEl);
    }
    if (this.ui.flashButton) {
      this._flashBtn = document.createElement("button");
      this._flashBtn.className = "nls-flash";
      this._flashBtn.type = "button";
      this._flashBtn.innerHTML =
        '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">' +
        '<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/></svg>';
      this._flashBtn.title = "Toggle flash";
      this._flashBtn.setAttribute("aria-pressed", "false");
      this._flashBtn.onclick = () => this.setTorch(!this.torchOn).catch(() => {});
      overlay.appendChild(this._flashBtn);
      // Torch capability is only known once the stream is live.
      if (this.torchSupported) this._flashBtn.style.display = "flex";
    }
    parent.appendChild(overlay);
    this._overlay = overlay;
  }

  _unmountOverlay() {
    this._overlay?.remove();
    this._overlay = this._scanline = this._statusEl = this._flashBtn = null;
  }

  _status(message) {
    if (this._statusEl) this._statusEl.textContent = message;
    this.onStatus(message);
  }

  _setAnalyzing(on) {
    if (this._scanline) this._scanline.style.display = on ? "block" : "none";
    if (on) this._status(this.ui.analyzingText);
  }

  // ---------- detection loop ----------

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
    const {
      motionStable, motionCeil, motionRearm, sharpnessMin, stableSamples,
      maxAttempts, textRowsMin, textCrossings, textEdge, debug,
    } = this.options;
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
        this._status("Hold steady over the nutrition table…");
      }
      return;
    }
    // Text-likeness: text lines are rows dense with alternating dark/light
    // strokes. Count gradient sign-flips per row; enough "texty" rows means
    // a label (not a desk, wall, or fabric) is in frame.
    const { luma, w, h } = sample;
    let sharp = 0, n = 0, textRows = 0;
    for (let y = 0; y < h - 1; y++) {
      let crossings = 0, prevSign = 0;
      for (let x = 0; x < w - 1; x++) {
        const i = y * w + x;
        const dx = luma[i + 1] - luma[i];
        sharp += Math.abs(dx) + Math.abs(luma[i] - luma[i + w]);
        n++;
        if (Math.abs(dx) >= textEdge) {
          const sign = dx > 0 ? 1 : -1;
          if (prevSign !== 0 && sign !== prevSign) crossings++;
          prevSign = sign;
        }
      }
      if (crossings >= textCrossings) textRows++;
    }
    const debugSuffix = debug
      ? ` [m ${motion.toFixed(1)}/${stillBar.toFixed(1)} · s ${(sharp / n).toFixed(1)}/${sharpnessMin} · t ${textRows}/${textRowsMin}]`
      : "";
    const say = (msg) => this._status(msg + debugSuffix);

    if (motion >= stillBar) {
      this.stillCount = 0;
      say("Hold the phone still…");
      return;
    }
    if (sharp / n < sharpnessMin) {
      this.stillCount = 0;
      say("Too blurry — move a little closer or improve the light…");
      return;
    }
    if (textRowsMin > 0 && textRows < textRowsMin) {
      this.stillCount = 0;
      say("Point at the nutrition table…");
      return;
    }
    this.stillCount++;
    say("Hold steady…");
    if (this.stillCount >= stableSamples) this._capture();
  }

  async _capture() {
    this.busy = true;
    this.attempts++;
    this.stillCount = 0;
    try {
      let rect = null;
      if (this.options.cropToText) {
        try {
          rect = this._textCropRect();
        } catch {}
      }
      const blob = await this.captureFrame(this.options.captureWidth, rect);
      if (!blob) return;
      this.onCapture(blob); // freeze the UI on the captured still
      this._setAnalyzing(true);
      const result = await this.scanner.scan(blob);
      this._setAnalyzing(false);
      if ((result.entities || []).length > 0) {
        this.onResult(result, blob);
        this.stop();
        return;
      }
      this.armed = false;
      this.onResume(); // show the live feed again for another attempt
      this._status(
        this.attempts >= this.options.maxAttempts
          ? "No nutrition table found — capture manually."
          : "No nutrition table found — aim at the label, then hold steady."
      );
    } catch (err) {
      this._setAnalyzing(false);
      this.armed = false;
      this.onResume();
      this._status("Scan failed — reposition to retry, or capture manually.");
      this.onError(err);
    } finally {
      this.busy = false;
    }
  }
}
