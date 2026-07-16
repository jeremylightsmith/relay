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

  // INPUT-01's "NEEDS INPUT" pill (RLY-89) — the lighter trio beside relayBlocked's
  // solid amber, and the same values as the web's #needs-input-panel (RLY-71).
  static const Color relayNeedsInputText = Color(
    0xFF935A11,
  ); // needs-input · amber text (oklch 0.52 0.11 65)
  static const Color relayNeedsInputBg = Color(
    0xFFFFF3DF,
  ); //   needs-input · amber bg   (oklch 0.97 0.03 75)
  static const Color relayNeedsInputBorder = Color(
    0xFFF0CEA1,
  ); // needs-input · amber border (oklch 0.87 0.07 75)

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

  // --- Card review bar · CORE-03 in docs/designs/Relay Mobile.dc.html line 188 (RLY-87) ---
  // The Reject label's red and the bar's hairline top border; the artboard's own oklch
  // values, converted. Approve needs no token — the artboard's oklch(0.60 0.14 250) is
  // already relayHumanLight, i.e. colorScheme.primary.
  static const Color relayRejectLabel = Color(
    0xFFA74639,
  ); //  Reject label      (oklch 0.52 0.13 30)
  static const Color relayHairline = Color(
    0xFFE2E5E9,
  ); //  bar top border    (oklch 0.92 0.006 255)

  // The mic, live as of RLY-99 (U5). These are CORE-07's own drawn values —
  // the ghost trio that sat here pre-RLY-99 was these, desaturated.
  static const Color relayMicFill = Color(
    0xFFF2EFFF,
  ); //   mic · violet fill   (oklch 0.96 0.03 292)
  static const Color relayMicBorder = Color(
    0xFFD7D2F7,
  ); // mic · violet border (oklch 0.88 0.05 292)
  static const Color relayMicGlyph = Color(
    0xFF6750AB,
  ); //  mic · violet glyph  (oklch 0.50 0.14 292)

  // --- Voice · Whisper (RLY-99) — the review sheet's provenance line ---
  // A deliberately darker green than relayDone: 9.5px monospace on white needs
  // the contrast. The artboard's own value, converted oklch → sRGB.
  static const Color relayVoiceTranscribed = Color(
    0xFF0B7643,
  ); // transcribed · green (oklch 0.5 0.12 155)

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
