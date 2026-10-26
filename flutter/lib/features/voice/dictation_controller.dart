import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dictation_text_controller.dart';
import 'insert_transcript.dart';
import 'voice_engines.dart';
import 'voice_transcriber.dart';

/// idle → (priming) → (downloading) → listening → (transcribing) → idle, with
/// error reachable from the permission check, a failed start and an empty
/// Whisper transcript (RE467).
enum DictationStage {
  idle,
  priming,
  downloading,
  listening,
  transcribing,
  error,
}

/// The dictation state machine (RE467): pure Dart over [VoiceEngines] and the
/// field's [DictationTextController], no widgets. It picks the engine, runs
/// the timer, and writes words into the field at the cursor — Apple's live
/// drafts as a faded span that is replaced in place until final, Whisper's
/// transcript after stop.
class DictationController extends ChangeNotifier {
  DictationController(
    this._engines, {
    required DictationTextController field,
    // Private named parameters: callers pass `onInserted:`, `tick:`, …
    this._onInserted,
    this._tick = const Duration(seconds: 1),
    this._finalizeTimeout = const Duration(seconds: 2),
    this._debugBuild = kDebugMode,
  }) : _field = field,
       _lastText = field.text {
    _field.addListener(_onFieldChanged);
  }

  /// The one definition of "the mic is red".
  static const Set<DictationStage> activeStages = {
    DictationStage.listening,
    DictationStage.downloading,
    DictationStage.transcribing,
  };

  final VoiceEngines _engines;
  final DictationTextController _field;
  final ValueChanged<String>? _onInserted;
  final Duration _tick;
  final Duration _finalizeTimeout;
  final bool _debugBuild;

  DictationStage stage = DictationStage.idle;

  /// Time spent listening in this dictation; resets on an engine switch.
  Duration elapsed = Duration.zero;

  /// `0.0–1.0` while the Apple model asset downloads.
  double downloadProgress = 0;

  /// The engine running *this* dictation.
  VoiceEngine activeEngine = VoiceEngine.apple;

  /// The debug/TestFlight Apple/Whisper pull-down.
  bool showEngineSwitch = false;

  String? errorMessage;
  bool showOpenSettings = false;
  bool showTryAgain = false;

  bool get isActive => activeStages.contains(stage);

  Timer? _timer;
  StreamSubscription<LiveResult>? _results;
  StreamSubscription<double>? _download;
  bool _disposed = false;

  /// True while an Apple stop is finalizing or a Whisper recording is being
  /// cancelled for an engine switch, so a stop in that window is a no-op.
  bool _finalizing = false;

  // --- The live draft span, in field coordinates ---

  /// The volatile chunk Apple is still revising; null when all words are ink.
  TextRange? _span;

  /// Set when the user edited inside the span: every result up to and
  /// including the next final is dropped, so those words never duplicate.
  bool _frozen = false;

  /// Set around every write this controller makes to [_field], so
  /// [_onFieldChanged] only sees the user's edits.
  bool _writing = false;
  String _lastText;

  // --- Actions ---

  /// The mic tap.
  Future<void> toggle() async {
    switch (stage) {
      case DictationStage.idle:
      case DictationStage.error:
      case DictationStage.priming:
        await start();
      case DictationStage.listening:
        await stop();
      case DictationStage.downloading:
        keepTyping();
      case DictationStage.transcribing:
        break;
    }
  }

  Future<void> start() async {
    _clearError();
    final permission = await _engines.whisper.permissionStatus();
    if (_disposed) return;
    switch (permission) {
      case MicPermission.granted:
        await _selectEngine();
      case MicPermission.notDetermined:
        _set(DictationStage.priming);
      case MicPermission.denied:
        errorMessage = 'Microphone access is off for Hamaca.';
        showOpenSettings = true;
        showTryAgain = false;
        _set(DictationStage.error);
    }
  }

  /// From priming: spend the one-shot OS prompt. Denial goes idle — the field
  /// stays focused for typing; no nag.
  Future<void> allowMic() async {
    final permission = await _engines.whisper.requestPermission();
    if (_disposed) return;
    if (permission == MicPermission.granted) {
      await _selectEngine();
    } else {
      _set(DictationStage.idle);
    }
  }

  Future<void> stop() async {
    if (stage != DictationStage.listening || _finalizing) return;
    if (activeEngine == VoiceEngine.apple) {
      await _finishApple();
      _set(DictationStage.idle);
    } else {
      await _stopWhisper();
    }
  }

  /// Not now, or the old "Type instead". A running dictation is ended with
  /// [stop] or [keepTyping], never dismissed.
  void dismiss() {
    if (isActive) return;
    _clearError();
    _set(DictationStage.idle);
  }

  Future<void> tryAgain() => start();

  Future<void> openSettings() => _engines.whisper.openSettings();

