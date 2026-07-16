import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../voice/mic_button.dart';
import '../voice/voice_transcriber.dart';
import 'answer_stepper.dart';
import 'review_queue.dart';

// INPUT-01's neutral chrome, converted oklch → sRGB. Feature-local: unlike the
// needs-input trio in RelayTheme, nothing outside this screen draws these.
const _navHairline = Color(0xFFE5E8EC); // oklch(0.93 0.006 255)
const _footerHairline = Color(0xFFE2E5E9); // oklch(0.92 0.006 255)
const _navChipBg = Color(0xFFEFF2F6); // oklch(0.96 0.006 255)
const _navChipGlyph = Color(0xFF414853); // oklch(0.4 0.02 255)
const _breadcrumb = Color(0xFF6A727D); // oklch(0.55 0.02 255)
const _titleColor = Color(0xFF141B24); // oklch(0.22 0.02 255)
const _attribution = Color(0xFF313942); // oklch(0.34 0.02 255)
const _promptColor = Color(0xFF272E38); // oklch(0.3 0.02 255)
const _sectionLabel = Color(0xFF78818C); // oklch(0.6 0.02 255)
const _optionSelectedBg = Color(0xFFE3F4FF); // oklch(0.96 0.03 250)
const _optionBorder = Color(0xFFDBDEE2); // oklch(0.9 0.006 255)
const _optionRadio = Color(0xFFC0C4CB); // oklch(0.82 0.01 255)
const _optionSelectedTitle = Color(0xFF192029); // oklch(0.24 0.02 255)
const _optionTitle = Color(0xFF1E252E); // oklch(0.26 0.02 255)
const _rowDivider = Color(0xFFE8EBEF); // oklch(0.94 0.006 255)

/// INPUT-01 ("Question · answer") — `docs/designs/Relay Mobile.dc.html`, HTML comment
/// ~line 320. A **fully native** decision surface (spec D2, closing ADR 0005's
/// structured-question open question): no webview, no JS bridge.
///
/// **Two modes, switched on the row's `questions`** — the field is the switch, because
/// `Cards.request_input/3`'s string clause writes no `"questions"` key at all:
/// non-null → the stepper → `answers[]`; null → one text field → `answer`. Shipping
/// only one shape would 400 on every legacy question or fail to render a structured one.
///
/// Renders from the queue's feed snapshot and never refetches (spec D7). **Accepted
/// race:** if the card is answered on the web *and* the agent then asks something new
/// while this screen is open, our positional `answers[]` composes against the *new*
/// prompts server-side — silent mis-attribution. The window is narrow (a blocked agent
/// cannot re-ask until unblocked; the common case is a clean `422 not_needs_input`
/// skip). The honest fix is a server-side question fingerprint + 409, and belongs to
/// F4/RLY-80 — not here.
///
/// INPUT-02 ("Answer sent") is **superseded** (spec D4): sending auto-advances, and the
/// "it happened" signal is the banner shown over the *next* item.
class AnswerScreen extends ConsumerStatefulWidget {
  const AnswerScreen({super.key, required this.cardRef, this.transcriber});

  final String cardRef;

  /// Structural seam for tests; null → the real WhisperKit-backed engine.
  final VoiceTranscriber? transcriber;

  @override
  ConsumerState<AnswerScreen> createState() => _AnswerScreenState();
}

class _AnswerScreenState extends ConsumerState<AnswerScreen> {
  final _text = TextEditingController();

  QueueItem? _item;
  AnswerStepper? _stepper;

  @override
  void initState() {
    super.initState();
    _syncItem();
    _scheduleBanner();
  }

