import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/embedded_webview.dart';

void main() {
  test('embedded webviews cannot pinch-zoom (RE400)', () {
    final settings = embeddedWebViewSettings();

    expect(settings.supportZoom, isFalse);
    expect(settings.builtInZoomControls, isFalse);
    expect(settings.ignoresViewportScaleLimits, isFalse);
  });
}