  /// From downloading: record this dictation on Whisper. The stored engine
  /// preference is unchanged.
  Future<void> useWhisperNow() async {
    if (stage != DictationStage.downloading) return;
    _cancelDownload();
    await _beginWhisper();
  }

  /// From downloading: stop waiting and go back to the keyboard.
  void keepTyping() {
    if (stage != DictationStage.downloading) return;
    _cancelDownload();
    _set(DictationStage.idle);
  }

  /// The debug/TestFlight pull-down: stores [engine], and mid-dictation moves
  /// this dictation onto it.
  Future<void> chooseEngine(VoiceEngine engine) async {
    await _engines.settings.setEnginePreference(engine);
    if (_disposed ||
        stage != DictationStage.listening ||
        _finalizing ||
        engine == activeEngine) {
      return;
    }
    if (activeEngine == VoiceEngine.apple) {
      await _finishApple();
      if (_disposed) return;
      await _beginWhisper();
    } else {
      _stopTimer();
      elapsed = Duration.zero;
      _finalizing = true;
      try {
        await _engines.whisper.cancelRecording();
      } finally {
        _finalizing = false;
      }
      if (_disposed) return;
      await _beginAppleFrom(await _engines.apple.liveSupport());
    }
  }

  // --- Engine selection ---

  Future<void> _selectEngine() async {
    final support = await _engines.apple.liveSupport();
    final canCompare = _debugBuild || await _engines.settings.isTestFlight();
    showEngineSwitch = canCompare && support != LiveSupport.unsupported;
    final preferred = showEngineSwitch
        ? await _engines.settings.enginePreference()
        : VoiceEngine.apple;
    if (_disposed) return;
    if (preferred == VoiceEngine.whisper) {
      await _beginWhisper();
    } else {
      await _beginAppleFrom(support);
    }
  }

  /// The Apple path from the support check: unsupported or Speech denied fall
  /// back to Whisper silently.
  Future<void> _beginAppleFrom(LiveSupport support) async {
    if (support == LiveSupport.unsupported ||
        !await _engines.apple.requestSpeechAuthorization()) {
      if (!_disposed) await _beginWhisper();
      return;
    }
    if (_disposed) return;
    if (support == LiveSupport.ready) {
      await _beginApple();
    } else {
      _beginDownload();
    }
  }

  void _beginDownload() {
    activeEngine = VoiceEngine.apple;
    downloadProgress = 0;
    _set(DictationStage.downloading);
    _download = _engines.apple.downloadAsset().listen(
      (fraction) {
        downloadProgress = fraction;
        _notify();
      },
      onError: (Object _) {
        _download = null;
        if (stage == DictationStage.downloading) unawaited(_beginWhisper());
      },
      onDone: () {
        _download = null;
        if (stage == DictationStage.downloading) unawaited(_beginApple());
      },
      cancelOnError: true,
    );
  }

  void _cancelDownload() {
    unawaited(_download?.cancel());
    _download = null;
  }

  // --- Apple (live) ---

  Future<void> _beginApple() async {
    activeEngine = VoiceEngine.apple;
    _span = null;
    _frozen = false;
    _results = _engines.apple.results.listen(_onResult);
    _claimInterruptions();
    try {
      await _engines.apple.startLive();
    } on Object {
      _cancelResults();
      if (!_disposed) _fail(VoiceErrorKind.recordingFailed);
      return;
    }
    if (_disposed) {
      unawaited(_engines.apple.cancelLive());
      return;
    }
    _startTimer();
    _set(DictationStage.listening);
  }

  /// Finalizes Apple — results emitted before `stopLive` resolves (or
  /// [_finalizeTimeout] passes) are applied — then settles any leftover draft
  /// as ink and stops listening for results.
  Future<void> _finishApple() async {
    _finalizing = true;
    _stopTimer();
    try {
      await _engines.apple.stopLive().timeout(_finalizeTimeout);
    } on Object {
      // A hung or failed finalize keeps whatever words already landed.
    }
    _finalizing = false;
    _cancelResults();
    if (_disposed) return;
    _span = null;
    _frozen = false;
    _field.draft = null;
  }

  void _cancelResults() {
    unawaited(_results?.cancel());
    _results = null;
  }

  void _onResult(LiveResult result) {
    if (_disposed) return;
    if (_frozen) {
      if (result.isFinal) _frozen = false;
      return;
    }
    final text = _field.text;
    final selection = _field.selection.isValid
        ? _field.selection
        : TextSelection.collapsed(offset: text.length);
    final span =
        _span ?? TextRange.collapsed(math.min(selection.end, text.length));

    final inserted = insertTranscript(
      span.textBefore(text) + span.textAfter(text),
      span.start,
      result.text,
    );
    final delta = inserted.text.length - text.length;
    int map(int offset) {
      final mapped = offset >= span.end
          ? offset + delta
          : offset <= span.start
          ? offset
          : inserted.range.end;
      return mapped.clamp(0, inserted.text.length);
    }

    final caretAtSpanEnd =
        selection.isCollapsed && selection.extentOffset == span.end;
    _write(
      TextEditingValue(
        text: inserted.text,
        selection: caretAtSpanEnd
            ? TextSelection.collapsed(offset: inserted.range.end)
            : TextSelection(
                baseOffset: map(selection.baseOffset),
                extentOffset: map(selection.extentOffset),
              ),
      ),
    );
    _span = result.isFinal ? null : inserted.range;
    _field.draft = _span;
    _onInserted?.call(_field.text);
  }