  // go_router's default page key is derived from the route *pattern*
  // (`/card/:ref/answer`), not the resolved path — so navigating from RLY-A's
  // answer screen to RLY-B's via pushReplacement matches the same page key and
  // reuses this State rather than remounting it. initState() alone would then
  // never see RLY-B: didUpdateWidget is what notices the ref changed and
  // re-syncs from the (already-advanced) queue snapshot.
  @override
  void didUpdateWidget(covariant AnswerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cardRef != oldWidget.cardRef) {
      _syncItem();
      _scheduleBanner();
    }
  }

  // Captured, deliberately NOT watched: advanceAfter() steps the queue's index
  // *before* we navigate, so a watch would rebuild this screen with the next
  // card's question while it is still mounted.
  void _syncItem() {
    final current = ref.read(reviewQueueProvider).current;
    _item = current != null && current.ref == widget.cardRef ? current : null;

    final questions = _item?.questions;
    _stepper = questions != null && questions.isNotEmpty
        ? AnswerStepper(questions)
        : null;
    _text.clear();
  }

  // The banner belongs to the item we just cleared, shown over the one we landed on.
  void _scheduleBanner() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final banner = ref.read(reviewQueueProvider.notifier).takeBanner();
      if (banner != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(banner)));
      }
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// The free-text field is the whole answer in legacy mode, and the current step's
  /// custom answer in stepper mode.
  bool get _canSubmit {
    final stepper = _stepper;
    if (stepper == null) return _text.text.trim().isNotEmpty;
    return stepper.canAdvance;
  }

  Future<void> _submit() async {
    final stepper = _stepper;

    // Not the last question yet: Next only advances.
    if (stepper != null && !stepper.isLast) {
      setState(stepper.next);
      _text.text = stepper.customText;
      return;
    }

    // No clearError() here: answerCurrent clears it as it goes in flight, so Retry
    // drops the strip on its own.
    final dest = await ref
        .read(reviewQueueProvider.notifier)
        .answerCurrent(
          answers: stepper?.toAnswers(),
          text: stepper == null ? _text.text : null,
        );
    if (!mounted || dest == null) return;
    navigateQueue(GoRouter.of(context), dest);
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    if (item == null) return const _Unavailable();

    // .select so stepping the queue's index does not rebuild this screen.
    final inFlight = ref.watch(reviewQueueProvider.select((s) => s.inFlight));
    final error = ref.watch(reviewQueueProvider.select((s) => s.error));
    final stepper = _stepper;
    final question = stepper?.current;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NavRow(
              breadcrumb: [
                item.boardName,
                if (item.stage != null) item.stage,
              ].join(' / '),
              stepLabel: stepper == null
                  ? null
                  : '${stepper.step + 1} of ${stepper.length}',
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TitleBlock(title: item.title),
                    const SizedBox(height: 14), // artboard 9
                    Text(
                      // Stepper mode prompts per step; legacy mode's question is the
                      // row's `reason` (FeedJSON renders it from meta["question"]).
                      question?.prompt ?? item.reason ?? '',
                      key: const Key('answer_prompt'),
                      style: const TextStyle(
                        fontSize: 21, // artboard 13 × 1.585
                        height: 1.4,
                        color: _promptColor,
                      ),
                    ),
                    const SizedBox(height: 19), // artboard 12
                    if (question != null && question.options.isNotEmpty) ...[
                      Text(
                        question.allowText
                            ? 'PICK ONE · OR ADD YOUR OWN'
                            : 'PICK ONE',
                        key: const Key('answer_section_label'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13.5, // artboard 8.5 × 1.585
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.81, // artboard 0.06em
                          color: _sectionLabel,
                        ),
                      ),
                      const SizedBox(height: 14), // artboard 9
                      for (var i = 0; i < question.options.length; i++) ...[
                        _OptionRow(
                          index: i,
                          label: question.options[i],
                          selected: stepper!.value == question.options[i],
                          onTap: () => setState(() {
                            stepper.select(question.options[i]);
                            // Picking clears the text row (stepper_custom_text/3).
                            _text.text = stepper.customText;
                          }),
                        ),
                        const SizedBox(height: 13), // artboard 8
                      ],
                    ],
                    // Stepper mode: only when the question allows text. Legacy mode
                    // (no stepper): the text field IS the answer.
                    if (stepper == null || question!.allowText)
                      _TextRow(
                        controller: _text,
                        // "Something else…" is INPUT-01's framing *for a picker*. With
                        // no options above it — a legacy question, or a structured
                        // free-text step — there is nothing to be something else than.
                        withPickerChrome:
                            question != null && question.options.isNotEmpty,
                        transcriber: widget.transcriber,
                        onChanged: (value) => setState(() {
                          if (stepper != null) stepper.setText(value);
                        }),
                      ),
                    if (error != null) ...[
                      const SizedBox(height: 16),
                      _ErrorStrip(message: error, onRetry: _submit),
                    ],
                  ],
                ),
              ),
            ),
            _Footer(
              label: stepper == null || stepper.isLast ? 'Send' : 'Next',
              onPressed: _canSubmit && !inFlight ? _submit : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The queue is how this screen gets its question (D7), so a route that does not match
/// the queue's current item has nothing to render. Reachable only by hand-typing the
/// URL — but a dead Send button would be worse than a way back.
class _Unavailable extends StatelessWidget {
  const _Unavailable();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: Center(
      key: const Key('answer_unavailable'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Open this card from Needs you to answer it.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, color: _breadcrumb),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => GoRouter.of(context).go('/needs-you'),
              child: const Text('Needs you'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// INPUT-01's nav row: back chip + "`<Board> / <Stage>`", plus the ADDED step counter
/// (the artboard draws "Next" with no progress affordance — see the plan).
class _NavRow extends StatelessWidget {
  const _NavRow({required this.breadcrumb, required this.stepLabel});

  final String breadcrumb;
  final String? stepLabel;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(22, 6, 22, 16), // artboard 14/4/10
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: _navHairline)),
    ),
    child: Row(
      children: [
        GestureDetector(
          key: const Key('answer_nav_back'),
          onTap: () {
            final router = GoRouter.of(context);
            if (router.canPop()) {
              router.pop();
            } else {
              router.go('/needs-you');
            }
          },
          child: Container(
            width: 41, // artboard 26
            height: 41,
            decoration: BoxDecoration(
              color: _navChipBg,
              borderRadius: BorderRadius.circular(13), // artboard 8
            ),
            alignment: Alignment.center,
            child: const Text(
              '‹',
              style: TextStyle(fontSize: 24, color: _navChipGlyph),
            ),
          ),
        ),
        const SizedBox(width: 13), // artboard 8
        Expanded(
          child: Text(
            breadcrumb,
            key: const Key('answer_breadcrumb'),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 17, // artboard 11
              color: _breadcrumb,
            ),
          ),
        ),
        if (stepLabel != null)
          Text(
            stepLabel!,
            key: const Key('answer_step_counter'),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 17,
              color: _breadcrumb,
            ),
          ),
      ],
    ),
  );
}

