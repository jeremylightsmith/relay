import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';

/// The card screen's mount fetch (RLY-98): the light card summary off
/// `GET /api/all/cards/:ref`, reduced to the one fact the native chrome needs today —
/// a launchable PR URL, or null. RLY-91's spec sheet extends this same source.
///
/// Null covers every "no chip" case in one value: fetch/auth failure, missing or empty
/// `pr_url`, and a value that isn't an absolute http(s) URL (both launch modes only
/// accept web URLs). Supplemental context must never block the primary action, so
/// failures degrade to "no chip" — no error UI.
///
/// Keyed by (cardRef, boardSlug) — the same pair that keys the webview body — so a
/// queue advance fetches the new card's summary, and `?board=` disambiguates
/// non-unique refs the same way every other /api/all call does.
final cardPrUrlProvider = FutureProvider.autoDispose
    .family<Uri?, ({String cardRef, String boardSlug})>((ref, key) async {
      final client = ref.watch(apiClientProvider);
      try {
        final body = await client.getJson(
          '/api/all/cards/${key.cardRef}?board=${key.boardSlug}',
        );
        final data = (body as Map)['data'];
        final raw = data is Map ? data['pr_url'] : null;
        if (raw is! String || raw.isEmpty) return null;
        final uri = Uri.tryParse(raw);
        if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
          return null;
        }
        return uri;
      } on ApiException {
        return null;
      }
    });
