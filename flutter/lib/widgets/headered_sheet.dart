import 'package:flutter/material.dart';

import '../app/theme.dart';

/// A bottom-sheet layout with a fixed header (leading | centred title | action)
/// and a body that scrolls beneath it (RE434, card mockup "B — primary action in
/// the sheet header").
///
/// Short bodies stay a compact sheet; long ones fill the space between the top
/// safe area and the keyboard and scroll, so the header's primary action is never
/// pushed off-screen.
///
/// **HeaderedSheet owns the keyboard inset** — callers must not also pad by
/// `viewInsets.bottom`. Host it in
/// `showModalBottomSheet(isScrollControlled: true, useSafeArea: true)`: the body's
/// `Flexible` only bounds the scroll view under a bounded max height, and without
/// `useSafeArea` the sheet can grow under the status bar.
class HeaderedSheet extends StatelessWidget {
  const HeaderedSheet({
    super.key,
    required this.leading,
    required this.title,
    required this.action,
    required this.body,
    this.showHandle = false,
    this.headerPadding = const EdgeInsets.fromLTRB(12, 12, 12, 8),
    this.bodyPadding = const EdgeInsets.fromLTRB(16, 12, 16, 22),
  });

  final Widget leading;
  final Widget title;
  final Widget action;
  final List<Widget> body;
  final bool showHandle;
  final EdgeInsets headerPadding;
  final EdgeInsets bodyPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: const Key('sheet_header'),
            padding: headerPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showHandle) ...[
                  Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: RelayTheme.relayHairline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    leading,
                    Expanded(child: Center(child: title)),
                    action,
                  ],
                ),
              ],
            ),
          ),
          const Divider(
            height: 1,
            thickness: 1,
            color: RelayTheme.relayHairline,
          ),
          Flexible(
            child: SingleChildScrollView(
              key: const Key('sheet_body'),
              padding: bodyPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: body,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The header's leading "Cancel" — the mockup's
/// `btn btn-ghost btn-sm text-base-content/70`.
class SheetHeaderCancel extends StatelessWidget {
  const SheetHeaderCancel({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      child: const Text('Cancel'),
    );
  }
}

/// The header's compact blue primary action — the mockup's
/// `btn btn-primary btn-sm rounded-lg`. While [busy] it shows a small spinner in
/// place of its label and is disabled whatever [onPressed] was passed.
class SheetHeaderAction extends StatelessWidget {
  const SheetHeaderAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      child: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Text(label),
    );
  }
}