/// INPUT-01's title + attribution row: card title, violet AI avatar, "Relay AI", and
/// the amber NEEDS INPUT pill.
class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        key: const Key('answer_title'),
        style: const TextStyle(
          fontSize: 24, // artboard 15
          fontWeight: FontWeight.w600,
          letterSpacing: -0.48, // artboard -0.02em
          height: 1.2,
          color: _titleColor,
        ),
      ),
      const SizedBox(height: 11), // artboard 7
      Row(
        children: [
          Container(
            width: 28, // artboard 18
            height: 28,
            decoration: const BoxDecoration(
              color: RelayTheme.relayAI,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Text(
              'AI',
              style: TextStyle(
                fontSize: 13, // artboard 8
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10), // artboard 6
          const Text(
            'Relay AI',
            style: TextStyle(
              fontSize: 17, // artboard 11
              fontWeight: FontWeight.w500,
              color: _attribution,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10, // artboard 6
              vertical: 3, // artboard 2
            ),
            decoration: BoxDecoration(
              color: RelayTheme.relayNeedsInputBg,
              border: Border.all(color: RelayTheme.relayNeedsInputBorder),
              borderRadius: BorderRadius.circular(8), // artboard 5
            ),
            child: const Text(
              'NEEDS INPUT',
              key: Key('answer_needs_input_pill'),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13, // artboard 8
                fontWeight: FontWeight.w600,
                color: RelayTheme.relayNeedsInputText,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

/// One single-select option card. **No subtitle** — RLY-71's wire format is plain
/// strings (D3).
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.index,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      key: Key('answer_option_$index'),
      padding: const EdgeInsets.symmetric(
        horizontal: 19, // artboard 12
        vertical: 17, // artboard 11
      ),
      decoration: BoxDecoration(
        color: selected ? _optionSelectedBg : Colors.white,
        border: Border.all(
          color: selected ? RelayTheme.relayHuman : _optionBorder,
          width: selected ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(19), // artboard 12
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 21, // artboard 13
                fontWeight: FontWeight.w600,
                color: selected ? _optionSelectedTitle : _optionTitle,
              ),
            ),
          ),
          const SizedBox(width: 16), // artboard 10
          Container(
            width: 32, // artboard 20
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? RelayTheme.relayHuman : null,
              border: selected
                  ? null
                  : Border.all(color: _optionRadio, width: 2),
            ),
            alignment: Alignment.center,
            child: selected
                ? Container(
                    width: 11, // artboard 7
                    height: 11,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  )
                : null,
          ),
        ],
      ),
    ),
  );
}

