import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/relay_avatar.dart';
import '../auth/auth_controller.dart';
import 'logout_confirm_dialog.dart';

/// SET-01 Settings (RLY-90): the identity block + the outlined destructive
/// Log out button, as the artboard draws it. The artboard's rows card is
/// deliberately not built — Notifications / Voice replies await SET-03 and
/// RLY-99, and the Account row was cut at Review ("add logout to the
/// settings page and get rid of account"). The auth gate makes signed-out
/// unreachable here; the null-tolerant reads below are for the ungated
/// shell test, not a real state.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final user = ref.watch(authProvider).user ?? const <String, dynamic>{};
    final name = (user['name'] as String?) ?? '';
    final email = (user['email'] as String?) ?? '';
    final avatarUrl = user['avatar_url'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
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
