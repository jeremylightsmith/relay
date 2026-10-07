import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// The one shared settings object for every embedded LiveView page (RE400): no
/// pinch-zoom. The page also pins its viewport (`maximum-scale=1`), but WKWebView
/// ignores viewport limits unless `ignoresViewportScaleLimits` stays false, and
/// Android only honors it with zoom support off.
InAppWebViewSettings embeddedWebViewSettings() => InAppWebViewSettings(
  supportZoom: false,
  builtInZoomControls: false,
  ignoresViewportScaleLimits: false,
);
