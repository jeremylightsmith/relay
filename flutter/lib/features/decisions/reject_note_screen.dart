import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import 'review_queue.dart';

/// CORE-07 "Reject · note required" (docs/designs/Relay Mobile.dc.html — the artboard
/// whose *visible badge* reads CORE-06; the HTML comment IDs are the real ones).
///
/// Reached at `/card/:ref/reject?board=<slug>`. The note is required: F4 answers a blank
/// one with 422 missing_note, and this screen is the client half of that rule — the
/// server stays the authority.
///
/// CORE-08 ("Sent back") is deliberately NOT built (D1): its full-screen confirmation
/// contradicts the auto-advance this card confirmed. The "it happened" signal is the
/// banner the next screen shows.
class RejectNoteScreen extends ConsumerStatefulWidget {
  const RejectNoteScreen({
    super.key,
    required this.cardRef,
    required this.boardSlug,
  });

  final String cardRef;
  final String boardSlug;

  @override
  ConsumerState<RejectNoteScreen> createState() => _RejectNoteScreenState();
}

class _RejectNoteScreenState extends ConsumerState<RejectNoteScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Routed through [ReviewQueue.rejectCurrent] rather than calling
  /// `DecisionApi.reject` directly — that keeps reject's outcome policy
  /// identical to approve's: `not_in_review` advances with "Already handled",
  /// `unauthorized` signs out (the router sends the human to `/welcome`), and
  /// only everything else lands as `reviewQueueProvider`'s `state.error`. It
  /// also puts reject behind the same `inFlight` double-tap guard approve gets.
  Future<void> _send() async {
    final router = GoRouter.of(context);
    final dest = await ref
        .read(reviewQueueProvider.notifier)
        .rejectCurrent(note: _controller.text.trim());
    if (!mounted || dest == null) return;

    // Drop the reject screen first, so the next card replaces the card we just
    // sent back rather than stacking on top of it. A cold deep link (or a
    // stashed sign-in resuming straight here) can leave nothing to pop — in
    // that case there is no card underneath to reveal, so just replace this
    // screen outright.
    if (router.canPop()) router.pop();
    navigateQueue(router, dest);
  }

  @override
  Widget build(BuildContext context) {
    final queueState = ref.watch(reviewQueueProvider);
    final canSend = _controller.text.trim().isNotEmpty && !queueState.inFlight;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _NavRow(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                child: Column(
                  // stretch, not start: the note field must fill the width, or the
                  // TextField inside its Stack sizes to its text and the mic's
                  // bottom-right anchor drifts inward.
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _BodyCopy(),
                    _NoteField(
                      controller: _controller,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8), // artboard margin-top:8px
                    const _Hint(),
                    if (queueState.error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        queueState.error!,
                        key: const Key('reject_error'),
                        style: const TextStyle(
                          fontSize: 13,
                          color: RelayTheme.relayReject,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _BottomBar(onSend: canSend ? _send : null),
          ],
        ),
      ),
    );
  }
}

/// The artboard's native nav row: a chevron chip and a title, over a hairline.
class _NavRow extends StatelessWidget {
  const _NavRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5E8EC)), // oklch(0.93 0.006 255)
        ),
      ),
      child: Row(
        children: [
          InkWell(
            key: const Key('reject_back'),
            onTap: () => Navigator.of(context).maybePop(),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFEFF2F6), // oklch(0.96 0.006 255)
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '‹',
                style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFF414853), // oklch(0.4 0.02 255)
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Send back',
            key: Key('reject_nav_title'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1E252E), // oklch(0.26 0.02 255)
            ),
          ),
        ],
      ),
    );
  }
}

class _BodyCopy extends StatelessWidget {
  const _BodyCopy();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 14), // artboard margin-bottom:14px
      child: Text.rich(
        TextSpan(
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Color(0xFF313942), // oklch(0.34 0.02 255)
          ),
          children: [
            TextSpan(text: 'Tell Relay AI what to fix. A note is '),
            TextSpan(
              text: 'required',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: ' so it can revise.'),
          ],
        ),
        key: Key('reject_body_copy'),
      ),
    );
  }
}

class _NoteField extends StatelessWidget {
  const _NoteField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('reject_note_field'),
      constraints: const BoxConstraints(minHeight: 120),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: RelayTheme.relayRejectBorder, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      // The 12px padding belongs to the text, not the Stack: CSS resolves the
      // mic's `bottom:10px right:10px` against the field's padding box (inside
      // the border, ignoring the 12px text inset). Padding the Stack itself
      // would carry that 12px into the Positioned offset too, drifting the mic
      // to 22px instead of the artboard's 10px.
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('reject_note_input'),
              controller: controller,
              onChanged: onChanged,
              maxLines: null,
              autofocus: true,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration.collapsed(
                hintText: 'Reason…',
                hintStyle: TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF7E8792), // oklch(0.62 0.02 255)
                ),
              ),
            ),
          ),
          const Positioned(bottom: 10, right: 10, child: _InertMic()),
        ],
      ),
    );
  }
}

/// The mic, drawn and dead (D4). RLY-99 makes it live; until then it is a visual
/// placeholder only — no tap target, no "coming soon" toast, and kept out of the
/// semantics tree so screen readers do not announce a button that does nothing.
class _InertMic extends StatelessWidget {
  const _InertMic();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        key: const Key('reject_mic'),
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: RelayTheme.micGhostFill,
          shape: BoxShape.circle,
          border: Border.all(color: RelayTheme.micGhostBorder),
        ),
        child: Container(
          width: 7,
          height: 12,
          decoration: BoxDecoration(
            color: RelayTheme.micGhostGlyph,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: const BoxDecoration(
            color: RelayTheme.relayReject,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        // D4a: the artboard reads "Add a reason to continue · or dictate it", but the
        // mic is inert — promising dictation next to a dead control is a promise the
        // screen cannot keep, so that half is dropped.
        const Text(
          'Add a reason to continue',
          key: Key('reject_hint'),
          style: TextStyle(
            fontSize: 10.5,
            fontFamily: 'monospace',
            color: RelayTheme.relayRejectHint,
          ),
        ),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.onSend});

  /// Null disables the button — the client half of F4's missing_note rule.
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 22),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Color(0xFFE2E5E9)), // oklch(0.92 0.006 255)
        ),
      ),
      child: FilledButton(
        key: const Key('reject_send'),
        onPressed: onSend,
        style: FilledButton.styleFrom(
          backgroundColor: RelayTheme.relayReject,
          foregroundColor: Colors.white,
          disabledBackgroundColor: RelayTheme.relayRejectDisabledBg,
          disabledForegroundColor: RelayTheme.relayRejectDisabledFg,
          minimumSize: const Size.fromHeight(
            48,
          ), // artboard padding:13px, full width
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
          textStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        child: const Text('Send back'),
      ),
    );
  }
}