  /// Keeps [_span] pointing at the same words while the user types around it;
  /// an edit that overlaps the span freezes it as ink.
  void _onFieldChanged() {
    final before = _lastText;
    final after = _field.text;
    _lastText = after;
    final span = _span;
    if (_writing || before == after || span == null) return;

    final shortest = math.min(before.length, after.length);
    var prefix = 0;
    while (prefix < shortest &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shortest - prefix &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    final editStart = prefix;
    final editEnd = before.length - suffix;

    if (editEnd <= span.start) {
      final delta = after.length - before.length;
      _span = TextRange(start: span.start + delta, end: span.end + delta);
      _field.draft = _span;
    } else if (editStart < span.end) {
      _span = null;
      _frozen = true;
      _field.draft = null;
    }
  }

  // --- Whisper (batch) ---

  Future<void> _beginWhisper() async {
    activeEngine = VoiceEngine.whisper;
    _claimInterruptions();
    try {
      await _engines.whisper.startRecording();
    } on Object {
      if (!_disposed) _fail(VoiceErrorKind.recordingFailed);
      return;
    }
    if (_disposed) {
      unawaited(_engines.whisper.cancelRecording());
      return;
    }
    _startTimer();
    _set(DictationStage.listening);
  }

  Future<void> _stopWhisper() async {
    _stopTimer();
    _set(DictationStage.transcribing);
    try {
      final transcript = (await _engines.whisper.stopAndTranscribe()).trim();
      // Cancelled (disposed) mid-flight: a late result is discarded.
      if (_disposed || stage != DictationStage.transcribing) return;
      if (transcript.isEmpty) {
        _fail(VoiceErrorKind.transcriptionFailed);
        return;
      }
      final text = _field.text;
      final cursor = _field.selection.isValid
          ? math.min(_field.selection.end, text.length)
          : text.length;
      final inserted = insertTranscript(text, cursor, transcript);
      _write(
        TextEditingValue(
          text: inserted.text,
          selection: TextSelection.collapsed(offset: inserted.range.end),
        ),
      );
      _onInserted?.call(_field.text);
      _set(DictationStage.idle);
    } on VoiceError catch (e) {
      if (!_disposed && stage == DictationStage.transcribing) _fail(e.kind);
    } on Object {
      if (!_disposed && stage == DictationStage.transcribing) {
        _fail(VoiceErrorKind.transcriptionFailed);
      }
    }
  }

  // --- Shared ---

  /// The engines hold one interruption handler each, so it is claimed when
  /// this controller starts recording rather than when it is built: with
  /// several hosts mounted, the one dictating is the one that hears it.
  void _claimInterruptions() {
    _engines.whisper.onInterrupted(_handleInterruption);
    _engines.apple.onInterrupted(_handleInterruption);
  }

  /// A phone call or route change: treated exactly like a Stop tap.
  void _handleInterruption() {
    if (!_disposed && stage == DictationStage.listening) unawaited(stop());
  }

  void _write(TextEditingValue value) {
    _writing = true;
    try {
      _field.value = value;
    } finally {
      _writing = false;
    }
  }

  void _startTimer() {
    _stopTimer();
    elapsed = Duration.zero;
    _timer = Timer.periodic(_tick, (_) {
      elapsed += _tick;
      _notify();
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _fail(VoiceErrorKind kind) {
    errorMessage = switch (kind) {
      VoiceErrorKind.modelUnavailable => "Voice isn't available right now.",
      _ => "Didn't catch that.",
    };
    showOpenSettings = false;
    showTryAgain = true;
    _set(DictationStage.error);
  }

  void _clearError() {
    errorMessage = null;
    showOpenSettings = false;
    showTryAgain = false;
  }

  void _set(DictationStage next) {
    stage = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Tears down whatever is running. Never touches the field's text.
  @override
  void dispose() {
    _disposed = true;
    _stopTimer();
    _cancelResults();
    _cancelDownload();
    _field.removeListener(_onFieldChanged);
    switch (stage) {
      case DictationStage.listening when activeEngine == VoiceEngine.whisper:
        unawaited(_engines.whisper.cancelRecording());
      case DictationStage.listening:
        unawaited(_engines.apple.cancelLive());
      case DictationStage.transcribing:
        unawaited(_engines.whisper.cancelTranscription());
      default:
        break;
    }
    super.dispose();
  }
}
