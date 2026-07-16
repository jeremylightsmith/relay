import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/relay_avatar.dart';
import '../auth/auth_controller.dart';
import 'logout_confirm_dialog.dart';

/// The Account screen (RLY-90, answer 1(b)): name + email + Log out, pushed
/// from Settings' `Account ›` row. There is no artboard for it — it borrows
/// SET-01's identity block and destructive-button treatment. Pushed as a
/// top-level route, so it covers the tab bar and gets a back chevron free.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final user = ref.watch(authProvider).user ?? const <String, dynamic>{};
    final name = (user['name'] as String?) ?? '';
    final email = (user['email'] as String?) ?? '';
    final avatarUrl = user['avatar_url'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
        children: [
          Row(
            children: [
              RelayAvatar(
                key: const Key('account_avatar'),
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
                      key: const Key('account_name'),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    Text(
                      email,
                      key: const Key('account_email'),
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
          // SET-01's outlined destructive Log out, relocated here (divergence 2).
          OutlinedButton(
            key: const Key('account_log_out'),
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
