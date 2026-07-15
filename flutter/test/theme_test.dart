import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';

void main() {
  test('light theme: primary is Relay blue, secondary is Relay violet', () {
    final scheme = RelayTheme.light.colorScheme;
    expect(scheme.brightness, Brightness.light);
    expect(scheme.primary, const Color(0xFF3284D0));
    expect(scheme.secondary, const Color(0xFF795EC9));
  });

  test('dark theme: primary is Relay blue, secondary is Relay violet', () {
    final scheme = RelayTheme.dark.colorScheme;
    expect(scheme.brightness, Brightness.dark);
    expect(scheme.primary, const Color(0xFF3A93E6));
    expect(scheme.secondary, const Color(0xFF9074E9));
  });

  test('semantic baton tokens are exposed for downstream cards', () {
    expect(RelayTheme.relayHuman, RelayTheme.relayHumanLight);
    expect(RelayTheme.relayAI, RelayTheme.relayAILight);
    expect(RelayTheme.relayDone, const Color(0xFF4AB074));
    expect(RelayTheme.relayBlocked, const Color(0xFFD58C3B));
  });

  test('CORE-07 reject tokens are the artboard oklch values, converted', () {
    expect(
      RelayTheme.relayReject,
      const Color(0xFFDB6656),
    ); // oklch(0.65 0.15 30)
    expect(
      RelayTheme.relayRejectBorder,
      const Color(0xFFF9C6BD),
    ); // oklch(0.87 0.06 30)
    expect(
      RelayTheme.relayRejectHint,
      const Color(0xFFAC5346),
    ); // oklch(0.55 0.12 30)
    expect(
      RelayTheme.relayRejectDisabledBg,
      const Color(0xFFEBD9D6),
    ); // oklch(0.9 0.02 30)
    expect(
      RelayTheme.relayRejectDisabledFg,
      const Color(0xFFC8978F),
    ); // oklch(0.72 0.06 30)
  });

  test(
    'the inert mic ghosts the artboard violet rather than inventing a grey',
    () {
      expect(
        RelayTheme.micGhostFill,
        const Color(0xFFF2F1F8),
      ); // oklch(0.96 0.01 292)
      expect(
        RelayTheme.micGhostBorder,
        const Color(0xFFD7D6DE),
      ); // oklch(0.88 0.01 292)
      expect(
        RelayTheme.micGhostGlyph,
        const Color(0xFFAEACBA),
      ); // oklch(0.75 0.02 292)

      // Ghosted, not the live violet RLY-99 will restore.
      expect(RelayTheme.micGhostGlyph, isNot(RelayTheme.relayAI));
    },
  );

  test('the NEEDS INPUT pill is the artboard oklch trio, converted', () {
    // INPUT-01's pill (Relay Mobile.dc.html ~line 329) — the same three tokens as the
    // web's #needs-input-panel, so the two surfaces stay recognizably one feature.
    expect(
      RelayTheme.relayNeedsInputText,
      const Color(0xFF935A11),
    ); // oklch(0.52 0.11 65)
    expect(
      RelayTheme.relayNeedsInputBg,
      const Color(0xFFFFF3DF),
    ); // oklch(0.97 0.03 75)
    expect(
      RelayTheme.relayNeedsInputBorder,
      const Color(0xFFF0CEA1),
    ); // oklch(0.87 0.07 75)

    // The lighter pill trio, not the existing needs-you amber it sits beside.
    expect(RelayTheme.relayNeedsInputText, isNot(RelayTheme.relayBlocked));
  });
}
