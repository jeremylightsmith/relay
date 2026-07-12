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
}
