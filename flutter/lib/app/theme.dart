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
