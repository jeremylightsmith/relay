import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../widgets/relay_avatar.dart';
import '../auth/auth_controller.dart';
import '../boards/board_switcher.dart';
import 'external_url_launcher.dart';
import 'logout_confirm_dialog.dart';

/// SET-01 Settings (RLY-90): the identity block, the outlined rows card, and
/// the outlined destructive Log out button, as the artboard draws them. The
/// rows card holds one row today — "Suggest an idea" (RE397), which opens the
/// server's `feedback_url` in the system browser and is shown only when the
/// server sends one; with no URL the card is not built at all and the screen
/// is exactly the pre-RE397 one. Notifications / Voice replies (SET-03 /
/// RLY-99) can join the card later; the Account row stays cut at Review ("add
/// logout to the settings page and get rid of account"). The auth gate makes
/// signed-out unreachable here; the null-tolerant reads below are for the
/// ungated shell test, not a real state.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final auth = ref.watch(authProvider);
    final user = auth.user ?? const <String, dynamic>{};
    final feedbackUrl = auth.feedbackUrl;
    final hasFeedback = feedbackUrl != null && feedbackUrl.isNotEmpty;
    final name = (user['name'] as String?) ?? '';
    final email = (user['email'] as String?) ?? '';
    final avatarUrl = user['avatar_url'] as String?;

    return Scaffold(
      // RE376: the board name is every tab's title; Settings' own content is unchanged.
      appBar: AppBar(title: const BoardSwitcherTitle()),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
        children: [
          Row(
            children: [
              RelayAvatar(
                key: const Key('settings_avatar'),
                src: avatarUrl,
                name: name,
                email: email,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      key: const Key('settings_name'),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    Text(
                      email,
                      key: const Key('settings_email'),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          if (hasFeedback) ...[
            _RowsCard(children: [_SuggestIdeaRow(url: feedbackUrl)]),
            const SizedBox(height: 24),
          ],
          // SET-01's outlined destructive Log out (artboard line ~571).
          OutlinedButton(
            key: const Key('settings_log_out'),
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.error,
              side: BorderSide(color: scheme.error.withValues(alpha: 0.45)),
              padding: const EdgeInsets.all(13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: () => showLogoutConfirmDialog(context),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
  }
}

/// The artboard's outlined rows card: a 1px `outlineVariant` border at radius
/// 12, its rows clipped just inside it so their ink stays in the corners.
class _RowsCard extends StatelessWidget {
  const _RowsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('settings_rows_card'),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11), // inside the 1px border
        child: Material(
          type: MaterialType.transparency,
          child: Column(children: children),
        ),
      ),
    );
  }
}

/// "Suggest an idea" (RE397): opens Relay's public roadmap outside the app —
/// [LaunchMode.externalApplication], the system browser, never an in-app view.
class _SuggestIdeaRow extends ConsumerWidget {
  const _SuggestIdeaRow({required this.url});

  final String url;

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final launch = ref.read(externalUrlLauncherProvider);
    var opened = false;
    try {
      opened = await launch(Uri.parse(url), LaunchMode.externalApplication);
    } on Exception {
      // A thrown PlatformException is the same user-visible failure as false.
    }
    if (opened || !context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Couldn't open the link")));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: const Key('settings_suggest_idea'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(
        Icons.lightbulb_outline,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      title: Text(
        'Suggest an idea',
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
        ),
      ),
      subtitle: Text(
        "Share or upvote ideas on Relay's public roadmap",
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
      trailing: Icon(
        Icons.open_in_new,
        size: 16,
        color: scheme.onSurfaceVariant,
      ),
      onTap: () => _open(context, ref),
    );
  }
}
