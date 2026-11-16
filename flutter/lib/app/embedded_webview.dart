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

/// The settings while the card's embedded mockup viewer is open (RE517): native
/// pinch-zoom on, toggled by the `relayViewerZoom` bridge. Android draws no zoom
/// buttons; iOS stays governed by the viewport meta the viewer relaxes (it caps
/// at 4×), so `ignoresViewportScaleLimits` stays false here too.
InAppWebViewSettings viewerZoomWebViewSettings() => InAppWebViewSettings(
  supportZoom: true,
  builtInZoomControls: true,
  displayZoomControls: false,
  ignoresViewportScaleLimits: false,
);
