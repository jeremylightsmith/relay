import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'dictation_controller.dart';
import 'voice_transcriber.dart';

/// The slim bar pinned above the keyboard while dictating (RE467, card mockup
/// "Dictate into the field — keyboard stays open, red stop on a keyboard
/// toolbar"). One frame for every non-idle [DictationStage]: listening
/// (waveform · timer · engine label · red stop), transcribing, downloading,
/// priming and error. Wrapped in a [TextFieldTapRegion] so a tap on it never
/// counts as a tap outside the field — the keyboard stays up.
class DictationToolbar extends StatelessWidget {
  const DictationToolbar({super.key, required this.controller});

  final DictationController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final stage = controller.stage;
        final compact =
            stage == DictationStage.listening ||
            stage == DictationStage.transcribing;
        return TextFieldTapRegion(
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              key: const Key('dictation_toolbar'),
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: compact ? 6 : 8,
              ),
              decoration: const BoxDecoration(
                color: RelayTheme.relayDictationToolbarBg,
                border: Border(
                  top: BorderSide(color: RelayTheme.relayHairline),
                ),
              ),
              child: switch (stage) {
                DictationStage.listening => _Listening(controller),
                DictationStage.transcribing => const _Transcribing(),
                DictationStage.downloading => _Downloading(controller),
                DictationStage.priming => _Priming(controller),
                DictationStage.error => _Error(controller),
                DictationStage.idle => const SizedBox.shrink(),
              },
            ),
          ),
        );
      },
    );
  }
}

/// `m:ss` — minutes are not zero-padded (`0:14`, `12:03`).
String _clock(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

Color _ink(BuildContext context, double alpha) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: alpha);

const _title = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);

/// The mockup's 18px progress ring (`radial-progress --size:18px`).
Widget _ring(BuildContext context, {Key? key, double? value}) => SizedBox(
  width: 18,
  height: 18,
  child: CircularProgressIndicator(
    key: key,
    value: value,
    strokeWidth: 2.5,
    color: Theme.of(context).colorScheme.primary,
  ),
);

class _Listening extends StatelessWidget {
  const _Listening(this.controller);

  final DictationController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: const Key('dictation_listening'),
      children: [
        _Waveform(phase: controller.elapsed.inSeconds),
        const SizedBox(width: 12),
        Text(
          _clock(controller.elapsed),
          key: const Key('dictation_timer'),
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: _ink(context, 0.6),
          ),
        ),
        const Spacer(),
        if (controller.showEngineSwitch) ...[
          _EngineMenu(controller),
          const SizedBox(width: 12),
        ],
        _StopButton(onTap: controller.stop),
      ],
    );
  }
}

/// 22 decorative bars (not a level meter): each timer tick rotates the
/// mockup's height sequence one bar along, animated between ticks.
class _Waveform extends StatelessWidget {
  const _Waveform({required this.phase});

  final int phase;

  /// The mockup's bar heights, 3–19px.
  static const _heights = <double>[
    3, 12, 17, 12, 3, 4, 3, 4, 11, 10, 3, //
    12, 19, 17, 7, 4, 9, 5, 3, 6, 3, 9,
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('dictation_waveform'),
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _heights.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOut,
              width: 3,
              height: _heights[(i + phase) % _heights.length],
              decoration: BoxDecoration(
                color: RelayTheme.relayDictationWave,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Stop dictating',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          key: const Key('dictation_stop'),
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: RelayTheme.relayDictationStop,
            shape: BoxShape.circle,
          ),
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}

/// The debug/TestFlight Apple/Whisper pull-down, styled like a UIMenu. A
/// Flutter [MenuAnchor] rather than a platform view so widget tests can see
/// it; it flips above the label because the keyboard inset leaves no room
/// below.
class _EngineMenu extends StatelessWidget {
  const _EngineMenu(this.controller);

  final DictationController controller;

  static String _label(VoiceEngine engine) => switch (engine) {
    VoiceEngine.apple => 'Apple',
    VoiceEngine.whisper => 'Whisper',
  };

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      menuChildren: [
        TextFieldTapRegion(
          child: SizedBox(
            width: 220,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final engine in VoiceEngine.values)
                  _EngineRow(
                    key: Key('dictation_engine_${engine.name}'),
                    label: _label(engine),
                    selected: engine == controller.activeEngine,
                    onTap: () {
                      MenuController.maybeOf(context)?.close();
                      controller.chooseEngine(engine);
                    },
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    'Debug & TestFlight builds only',
                    key: const Key('dictation_engine_footnote'),
                    style: TextStyle(fontSize: 12, color: _ink(context, 0.5)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, menu, _) => GestureDetector(
        key: const Key('dictation_engine_label'),
        behavior: HitTestBehavior.opaque,
        onTap: () => menu.isOpen ? menu.close() : menu.open(),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label(controller.activeEngine),
              style: TextStyle(fontSize: 12, color: primary),
            ),
            const SizedBox(width: 2),
            Icon(Icons.unfold_more, size: 12, color: primary),
          ],
        ),
      ),
    );
  }
}

