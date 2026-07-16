import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'append_transcript.dart';
import 'voice_sheet.dart';
import 'voice_transcriber.dart';

/// The live mic (RLY-99 U5): CORE-07's 30px circle, violet and tappable.
/// Opens the voice sheet and appends the returned transcript to [controller] —
/// append, never replace (D7); fill, never send (D6).
class MicButton extends StatelessWidget {
  const MicButton({
    super.key,
    required this.controller,
    this.transcriber,
    this.onInserted,
  });

  final TextEditingController controller;

  /// Structural seam for tests; null → the real WhisperKit-backed engine.
  final VoiceTranscriber? transcriber;

  /// Fired with the full new field text after an insert. TextField.onChanged
  /// only fires for user edits, so hosts that gate a button on the field's
  /// content (reject's Send back) re-check through this.
  final ValueChanged<String>? onInserted;

  Future<void> _dictate(BuildContext context) async {
    final text = await showVoiceSheet(context, transcriber: transcriber);
    if (text == null || text.isEmpty) return;
    final next = appendTranscript(controller.text, text);
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    onInserted?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Dictate',
      child: InkWell(
        onTap: () => _dictate(context),
        customBorder: const CircleBorder(),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: RelayTheme.relayMicFill,
            shape: BoxShape.circle,
            border: Border.all(color: RelayTheme.relayMicBorder),
          ),
          child: Container(
            width: 7,
            height: 12,
            decoration: BoxDecoration(
              color: RelayTheme.relayMicGlyph,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }
}
