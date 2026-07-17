import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../voice/mic_button.dart';
import '../voice/voice_transcriber.dart';
import 'board_api.dart';

/// The `relayCreateCard` bridge payload (RLY-126 · BOARD-04): which board the
/// sheet creates into, the top-level stage names for the chip row, and the
/// stage the pager was showing when + was tapped.
class CreateCardRequest {
  const CreateCardRequest({
    required this.board,
    required this.stages,
    required this.current,
  });

  final String board;
  final List<String> stages;
  final String current;

  /// Null when the payload is unusable (no board or no stages) — nothing to
  /// create into. A `current` missing from `stages` falls back to the first
  /// stage, matching the hook's own fallback.
  static CreateCardRequest? fromPayload(Map<dynamic, dynamic> payload) {
    final board = payload['board'] as String?;
    final stages = (payload['stages'] as List?)?.cast<String>();
    if (board == null || board.isEmpty || stages == null || stages.isEmpty) {
      return null;
    }
    final current = payload['current'] as String?;
    return CreateCardRequest(
      board: board,
      stages: stages,
      current: stages.contains(current) ? current! : stages.first,
    );
  }
}

/// The submit seam: the sheet never talks to Dio directly, so widget tests run
/// on the host (same style as CardScreen's bodyBuilder / decision_api seams).
typedef SubmitCreateCard =
    Future<CreateCardResult> Function({
      required String board,
      required String stage,
      required String title,
      String? description,
    });

/// Slides BOARD-04's New-card sheet up over the (dimmed) board.
Future<void> showNewCardSheet(
  BuildContext context,
  CreateCardRequest request, {
  SubmitCreateCard? submit,
  VoiceTranscriber? transcriber,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => Padding(
      // Keep the Add card button above the keyboard.
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: NewCardSheet(
        request: request,
        submit: submit,
        transcriber: transcriber,
      ),
    ),
  );
}

/// BOARD-04 · Create card: title, description with the RLY-99 dictation mic,
/// a STAGE chip row, and a full-width Add card button. The card lands in the
/// picked stage; the board webview updates by itself via LiveView realtime.
class NewCardSheet extends ConsumerStatefulWidget {
  const NewCardSheet({
    super.key,
    required this.request,
    this.submit,
    this.transcriber,
  });

  final CreateCardRequest request;

  /// Test seam; null → the real [BoardApi] via [boardApiProvider].
  final SubmitCreateCard? submit;

  /// Forwarded to the description [MicButton] (test seam, as in RLY-99 hosts).
  final VoiceTranscriber? transcriber;

  @override
  ConsumerState<NewCardSheet> createState() => _NewCardSheetState();
}

class _NewCardSheetState extends ConsumerState<NewCardSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _description = TextEditingController();
  late String _stage = widget.request.current;
  bool _submitting = false;
  String? _error;

  bool get _canSubmit => _title.text.trim().isNotEmpty && !_submitting;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    final submit = widget.submit ?? ref.read(boardApiProvider).createCard;
    final result = await submit(
      board: widget.request.board,
      stage: _stage,
      title: _title.text.trim(),
      description: _description.text.trim().isEmpty ? null : _description.text,
    );
    if (!mounted) return;
    switch (result) {
      case CreateCardOk():
        // The board webview picks the new card up via LiveView realtime.
        Navigator.of(context).pop();
      case CreateCardFailed(:final message):
        setState(() {
          _submitting = false;
          _error = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E1E4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'New card',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('new_card_title'),
              controller: _title,
              autofocus: true,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Card title',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: RelayTheme.relayHairline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: primary, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              decoration: BoxDecoration(
                border: Border.all(color: RelayTheme.relayHairline),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('new_card_description'),
                      controller: _description,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText:
                            'Add a description, or tap the mic to dictate…',
                        hintMaxLines: 2,
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: MicButton(
                      controller: _description,
                      transcriber: widget.transcriber,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'STAGE',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final stage in widget.request.stages)
                  _StageChip(
                    key: Key('stage_chip_$stage'),
                    name: stage,
                    selected: stage == _stage,
                    onTap: () => setState(() => _stage = stage),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: RelayTheme.relayReject,
                ),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              key: const Key('new_card_submit'),
              onPressed: _canSubmit ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: primary,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Add card',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One BOARD-04 stage chip: blue-tinted with a square blue dot when selected,
/// neutral hairline otherwise.
class _StageChip extends StatelessWidget {
  const _StageChip({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? RelayTheme.relayChipSelectedBg : Colors.white,
          border: Border.all(
            color: selected
                ? RelayTheme.relayChipSelectedBorder
                : RelayTheme.relayHairline,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? const Color(0xFF33373D)
                    : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
