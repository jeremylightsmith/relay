import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'voice_controller.dart';
import 'voice_transcriber.dart';
import 'whisper_kit_transcriber.dart';

// Review-state chrome from the "Voice · Whisper" artboard (badged CORE-04 —
// the badge is off by one; the title is the identity, spec D5), oklch → sRGB.
const _transcriptBorder = Color(0xFFD1CEE4); // oklch(0.86 0.03 292)
const _transcriptText = Color(0xFF222933); // oklch(0.28 0.02 255)
const _headingText = Color(0xFF1E252E); // oklch(0.26 0.02 255)
const _cancelBg = Color(0xFFEFF2F6); // oklch(0.96 0.006 255)
const _cancelBorder = Color(0xFFE2E5E9); // oklch(0.92 0.006 255)
const _cancelText = Color(0xFF464E58); // oklch(0.42 0.02 255)

/// The whole public surface of RLY-99 (spec U4): records, transcribes
/// on-device, and returns the (possibly hand-edited) transcript — or null on
/// cancel. It never touches a field, an API, or a card itself (D6).
Future<String?> showVoiceSheet(
  BuildContext context, {
  VoiceTranscriber? transcriber,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // Stop and Cancel are the only exits (D8) — a stray swipe must not
    // half-dismiss a sheet holding a live mic.
    isDismissible: false,
    enableDrag: false,
    builder: (_) =>
        VoiceSheet(transcriber: transcriber ?? WhisperKitTranscriber()),
  );
}

class VoiceSheet extends StatefulWidget {
  const VoiceSheet({super.key, required this.transcriber});

  final VoiceTranscriber transcriber;

  @override
  State<VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<VoiceSheet> {
  late final VoiceController _controller;
  final _transcriptField = TextEditingController();
  bool _seeded = false;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _controller = VoiceController(widget.transcriber);
    _controller.addListener(_onControllerChanged);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _transcriptField.dispose();
    super.dispose();
  }

  /// The controller's `dismissed` is the single null-exit: every Cancel /
  /// Not now / Type instead / denied path funnels through it, so the sheet
  /// pops exactly once.
  void _onControllerChanged() {
    if (_controller.stage == VoiceStage.review && !_seeded) {
      _transcriptField.text = _controller.transcript;
      _seeded = true;
    }
    if (_controller.stage == VoiceStage.dismissed && !_popped) {
      _popped = true;
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  void _useThis() {
    if (_popped) return;
    _popped = true;
    final text = _transcriptField.text.trim();
    Navigator.of(context).pop(text.isEmpty ? null : text);
  }

  void _tryAgain() {
    _seeded = false;
    _controller.tryAgain();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // The review TextField must clear the keyboard (isScrollControlled).
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Container(
          key: const Key('voice_sheet'),
          width: double.infinity,
          // Artboard: padding 20px 18px 22px; radius 22px top.
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 22),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: switch (_controller.stage) {
            VoiceStage.starting || VoiceStage.dismissed => const SizedBox(
              height: 96,
              key: Key('voice_starting'),
            ),
            VoiceStage.priming => _Priming(
              onAllow: _controller.allowMic,
              onNotNow: _controller.cancel,
            ),
            VoiceStage.recording => _Recording(
              elapsed: _controller.elapsed,
              onStop: _controller.stopAndReview,
              onCancel: _controller.cancel,
            ),
            VoiceStage.transcribing => _Transcribing(
              onCancel: _controller.cancel,
            ),
            VoiceStage.review => _Review(
              field: _transcriptField,
              onCancel: _controller.cancel,
              onUse: _useThis,
            ),
            VoiceStage.error => _ErrorState(
              message: _controller.errorMessage ?? "Didn't catch that.",
              showOpenSettings: _controller.showOpenSettings,
              showTryAgain: _controller.showTryAgain,
              onOpenSettings: _controller.openSettings,
              onTryAgain: _tryAgain,
              onTypeInstead: _controller.cancel,
            ),
          },
        ),
      ),
    );
  }
}

/// The artboard's mic mark: a violet circle holding a white rounded bar.
/// 34px in the review header; scaled up elsewhere.
class _MicBadge extends StatelessWidget {
  const _MicBadge({this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: RelayTheme.relayAI,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Container(
        width: size * 8 / 34,
        height: size * 13 / 34,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(size * 4 / 34),
        ),
      ),
    );
  }
}

/// Why-we-need-the-mic, before the OS dialog — mirrors AUTH-03 /
/// PushPermissionScreen (spec D4 state 1).
class _Priming extends StatelessWidget {
  const _Priming({required this.onAllow, required this.onNotNow});

  final VoidCallback onAllow;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('voice_priming'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: RelayTheme.relayAI.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            alignment: Alignment.center,
            child: const _MicBadge(),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Dictate instead of typing',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: _headingText,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Relay listens only while this sheet is open and transcribes on '
          'your phone — audio never leaves it.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        FilledButton(
          key: const Key('voice_allow_mic'),
          onPressed: onAllow,
          style: _primaryStyle,
          child: const Text('Allow microphone'),
        ),
        const SizedBox(height: 6),
        TextButton(
          key: const Key('voice_not_now'),
          onPressed: onNotNow,
          child: const Text('Not now'),
        ),
      ],
    );
  }
}

