/**
 * Nutrition Scanner — React Native / Expo SDK.
 *
 * Manual capture:
 *   const scanner = new NutritionScanner({ apiKey: "nls_..." });
 *   const result = await scanner.scanUri(photo.uri);
 *
 * Auto capture: see useAutoCapture.ts (accelerometer-gated shutter).
 */

export const DEFAULT_BASE_URL =
  "https://nutrition-scanner-api-riiqvjsmkq-uc.a.run.app";

export interface Nutriment {
  text: string;
  score: number;
  value?: number;
  unit?: string | null;
}

export interface ScanResult {
  entities: { label: string; text: string; score: number }[];
  nutriments: Record<string, Nutriment>;
  words_detected: number;
  /** True when served from the server-side result cache (an identical label
   *  was scanned before). Values match a fresh scan; latency ~1 s. */
  cached?: boolean;
}

export class ScanError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "ScanError";
  }
}

export interface ScannerOptions {
  apiKey?: string;
  /** Alternative to apiKey: returns a Firebase ID token of a verified user. */
  getToken?: () => Promise<string>;
  baseUrl?: string;
  timeoutMs?: number;
}

export class NutritionScanner {
  private apiKey?: string;
  private getToken?: () => Promise<string>;
  private baseUrl: string;
  private timeoutMs: number;

  constructor({ apiKey, getToken, baseUrl = DEFAULT_BASE_URL, timeoutMs = 60_000 }: ScannerOptions) {
    if (!apiKey && !getToken) throw new Error("Provide apiKey or getToken.");
    this.apiKey = apiKey;
    this.getToken = getToken;
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.timeoutMs = timeoutMs;
  }

  private async headers(): Promise<Record<string, string>> {
    if (this.apiKey) return { "X-API-Key": this.apiKey };
    return { Authorization: `Bearer ${await this.getToken!()}` };
  }

  /**
   * Scan a local image by URI (from expo-camera / expo-image-picker).
   * Tip: re-encode with expo-image-manipulator to JPEG width ≤2000 first —
   * it bakes EXIF rotation into pixels and shrinks the upload.
   */
  async scanUri(uri: string, mimeType = "image/jpeg"): Promise<ScanResult> {
    const form = new FormData();
    // React Native's FormData accepts {uri, name, type} file descriptors.
    form.append("image", { uri, name: "label.jpg", type: mimeType } as any);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await fetch(`${this.baseUrl}/extract`, {
        method: "POST",
        headers: await this.headers(),
        body: form,
        signal: controller.signal,
      });
      if (!response.ok) {
        const detail = (await response.json().catch(() => ({} as any))).detail;
        throw new ScanError(response.status, detail || `HTTP ${response.status}`);
      }
      return (await response.json()) as ScanResult;
    } finally {
      clearTimeout(timer);
    }
  }
}
