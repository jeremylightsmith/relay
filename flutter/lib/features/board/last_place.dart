// RE452: where the user was, so a cold launch can put them back there. One
// remembered place per install — the tab, the Board tab's stage page and a card
// opened from the Board tab — kept in the Keychain beside RLY-95's BoardPrefs and
// cleared with it on sign-out. This file only *records* it; the launch restore
// reads it back through [LastPlaceController.takeLaunchPlace].
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../../app/tabs.dart';
import '../card/card_screen.dart';

/// The one remembered place: [tab], the Board tab's stage page
/// ([stageId]/[stageName]) and a card opened from the Board tab ([cardRef]).
@immutable
class LastPlace {
  const LastPlace({
    required this.tab,
    this.stageId,
    this.stageName,
    this.cardRef,
  });

  final AppTab tab;
  final int? stageId;
  final String? stageName;
  final String? cardRef;

  Map<String, Object?> toJson() => {
    'tab': tab.name,
    'stage_id': stageId,
    'stage_name': stageName,
    'card_ref': cardRef,
  };

  /// Null for anything that is not a map with a known `tab` name — a stored
  /// value from some other build must degrade to "nothing remembered". A
  /// wrong-typed optional field reads as null rather than throwing.
  static LastPlace? fromJson(Object? json) {
    if (json is! Map) return null;
    final tabName = json['tab'];
    final tab = AppTab.values.where((t) => t.name == tabName).firstOrNull;
    if (tab == null) return null;
    T? field<T>(String key) {
      final value = json[key];
      return value is T ? value : null;
    }

    return LastPlace(
      tab: tab,
      stageId: field<int>('stage_id'),
      stageName: field<String>('stage_name'),
      cardRef: field<String>('card_ref'),
    );
  }

  LastPlace _copy({
    AppTab? tab,
    int? Function()? stageId,
    String? Function()? stageName,
    String? Function()? cardRef,
  }) => LastPlace(
    tab: tab ?? this.tab,
    stageId: stageId == null ? this.stageId : stageId(),
    stageName: stageName == null ? this.stageName : stageName(),
    cardRef: cardRef == null ? this.cardRef : cardRef(),
  );

  @override
  bool operator ==(Object other) =>
      other is LastPlace &&
      other.tab == tab &&
      other.stageId == stageId &&
      other.stageName == stageName &&
      other.cardRef == cardRef;

  @override
  int get hashCode => Object.hash(tab, stageId, stageName, cardRef);

  @override
  String toString() => 'LastPlace(${toJson()})';
}

/// The last place, persisted across launches.
abstract class LastPlaceStore {
  /// The stored place, or null when nothing is stored — or the read failed.
  Future<LastPlace?> read();
  Future<void> write(LastPlace place);
  Future<void> clear();
}

