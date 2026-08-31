/**
 * Auto capture for React Native / Expo.
 *
 * RN can't cheaply sample camera frames in JS, so stability is measured with
 * the accelerometer (expo-sensors) instead of frame differencing: when total
 * acceleration variance stays low for `stableMs`, we trigger the camera
 * shutter you provide and scan the photo. Focus is delegated to the OS
 * autofocus, which locks quickly once the phone is still.
 *
 * Peer dependencies: expo-sensors, and a camera that exposes takePictureAsync
 * (expo-camera) — wired in by the app, not imported here.
 */

import { useEffect, useRef, useState } from "react";
import { Accelerometer } from "expo-sensors";
import { NutritionScanner, ScanResult } from "./index";

export interface AutoCaptureOptions {
  scanner: NutritionScanner;
  /** App-provided shutter, e.g. () => cameraRef.current.takePictureAsync({quality: 0.85}) */
  takePicture: () => Promise<{ uri: string }>;
  onResult: (result: ScanResult, uri: string) => void;
  onStatus?: (message: string) => void;
  onError?: (error: Error) => void;
  /** Milliseconds the phone must be still before the shutter fires. */
  stableMs?: number;
  /** Floor (g) of the adaptive jitter threshold for "still". */
  jitterThreshold?: number;
  /** The adaptive jitter threshold never exceeds this (g). */
  jitterCeil?: number;
  /** Jitter above this re-arms after an empty result (deliberate reposition). */
  rearmThreshold?: number;
  settleMs?: number;
  maxAttempts?: number;
}

export function useAutoCapture({
  scanner,
  takePicture,
  onResult,
  onStatus = () => {},
  onError = () => {},
  stableMs = 900,
  jitterThreshold = 0.03,
  jitterCeil = 0.1,
  rearmThreshold = 0.2,
  settleMs = 1000,
  maxAttempts = 6,
}: AutoCaptureOptions) {
  const [active, setActive] = useState(false);
  const state = useRef({
    stillSince: 0,
    armed: true,
    busy: false,
    attempts: 0,
    lastMagnitude: 1,
    jitterHistory: [] as number[],
  });

  useEffect(() => {
    if (!active) return;
    const s = state.current;
    s.stillSince = 0;
    s.armed = true;
    s.busy = false;
    s.attempts = 0;
    onStatus("Point the camera at the nutrition table…");

    const startedAt = Date.now();
    Accelerometer.setUpdateInterval(120);
    const subscription = Accelerometer.addListener(async ({ x, y, z }) => {
      if (s.busy || Date.now() - startedAt < settleMs) return;
      const magnitude = Math.sqrt(x * x + y * y + z * z);
      const jitter = Math.abs(magnitude - s.lastMagnitude);
      s.lastMagnitude = magnitude;

      // Adaptive stillness bar: calibrate to this device's sensor noise.
      s.jitterHistory.push(jitter);
      if (s.jitterHistory.length > 24) s.jitterHistory.shift();
      const noiseFloor = Math.min(...s.jitterHistory);
      const stillBar = Math.min(jitterCeil, Math.max(jitterThreshold, noiseFloor * 1.6));

      if (!s.armed) {
        if (jitter > rearmThreshold && s.attempts < maxAttempts) {
          s.armed = true;
          onStatus("Hold steady over the nutrition table…");
        }
        return;
      }
      if (jitter > stillBar) {
        s.stillSince = 0;
        onStatus("Hold the phone still…");
        return;
      }
      if (s.stillSince === 0) s.stillSince = Date.now();
      if (Date.now() - s.stillSince < stableMs) {
        onStatus("Hold steady…");
        return;
      }

      s.busy = true;
      s.attempts++;
      s.stillSince = 0;
      onStatus("Looks steady — scanning…");
      try {
        const photo = await takePicture();
        const result = await scanner.scanUri(photo.uri);
        if ((result.entities || []).length > 0) {
          setActive(false);
          onResult(result, photo.uri);
          return;
        }
        s.armed = false;
        onStatus(
          s.attempts >= maxAttempts
            ? "No nutrition table found — capture manually."
            : "No nutrition table found — aim at the label, then hold steady."
        );
      } catch (err) {
        s.armed = false;
        onError(err as Error);
      } finally {
        s.busy = false;
      }
    });

    return () => subscription.remove();
  }, [active]);

  return { active, start: () => setActive(true), stop: () => setActive(false) };
}