class _EngineRow extends StatelessWidget {
  const _EngineRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: RelayTheme.relayHairline)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: selected
                  ? Icon(
                      Icons.check,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

/// Whisper after stop: the words land when this finishes. No stop — there is
/// nothing left to stop.
class _Transcribing extends StatelessWidget {
  const _Transcribing();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('dictation_transcribing'),
      height: 30,
      child: Row(
        children: [
          _ring(context),
          const SizedBox(width: 8),
          const Text('Transcribing…', style: _title),
        ],
      ),
    );
  }
}

class _Downloading extends StatelessWidget {
  const _Downloading(this.controller);

  final DictationController controller;

  @override
  Widget build(BuildContext context) {
    final progress = controller.downloadProgress;
    return Column(
      key: const Key('dictation_downloading'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _ring(
              context,
              key: const Key('dictation_download_ring'),
              value: progress,
            ),
            const SizedBox(width: 8),
            const Text('Downloading Apple dictation…', style: _title),
            const Spacer(),
            Text(
              '${(progress * 100).round()}%',
              key: const Key('dictation_download_percent'),
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: _ink(context, 0.55),
              ),
            ),
          ],
        ),
        _Indented(
          child: _Secondary('One time only · about a minute', alpha: 0.55),
        ),
        _Indented(
          child: _Buttons([
            _SmallText(
              key: const Key('dictation_use_whisper'),
              label: 'Use Whisper now',
              onPressed: controller.useWhisperNow,
            ),
            _SmallText(
              key: const Key('dictation_keep_typing'),
              label: 'Keep typing',
              onPressed: controller.keepTyping,
            ),
          ]),
        ),
      ],
    );
  }
}

/// Before the one-shot OS prompt — RLY-99's priming copy, carried over.
class _Priming extends StatelessWidget {
  const _Priming(this.controller);

  final DictationController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('dictation_priming'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Dictate instead of typing', style: _title),
        const _Secondary(
          "Relay listens only while you're dictating and transcribes on your "
          'phone — audio never leaves it.',
        ),
        _Buttons([
          _SmallFilled(
            key: const Key('dictation_allow_mic'),
            label: 'Allow microphone',
            onPressed: controller.allowMic,
          ),
          _SmallText(
            key: const Key('dictation_not_now'),
            label: 'Not now',
            onPressed: controller.dismiss,
          ),
        ]),
      ],
    );
  }
}

/// One plain line of cause, Try again or Open Settings, and always the
/// Type instead escape hatch (RLY-99's error copy, carried over).
class _Error extends StatelessWidget {
  const _Error(this.controller);

  final DictationController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('dictation_error'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          controller.errorMessage ?? "Didn't catch that.",
          key: const Key('dictation_error_message'),
          style: _title,
        ),
        _Buttons([
          if (controller.showTryAgain)
            _SmallFilled(
              key: const Key('dictation_try_again'),
              label: 'Try again',
              onPressed: controller.tryAgain,
            ),
          if (controller.showOpenSettings)
            _SmallFilled(
              key: const Key('dictation_open_settings'),
              label: 'Open Settings',
              onPressed: controller.openSettings,
            ),
          _SmallText(
            key: const Key('dictation_dismiss'),
            label: 'Type instead',
            onPressed: controller.dismiss,
          ),
        ]),
      ],
    );
  }
}

class _Secondary extends StatelessWidget {
  const _Secondary(this.text, {this.alpha = 0.65});

  final String text;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, color: _ink(context, alpha)),
      ),
    );
  }
}

/// The mockup's `ml-[26px]`: the 18px ring plus its 8px gap.
class _Indented extends StatelessWidget {
  const _Indented({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(left: 26), child: child);
}

class _Buttons extends StatelessWidget {
  const _Buttons(this.buttons);

  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 4, children: buttons),
    );
  }
}

class _SmallText extends StatelessWidget {
  const _SmallText({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    );
  }
}

class _SmallFilled extends StatelessWidget {
  const _SmallFilled({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: RelayTheme.relayHuman,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}
