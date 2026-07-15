import 'package:flutter/material.dart';

/// Relay's "who holds the baton" palette + Material 3 themes.
///
/// Colors are derived from the design tokens in `assets/css/app.css`
/// (converted oklch → sRGB). Human = blue (primary), AI = violet (secondary).
class RelayTheme {
  RelayTheme._();

  // --- Semantic tokens (light-theme values are the defaults) ---
  static const Color relayHumanLight = Color(
    0xFF3284D0,
  ); // primary · blue  (oklch 0.60 0.14 250)
  static const Color relayHumanDark = Color(
    0xFF3A93E6,
  ); //  primary · blue  (oklch 0.65 0.15 250)
  static const Color relayAILight = Color(
    0xFF795EC9,
  ); //    secondary · violet (oklch 0.56 0.16 292)
  static const Color relayAIDark = Color(
    0xFF9074E9,
  ); //     secondary · violet (oklch 0.64 0.17 292)
  static const Color relayDone = Color(
    0xFF4AB074,
  ); //       done · green  (oklch 0.68 0.13 155)
  static const Color relayBlocked = Color(
    0xFFD58C3B,
  ); //    blocked · amber (oklch 0.70 0.13 65)

  // --- Reject / send-back · CORE-07 in docs/designs/Relay Mobile.dc.html (RLY-88) ---
  // theme.dart had no reject-red; these are the artboard's own oklch values, converted.
  static const Color relayReject = Color(
    0xFFDB6656,
  ); //      reject · red   (oklch 0.65 0.15 30)
  static const Color relayRejectBorder = Color(
    0xFFF9C6BD,
  ); // note field border  (oklch 0.87 0.06 30)
  static const Color relayRejectHint = Color(
    0xFFAC5346,
  ); //   hint text         (oklch 0.55 0.12 30)
  static const Color relayRejectDisabledBg = Color(
    0xFFEBD9D6,
  ); // Send back disabled  (oklch 0.90 0.02 30)
  static const Color relayRejectDisabledFg = Color(
    0xFFC8978F,
  ); // Send back disabled  (oklch 0.72 0.06 30)

  // The mic is drawn but dead until RLY-99 (D4). Ghosted along the artboard's *own*
  // disabled convention — the move it makes for the Send back button (0.65 0.15 30 →
  // 0.9 0.02 30: hold hue, drop chroma, lift lightness) — so it reads as a
  // neutral-violet placeholder rather than an invented grey.
  static const Color micGhostFill = Color(
    0xFFF2F1F8,
  ); //  ← oklch 0.96 0.03 292 (oklch 0.96 0.01 292)
  static const Color micGhostBorder = Color(
    0xFFD7D6DE,
  ); // ← oklch 0.88 0.05 292 (oklch 0.88 0.01 292)
  static const Color micGhostGlyph = Color(
    0xFFAEACBA,
  ); //  ← oklch 0.50 0.14 292 (oklch 0.75 0.02 292)

  /// Convenience aliases used by downstream feature cards (badges, inbox rows).
  static const Color relayHuman = relayHumanLight;
  static const Color relayAI = relayAILight;

  static ThemeData get light => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: relayHumanLight,
      brightness: Brightness.light,
    ).copyWith(primary: relayHumanLight, secondary: relayAILight),
  );

  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: relayHumanDark,
      brightness: Brightness.dark,
    ).copyWith(primary: relayHumanDark, secondary: relayAIDark),
  );
}
