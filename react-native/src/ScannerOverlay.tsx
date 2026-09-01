/**
 * Viewfinder overlay: corner brackets, animated scan line + "Analyzing
 * label…" while scanning, status text, and a flash toggle. Render it
 * absolutely over your camera view. Every element is configurable; set
 * `visible={false}` to render nothing.
 */

import React, { useEffect, useRef, useState } from "react";
import { Animated, Pressable, StyleSheet, Text, View } from "react-native";

export interface ScannerOverlayProps {
  /** Master switch — false renders nothing. */
  visible?: boolean;
  /** Corner-bracket framing box. */
  brackets?: boolean;
  /** True while a scan is in flight: shows the animated line + analyzingText. */
  analyzing?: boolean;
  analyzingText?: string;
  /** Guidance line ("Hold steady…") — ignored while analyzing. */
  status?: string;
  /** Flash button (default shown; hide with false). Wire to your camera's torch. */
  showFlash?: boolean;
  flashOn?: boolean;
  onToggleFlash?: () => void;
  /** Override the default bolt glyph with your own icon component. */
  flashIcon?: React.ReactNode;
}

export function ScannerOverlay({
  visible = true,
  brackets = true,
  analyzing = false,
  analyzingText = "Analyzing label…",
  status = "",
  showFlash = true,
  flashOn = false,
  onToggleFlash,
  flashIcon,
}: ScannerOverlayProps) {
  const progress = useRef(new Animated.Value(0)).current;
  const [height, setHeight] = useState(0);

  useEffect(() => {
    if (!analyzing || !height) return;
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(progress, { toValue: 1, duration: 2200, useNativeDriver: true }),
        Animated.timing(progress, { toValue: 0, duration: 2200, useNativeDriver: true }),
      ])
    );
    loop.start();
    return () => loop.stop();
  }, [analyzing, height]);

  if (!visible) return null;

  const translateY = progress.interpolate({
    inputRange: [0, 1],
    outputRange: [height * 0.08, height * 0.9],
  });

  return (
    <View
      style={StyleSheet.absoluteFill}
      pointerEvents="box-none"
      onLayout={(e) => setHeight(e.nativeEvent.layout.height)}
    >
      {brackets && (
        <>
          <View style={[styles.corner, styles.tl]} />
          <View style={[styles.corner, styles.tr]} />
          <View style={[styles.corner, styles.bl]} />
          <View style={[styles.corner, styles.br]} />
        </>
      )}
      {analyzing && height > 0 && (
        <Animated.View style={[styles.scanline, { transform: [{ translateY }] }]} />
      )}
      {(analyzing ? analyzingText : status) ? (
        <Text style={styles.status}>{analyzing ? analyzingText : status}</Text>
      ) : null}
      {showFlash && onToggleFlash && (
        <Pressable
          style={styles.flash}
          onPress={onToggleFlash}
          accessibilityRole="button"
          accessibilityLabel="Toggle flash"
        >
          {flashIcon ?? (
            // \uFE0E forces the monochrome (text) bolt glyph, tinted white.
            <Text style={[styles.flashIcon, flashOn && styles.flashIconOn]}>
              {"\u26A1\uFE0E"}
            </Text>
          )}
        </Pressable>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  corner: {
    position: "absolute",
    width: 34,
    height: 34,
    borderColor: "rgba(255,255,255,0.92)",
    borderRadius: 2,
  },
  tl: { top: "6%", left: "6%", borderTopWidth: 3, borderLeftWidth: 3 },
  tr: { top: "6%", right: "6%", borderTopWidth: 3, borderRightWidth: 3 },
  bl: { bottom: "6%", left: "6%", borderBottomWidth: 3, borderLeftWidth: 3 },
  br: { bottom: "6%", right: "6%", borderBottomWidth: 3, borderRightWidth: 3 },
  scanline: {
    position: "absolute",
    left: "8%",
    right: "8%",
    height: 2,
    backgroundColor: "rgba(255,255,255,0.95)",
    shadowColor: "#fff",
    shadowOpacity: 0.7,
    shadowRadius: 6,
    elevation: 4,
  },
  status: {
    position: "absolute",
    bottom: "4%",
    left: "4%",
    right: "4%",
    textAlign: "center",
    color: "#fff",
    fontSize: 15,
    textShadowColor: "rgba(0,0,0,0.85)",
    textShadowRadius: 4,
  },
  flash: {
    position: "absolute",
    top: 10,
    right: 10,
    width: 42,
    height: 42,
    borderRadius: 21,
    backgroundColor: "#000",
    alignItems: "center",
    justifyContent: "center",
  },
  flashIcon: { color: "#fff", fontSize: 18 },
  flashIconOn: { color: "#FFD60A" },
});
