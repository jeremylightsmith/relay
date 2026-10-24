import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'dictation_controller.dart';
import 'dictation_text_controller.dart';
import 'dictation_toolbar.dart';
import 'voice_engines.dart';

/// The field's mic (RE467): CORE-07's 30px circle, violet when idle and red
/// while dictating. A tap focuses the field (the keyboard comes up) and starts
/// dictation into [controller] at the cursor; [DictationToolbar] rides above
/// the keyboard through an [OverlayPortal] until dictation ends. Fill, never
/// send (RLY-99 D6).
class MicButton extends StatefulWidget {
  const MicButton({
    super.key,
    required this.controller,
    this.focusNode,
    this.voice,
    this.onInserted,
    this.debugBuild = kDebugMode,
  });

  /// The host field's controller — the dictation target.
  final DictationTextController controller;

  /// The host field's focus node, focused on the first tap.
  final FocusNode? focusNode;

  /// Structural seam for tests; null → [VoiceEngines.platform], built lazily
  /// on the first tap so hosts that are never dictated into touch no channel.
  final VoiceEngines? voice;

  /// Fired with the full new field text after every dictated change.
  /// TextField.onChanged only fires for user edits, so hosts that gate a
  /// button on the field's content (reject's Send back) re-check through this.
  final ValueChanged<String>? onInserted;

  /// Debug builds always offer the Apple/Whisper pull-down.
  final bool debugBuild;

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> {
  final _overlay = OverlayPortalController();
  DictationController? _dictation;

  DictationController get _ensureDictation =>
      _dictation ??= DictationController(
        widget.voice ?? VoiceEngines.platform(),
        field: widget.controller,
        onInserted: (text) => widget.onInserted?.call(text),
        debugBuild: widget.debugBuild,
      )..addListener(_onStage);

  /// Shows the toolbar for every non-idle stage; re-colours the mic.
  void _onStage() {
    final idle = _dictation!.stage == DictationStage.idle;
    if (idle && _overlay.isShowing) {
      _overlay.hide();
    } else if (!idle && !_overlay.isShowing) {
      _overlay.show();
    }
    setState(() {});
  }

  void _tap() {
    widget.focusNode?.requestFocus();
    _ensureDictation.toggle();
  }

  @override
  void dispose() {
    _dictation?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _dictation?.isActive ?? false;
    return OverlayPortal(
      controller: _overlay,
      overlayChildBuilder: (context) {
        // The view's own insets: a Scaffold body has the keyboard inset
        // removed from its MediaQuery, but the toolbar sits on the keyboard.
        return MediaQuery.fromView(
          view: View.of(context),
          child: Builder(
            builder: (context) => Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.viewInsetsOf(context).bottom,
              child: DictationToolbar(controller: _dictation!),
            ),
          ),
        );
      },
      child: TextFieldTapRegion(
        child: Semantics(
          button: true,
          label: 'Dictate',
          child: InkWell(
            onTap: _tap,
            customBorder: const CircleBorder(),
            child: Container(
              key: const Key('mic_circle'),
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active
                    ? RelayTheme.relayMicActiveFill
                    : RelayTheme.relayMicFill,
                shape: BoxShape.circle,
                border: Border.all(
                  color: active
                      ? RelayTheme.relayMicActiveBorder
                      : RelayTheme.relayMicBorder,
                ),
              ),
              child: Container(
                width: 7,
                height: 12,
                decoration: BoxDecoration(
                  color: active
                      ? RelayTheme.relayMicActiveGlyph
                      : RelayTheme.relayMicGlyph,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