/// Violet pulsing mic + live elapsed timer, counting up with no cap (D8).
/// Stop is the only exit besides Cancel, so it is the full-width primary.
class _Recording extends StatefulWidget {
  const _Recording({
    required this.elapsed,
    required this.onStop,
    required this.onCancel,
  });

  final Duration elapsed;
  final VoidCallback onStop;
  final VoidCallback onCancel;

  @override
  State<_Recording> createState() => _RecordingState();
}

class _RecordingState extends State<_Recording>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String get _timer {
    final m = widget.elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (widget.elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('voice_recording'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: ScaleTransition(
            scale: Tween(
              begin: 1.0,
              end: 1.12,
            ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
            child: const _MicBadge(size: 64),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Listening',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _headingText,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _timer,
          key: const Key('voice_timer'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            fontFamily: 'monospace',
            color: _cancelText,
          ),
        ),
        const SizedBox(height: 18),
        FilledButton(
          key: const Key('voice_stop'),
          onPressed: widget.onStop,
          style: _primaryStyle,
          child: const Text('Stop'),
        ),
        const SizedBox(height: 6),
        TextButton(
          key: const Key('voice_cancel'),
          onPressed: widget.onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Violet indeterminate progress, cancellable — an uncapped clip means an
/// unbounded wait, and the human must be able to walk away (D8).
class _Transcribing extends StatelessWidget {
  const _Transcribing({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('voice_transcribing'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              color: RelayTheme.relayAI,
              strokeWidth: 3,
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Transcribing…',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _headingText,
          ),
        ),
        const SizedBox(height: 14),
        TextButton(
          key: const Key('voice_cancel'),
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The one drawn state — matches the "Voice · Whisper" artboard exactly.
class _Review extends StatelessWidget {
  const _Review({
    required this.field,
    required this.onCancel,
    required this.onUse,
  });

  final TextEditingController field;
  final VoidCallback onCancel;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('voice_review'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const _MicBadge(),
            const SizedBox(width: 9),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'You said',
                  key: Key('voice_you_said'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _headingText,
                  ),
                ),
                Text(
                  'TRANSCRIBED · WHISPER · TAP TO EDIT',
                  key: Key('voice_provenance'),
                  style: TextStyle(
                    fontSize: 9.5,
                    fontFamily: 'monospace',
                    color: RelayTheme.relayVoiceTranscribed,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          key: const Key('voice_transcript_box'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _transcriptBorder, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            key: const Key('voice_transcript'),
            controller: field,
            maxLines: null,
            cursorColor: RelayTheme.relayAI,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: _transcriptText,
            ),
            decoration: const InputDecoration.collapsed(hintText: ''),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              flex: 10, // artboard flex:1 (ints only — 10:13 ≡ 1:1.3)
              child: FilledButton(
                key: const Key('voice_review_cancel'),
                onPressed: onCancel,
                style: FilledButton.styleFrom(
                  backgroundColor: _cancelBg,
                  foregroundColor: _cancelText,
                  side: const BorderSide(color: _cancelBorder),
                  padding: const EdgeInsets.all(12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              flex: 13, // artboard flex:1.3
              child: FilledButton(
                key: const Key('voice_use'),
                onPressed: onUse,
                // Blue, not violet: the AI transcribed, but the human is the
                // one acting (spec — "that is not an artboard slip").
                style: FilledButton.styleFrom(
                  backgroundColor: RelayTheme.relayHuman,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Use this'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One line of plain cause + Try again / Open Settings, and always a
/// Type instead escape hatch (spec D4 state 4).
class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.showOpenSettings,
    required this.showTryAgain,
    required this.onOpenSettings,
    required this.onTryAgain,
    required this.onTypeInstead,
  });

  final String message;
  final bool showOpenSettings;
  final bool showTryAgain;
  final VoidCallback onOpenSettings;
  final VoidCallback onTryAgain;
  final VoidCallback onTypeInstead;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('voice_error'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          message,
          key: const Key('voice_error_message'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: _headingText,
          ),
        ),
        const SizedBox(height: 16),
        if (showTryAgain)
          FilledButton(
            key: const Key('voice_try_again'),
            onPressed: onTryAgain,
            style: _primaryStyle,
            child: const Text('Try again'),
          ),
        if (showOpenSettings)
          FilledButton(
            key: const Key('voice_open_settings'),
            onPressed: onOpenSettings,
            style: _primaryStyle,
            child: const Text('Open Settings'),
          ),
        const SizedBox(height: 6),
        TextButton(
          key: const Key('voice_type_instead'),
          onPressed: onTypeInstead,
          child: const Text('Type instead'),
        ),
      ],
    );
  }
}

/// The blue primary CTA all designed states share — the human is acting.
final _primaryStyle = FilledButton.styleFrom(
  backgroundColor: RelayTheme.relayHuman,
  foregroundColor: Colors.white,
  minimumSize: const Size.fromHeight(48),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
);