/// The iOS Keychain, via flutter_secure_storage — the SecureBoardPrefs pattern,
/// failure posture included: every method swallows platform errors and [read]
/// returns null on failure or undecodable JSON, so a Keychain hiccup degrades to
/// "nothing remembered", never a crash. That also keeps widget tests that do not
/// override [lastPlaceStoreProvider] working: `flutter test` has no platform
/// channel.
class SecureLastPlaceStore implements LastPlaceStore {
  SecureLastPlaceStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'relay_last_place';
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<LastPlace?> read() async {
    try {
      final raw = await _storage.read(key: key, iOptions: _iosOptions);
      return raw == null ? null : LastPlace.fromJson(jsonDecode(raw));
    } catch (e) {
      debugPrint('[last-place] read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(LastPlace place) async {
    try {
      await _storage.write(
        key: key,
        value: jsonEncode(place.toJson()),
        iOptions: _iosOptions,
      );
    } catch (e) {
      debugPrint('[last-place] write failed: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: key, iOptions: _iosOptions);
    } catch (e) {
      debugPrint('[last-place] clear failed: $e');
    }
  }
}

/// Tests.
class InMemoryLastPlaceStore implements LastPlaceStore {
  InMemoryLastPlaceStore([this._place]);

  LastPlace? _place;

  /// The stored place, for assertions.
  LastPlace? get place => _place;

  @override
  Future<LastPlace?> read() async => _place;

  @override
  Future<void> write(LastPlace place) async {
    _place = place;
  }

  @override
  Future<void> clear() async {
    _place = null;
  }
}

final lastPlaceStoreProvider = Provider<LastPlaceStore>(
  (ref) => SecureLastPlaceStore(),
);

/// The remembered place. [restored] is false only until the launch-time
/// Keychain read lands (or the first explicit write/forget).
class LastPlaceState {
  const LastPlaceState({this.place, this.restored = false});

  final LastPlace? place;
  final bool restored;
}

/// Owns the remembered place: the launch read, the one-shot launch snapshot,
/// and every write and forget. The CurrentBoard Notifier shape.
class LastPlaceController extends Notifier<LastPlaceState> {
  Completer<void> _ready = Completer<void>();

  /// Set by any explicit write/forget: one made while the launch read is still
  /// in flight must survive it landing.
  bool _touched = false;

  /// The place read at launch, handed out once by [takeLaunchPlace].
  LastPlace? _launchPlace;

  /// Set by [forget]: a launch read that lands afterwards must not resurrect
  /// the snapshot.
  bool _launchPlaceDropped = false;

  @override
  LastPlaceState build() {
    _ready = Completer<void>();
    _touched = false;
    _launchPlace = null;
    _launchPlaceDropped = false;
    _restore();
    return const LastPlaceState();
  }

  LastPlaceStore get _store => ref.read(lastPlaceStoreProvider);

  /// Completes once the launch read landed, or the first explicit write or
  /// forget, whichever comes first.
  Future<void> get ready => _ready.future;

  Future<void> _restore() async {
    final place = await _store.read();
    if (!ref.mounted) return;
    if (!_launchPlaceDropped) _launchPlace = place;
    if (!_touched) state = LastPlaceState(place: place, restored: true);
    _markReady();
  }

  void _markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// The place read at launch — once. Null on every later call, and null if
  /// [forget] ran first.
  LastPlace? takeLaunchPlace() {
    final place = _launchPlace;
    _launchPlace = null;
    return place;
  }

  Future<void> _set(LastPlace? place) async {
    _touched = true;
    state = LastPlaceState(place: place, restored: true);
    _markReady();
    if (place == null) {
      await _store.clear();
    } else {
      await _store.write(place);
    }
  }

  /// The user is on [tab]. The stage belongs to the Board tab and is kept; the
  /// card is not (they left it).
  Future<void> recordTab(AppTab tab) {
    final current = state.place;
    return _set(
      current == null
          ? LastPlace(tab: tab)
          : current._copy(tab: tab, cardRef: () => null),
    );
  }

  /// A card opened from the Board tab.
  Future<void> recordBoardCard(String cardRef) {
    final current = state.place;
    return _set(
      current == null
          ? LastPlace(tab: AppTab.board, cardRef: cardRef)
          : current._copy(tab: AppTab.board, cardRef: () => cardRef),
    );
  }

  /// The Board tab's pager settled on a stage page.
  Future<void> recordStage(int stageId, String stageName) {
    final current = state.place;
    return _set(
      current == null
          ? LastPlace(tab: AppTab.board, stageId: stageId, stageName: stageName)
          : current._copy(stageId: () => stageId, stageName: () => stageName),
    );
  }

  /// Drop the remembered card, keep the rest.
  Future<void> forgetCard() {
    final current = state.place;
    if (current == null) return _set(null);
    return _set(current._copy(cardRef: () => null));
  }

  /// Drop the Board tab's stage and card (a board switch); keep the tab.
  Future<void> forgetBoardPosition() {
    final current = state.place;
    if (current == null) return _set(null);
    return _set(
      current._copy(
        stageId: () => null,
        stageName: () => null,
        cardRef: () => null,
      ),
    );
  }

  /// Forget everything, the launch snapshot included (sign-out, dead session).
  Future<void> forget() {
    _launchPlace = null;
    _launchPlaceDropped = true;
    return _set(null);
  }
}

final lastPlaceProvider = NotifierProvider<LastPlaceController, LastPlaceState>(
  LastPlaceController.new,
);

/// Turns router locations into last-place writes. Only the tab roots and a card
/// opened from the Board tab are remembered; everything else (a card from Needs
/// you or a push, the reject note, Choose a board, the auth scaffolding) is not.
class LastPlaceTracker {
  LastPlaceTracker(this._controller);

  final LastPlaceController _controller;

  /// The last location that produced a write — the same one again is a no-op.
  Uri? _lastApplied;

  static final _cardPath = RegExp(r'^/cards/([^/]+)$');

  void onLocation(Uri uri) {
    if (uri == _lastApplied) return;

    final tab = AppTab.fromPath(uri.path);
    if (tab != null) {
      _lastApplied = uri;
      unawaited(_controller.recordTab(tab));
      return;
    }

    final card = _cardPath.firstMatch(uri.path);
    if (card != null &&
        uri.queryParameters['back'] == CardScreen.backFromBoard) {
      _lastApplied = uri;
      unawaited(_controller.recordBoardCard(card.group(1)!));
    }
  }

  /// The location actually on screen. A `push` (how a card opens from the
  /// Board tab) leaves [RouteMatchList.uri] on the base route — go_router
  /// only reflects imperative routes in the uri under
  /// `optionURLReflectsImperativeAPIs` — so a pushed top match reports its own
  /// uri instead. Also BoardScreen's "is the board on screen" check.
  static Uri topLocation(RouteMatchList config) {
    final top = config.lastOrNull;
    return top is ImperativeRouteMatch ? top.matches.uri : config.uri;
  }

  /// Track [router]'s location from its delegate — after navigation, never
  /// from inside the redirect. Writing a Notifier mid-build trips Riverpod's
  /// "modified a provider while the tree was building" guard, and the delegate
  /// itself notifies mid-build on the Router's first mount
  /// (`setInitialRoutePath`), so the location is captured now and applied in a
  /// microtask, after the frame. Returns the detach callback, for the owner's
  /// dispose.
  static VoidCallback attach(GoRouter router, LastPlaceController controller) {
    final tracker = LastPlaceTracker(controller);
    final delegate = router.routerDelegate;
    var attached = true;
    void listener() {
      final uri = topLocation(delegate.currentConfiguration);
      scheduleMicrotask(() {
        if (attached) tracker.onLocation(uri);
      });
    }

    delegate.addListener(listener);
    return () {
      attached = false;
      delegate.removeListener(listener);
    };
  }
}
