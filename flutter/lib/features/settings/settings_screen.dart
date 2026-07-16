import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/relay_avatar.dart';
import '../auth/auth_controller.dart';

/// SET-01 Settings (RLY-90): the identity block + one `Account ›` row.
/// Log out lives on the Account screen [answer 1(b)], and the artboard's
/// Notifications / Voice replies rows are deliberately not built — SET-03 is
/// deferred and RLY-99 is still in Backlog. The auth gate makes signed-out
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
          const SizedBox(height: 20),
          // The rows card, down to its one backed row (SET-01 divergence 1).
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: InkWell(
              key: const Key('settings_account_row'),
              onTap: () => context.push('/account'),
              child: Padding(
                padding: const EdgeInsets.all(13),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Account',
                        style: TextStyle(fontSize: 13, color: scheme.onSurface),
                      ),
                    ),
                    Text(
                      '›',
                      style: TextStyle(
                        fontSize: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