/// INPUT-01's "Something else…" row in stepper mode; the whole answer field in legacy
/// mode. INPUT-01 drew no mic here (D5 deferred it); RLY-99 (U5) adds one, reusing the
/// same [MicButton] the reject note field got.
class _TextRow extends StatelessWidget {
  const _TextRow({
    required this.controller,
    required this.withPickerChrome,
    required this.transcriber,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool withPickerChrome;
  final VoiceTranscriber? transcriber;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 17),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _optionBorder),
      borderRadius: BorderRadius.circular(19),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (withPickerChrome)
          const Text(
            'Something else…',
            style: TextStyle(
              fontSize: 21, // artboard 13
              fontWeight: FontWeight.w600,
              color: _optionTitle,
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('answer_text'),
                controller: controller,
                onChanged: onChanged,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Type your answer…',
                ),
                style: const TextStyle(fontSize: 21, color: _promptColor),
              ),
            ),
            const SizedBox(width: 8),
            MicButton(
              key: const Key('answer_mic'),
              controller: controller,
              transcriber: transcriber,
              onInserted: onChanged,
            ),
          ],
        ),
        if (withPickerChrome) ...[
          const Divider(
            height: 25,
            color: _rowDivider,
          ), // artboard 8/8 + hairline
          const Text(
            'Type your own answer',
            style: TextStyle(
              fontSize: 17, // artboard 11
              color: _sectionLabel,
            ),
          ),
        ],
      ],
    ),
  );
}

/// A stay-put failure. Never silently discards the typed/picked answer — Retry re-posts
/// exactly what is on screen.
class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          message,
          key: const Key('answer_error'),
          style: const TextStyle(fontSize: 16, color: _promptColor),
        ),
      ),
      TextButton(
        key: const Key('answer_retry'),
        onPressed: onRetry,
        child: const Text('Retry'),
      ),
    ],
  );
}

/// INPUT-01's pinned footer: white, top hairline, one full-width primary button.
class _Footer extends StatelessWidget {
  const _Footer({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(22, 16, 22, 32), // artboard 14/10/20
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: _footerHairline)),
    ),
    child: FilledButton(
      key: const Key('answer_submit'),
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: RelayTheme.relayHuman,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(
          48,
        ), // artboard padding:13px, full width
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(19), // artboard 12
        ),
        textStyle: const TextStyle(
          fontSize: 22, // artboard 14
          fontWeight: FontWeight.w600,
        ),
      ),
      child: Text(label),
    ),
  );
}
