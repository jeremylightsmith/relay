import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';

/// SET-02 Log out confirm: a centered dialog over a scrim, copy exactly as
/// drawn — the notifications sentence is literally true now that signOut()
/// deregisters push. A filled destructive Log out above a secondary Cancel.
///
/// Navigation is not this dialog's job: signOut() lands AuthStatus.signedOut,
/// routerProvider's refreshListenable fires, and the redirect replaces the
/// whole stack with /welcome — that IS the artboard's `confirm → AUTH-01`.
Future<void> showLogoutConfirmDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Consumer(
      builder: (context, ref, _) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          key: const Key('logout_confirm'),
          title: const Text('Log out of Relay?', textAlign: TextAlign.center),
          content: const Text(
            "You'll stop receiving notifications until you sign back in.",
            textAlign: TextAlign.center,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          actions: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  key: const Key('logout_confirm_logout'),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    ref.read(authProvider.notifier).signOut();
                  },
                  child: const Text('Log out'),
                ),
                const SizedBox(height: 9),
                OutlinedButton(
                  key: const Key('logout_confirm_cancel'),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}
