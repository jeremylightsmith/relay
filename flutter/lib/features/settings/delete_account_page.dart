import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../app/messenger.dart';
import '../auth/apple_credential.dart';
import '../auth/auth_controller.dart';
import 'account_deletion.dart';
import 'owner_picker_sheet.dart';

/// The one word that confirms — matched exactly: no trim, no case folding.
const _confirmWord = 'DELETE';

const _loadErrorText = "Couldn't load. Check your connection and try again.";
const _deleteErrorText =
    "Couldn't delete your account. Check your connection and try again. "
    'Nothing was deleted.';

/// RE509 · SET-03: the pushed "Delete account" confirm page.
///
/// It loads the server's preview every time it opens, lists the boards that
/// change hands (each with a new-owner chip opening SET-03a) and what is
/// deleted with the account, and enables the red button only once the field
/// reads exactly `DELETE`. Apple accounts re-authorize with Apple first, for a
/// fresh authorization code the server revokes with; cancelling that sheet is
/// a quiet no-op.
///
/// On success it toasts through the app-level messenger — so the toast
/// outlives this page — and signs out locally. Navigation is not its job: the
/// auth-gated router redirects to Welcome on `signedOut`.
class DeleteAccountPage extends ConsumerStatefulWidget {
  const DeleteAccountPage({super.key});

  @override
  ConsumerState<DeleteAccountPage> createState() => _DeleteAccountPageState();
}

class _DeleteAccountPageState extends ConsumerState<DeleteAccountPage> {
  final _confirm = TextEditingController();

  DeletionPreview? _preview;
  bool _loadFailed = false;

  /// Each shared board's chosen new owner, by slug.
  Map<String, int> _owners = const {};

  bool _busy = false;
  bool _deleteFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _preview = null;
      _loadFailed = false;
    });
    try {
      final preview = await ref
          .read(accountDeletionRepositoryProvider)
          .fetchPreview();
      if (!mounted) return;
      _show(preview);
    } catch (e) {
      debugPrint('[delete-account] preview failed: $e');
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  /// Shows [preview], each board's owner back on its default: the candidate
  /// who has been on it longest (the server lists them oldest first).
  void _show(DeletionPreview preview) {
    setState(() {
      _preview = preview;
      _owners = {
        for (final board in preview.sharedBoards)
          if (board.candidates.isNotEmpty)
            board.slug: board.candidates.first.userId,
      };
    });
  }

  bool get _canSubmit => !_busy && _confirm.text == _confirmWord;

  Future<void> _pickOwner(SharedBoard board) async {
    final picked = await showOwnerPickerSheet(
      context,
      board: board,
      selectedUserId: _owners[board.slug] ?? board.candidates.first.userId,
    );
    if (picked == null || !mounted) return;
    setState(() => _owners = {..._owners, board.slug: picked.userId});
  }

  Future<void> _submit() async {
    final preview = _preview!;
    // Read up front: the user can still pop this page (back button, swipe)
    // while the request is in flight, and `ref` is unusable once it's
    // disposed. A deletion the server made must still sign out.
    final messenger = ref.read(scaffoldMessengerKeyProvider);
    final auth = ref.read(authProvider.notifier);
    final repo = ref.read(accountDeletionRepositoryProvider);
    setState(() {
      _deleteFailed = false;
      _busy = true;
    });

    String? appleCode;
    if (preview.appleReauthRequired) {
      try {
        final credential = await ref.read(appleCredentialRequestProvider)(
          sha256Hex(generateRawNonce()),
        );
        appleCode = credential.authorizationCode;
      } on SignInWithAppleAuthorizationException catch (e) {
        if (e.code == AuthorizationErrorCode.canceled) {
          // Backing out of Apple's sheet changes nothing — no error to show.
          if (mounted) setState(() => _busy = false);
          return;
        }
        debugPrint('[delete-account] Apple re-auth failed: $e');
        return _fail();
      } catch (e) {
        debugPrint('[delete-account] Apple re-auth failed: $e');
        return _fail();
      }
      // The plugin types the code as non-null; "no code" arrives empty.
      if (appleCode.isEmpty) return _fail();
    }

    final result = await repo.deleteAccount(
      transfers: Map.of(_owners),
      appleAuthorizationCode: appleCode,
    );

    switch (result) {
      case DeleteAccountDeleted():
        // Mounted or not. Toast before signing out: the app-level messenger
        // holds it until Welcome's Scaffold appears, after this page is gone.
        showToast(
          messenger,
          'Your account was deleted.',
          key: const Key('account_deleted_toast'),
        );
        await auth.signOutDeletedAccount();
      case DeleteAccountInvalidTransfers():
        if (!mounted) return;
        // The boards or their members moved since the preview: show the
        // fresh one, owners re-defaulted, then the error.
        try {
          final fresh = await repo.fetchPreview();
          if (mounted) _show(fresh);
        } catch (e) {
          debugPrint('[delete-account] preview refetch failed: $e');
        }
        _fail();
      case DeleteAccountFailed():
        _fail();
    }
  }

  void _fail() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _deleteFailed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      key: const Key('delete_account_page'),
      appBar: AppBar(title: const Text('Delete account')),
      body: preview != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _content(context, preview)),
                _BottomBar(
                  busy: _busy,
                  onSubmit: _canSubmit ? _submit : null,
                  onCancel: _busy ? null : () => Navigator.maybePop(context),
                ),
              ],
            )
          : _loadFailed
          ? _LoadError(onRetry: _load)
          : const Center(
              key: Key('delete_account_loading'),
              child: CircularProgressIndicator(),
            ),
    );
  }

  Widget _content(BuildContext context, DeletionPreview preview) {
    final scheme = Theme.of(context).colorScheme;
    final deletedLines = [
      for (final board in preview.soloBoards)
        _Consequence(
          key: Key('delete_account_solo_${board.slug}'),
          glyph: '✕',
          glyphColor: scheme.error,
          text: TextSpan(
            children: [
              TextSpan(
                text: board.name,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const TextSpan(text: ': only you use it'),
            ],
          ),
        ),
      if (preview.planEnds)
        _Consequence(
          key: const Key('delete_account_plan'),
          glyph: '✕',
          glyphColor: scheme.error,
          text: const TextSpan(
            text: "Your Pro plan ends now and won't be refunded",
          ),
        ),
      if (preview.runners.isNotEmpty)
        _Consequence(
          key: const Key('delete_account_runners'),
          glyph: '✕',
          glyphColor: scheme.error,
          text: _runnersSpan(preview.runners),
        ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'This permanently deletes your Hamaca account.',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "It happens right away and can't be undone.",
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          if (preview.sharedBoards.isNotEmpty)
            _Handoffs(
              boards: preview.sharedBoards,
              owners: _owners,
              onPick: _busy ? null : _pickOwner,
            ),
          if (deletedLines.isNotEmpty)
            const _SectionHeader('DELETED WITH YOUR ACCOUNT')
          else
            const SizedBox(height: 16),
          for (final line in deletedLines) ...[line, const SizedBox(height: 6)],
          _Consequence(
            key: const Key('delete_account_kept'),
            glyph: '•',
            glyphColor: scheme.onSurfaceVariant,
            text: TextSpan(
              text: 'Your comments and votes stay, shown as "Deleted user"',
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.7)),
            ),
          ),
          const SizedBox(height: 16),
          Text.rich(
            const TextSpan(
              children: [
                TextSpan(text: 'Type '),
                TextSpan(
                  text: _confirmWord,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextSpan(text: ' to confirm'),
              ],
            ),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('delete_account_confirm_field'),
            controller: _confirm,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            // Only a typing aid — the match itself stays exact.
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: _confirmWord,
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (preview.appleReauthRequired) ...[
            const SizedBox(height: 12),
            Text(
              'Next, Apple asks you to sign in once more so we can disconnect '
              'Hamaca from your Apple ID.',
              key: const Key('delete_account_apple_note'),
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ],
          if (_deleteFailed) ...[
            const SizedBox(height: 12),
            const _ErrorAlert(),
          ],
        ],
      ),
    );
  }

  /// [runnersLine], its names part set in monospace.
  TextSpan _runnersSpan(List<String> names) {
    final line = runnersLine(names);
    final split = line.length - names.join(', ').length;
    return TextSpan(
      children: [
        TextSpan(text: line.substring(0, split)),
        TextSpan(
          text: line.substring(split),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
        ),
      ],
    );
  }
}

/// A mono uppercase section header: 16 above, 6 below.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontFamily: 'monospace',
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// BOARDS YOU'LL HAND OFF: the outlined card of boards, each with its owner
/// chip, then the footnote.
class _Handoffs extends StatelessWidget {
  const _Handoffs({
    required this.boards,
    required this.owners,
    required this.onPick,
  });

  final List<SharedBoard> boards;
  final Map<String, int> owners;

  /// Null while the page is busy: the chips are locked.
  final void Function(SharedBoard)? onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (final board in boards) {
      if (rows.isNotEmpty) {
        rows.add(
          Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
        );
      }
      rows.add(
        _HandoffRow(board: board, ownerId: owners[board.slug], onPick: onPick),
      );
    }
    return Column(
      key: const Key('delete_account_handoffs'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader("BOARDS YOU'LL HAND OFF"),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'They become the owner and pay for the board from now on.',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _HandoffRow extends StatelessWidget {
  const _HandoffRow({
    required this.board,
    required this.ownerId,
    required this.onPick,
  });

  final SharedBoard board;
  final int? ownerId;
  final void Function(SharedBoard)? onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final owner = board.candidates
        .where((c) => c.userId == ownerId)
        .firstOrNull;
    final pick = onPick;
    return Padding(
      key: Key('delete_account_handoff_${board.slug}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  board.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                Text(
                  '${board.memberCount} members',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (owner != null) ...[
            const SizedBox(width: 8),
            _OwnerChip(
              key: Key('delete_account_owner_${board.slug}'),
              owner: owner,
              onTap: pick == null ? null : () => pick(board),
            ),
          ],
        ],
      ),
    );
  }
}

/// The current new owner, tappable to open the picker.
class _OwnerChip extends StatelessWidget {
  const _OwnerChip({super.key, required this.owner, required this.onTap});

  final OwnerCandidate owner;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(8);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CandidateAvatar(candidate: owner, size: 20, fontSize: 9),
              const SizedBox(width: 6),
              Text(
                candidateLabel(owner),
                style: TextStyle(fontSize: 12, color: scheme.onSurface),
              ),
              const SizedBox(width: 4),
              Text('▾', style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One consequence: a glyph, then its sentence (13 px).
class _Consequence extends StatelessWidget {
  const _Consequence({
    super.key,
    required this.glyph,
    required this.glyphColor,
    required this.text,
  });

  final String glyph;
  final Color glyphColor;
  final InlineSpan text;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      color: Theme.of(context).colorScheme.onSurface,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: Text(glyph, style: style.copyWith(color: glyphColor)),
        ),
        Expanded(child: Text.rich(text, style: style)),
      ],
    );
  }
}

/// SET-03b: the inline failure, at the end of the scroll content.
class _ErrorAlert extends StatelessWidget {
  const _ErrorAlert();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('delete_account_error'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _deleteErrorText,
        style: TextStyle(fontSize: 12, color: scheme.error),
      ),
    );
  }
}

/// The preview didn't load: say so, and offer to try again.
class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      key: const Key('delete_account_load_error'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _loadErrorText,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// The pinned bar: the red Delete account button over Cancel.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.busy,
    required this.onSubmit,
    required this.onCancel,
  });

  final bool busy;
  final VoidCallback? onSubmit;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 24),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const Key('delete_account_submit'),
                // Enabled colors only: disabled keeps the Material defaults.
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  shape: shape,
                ),
                onPressed: onSubmit,
                child: busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          key: Key('delete_account_spinner'),
                          strokeWidth: 2,
                        ),
                      )
                    : const Text('Delete account'),
              ),
              const SizedBox(height: 4),
              TextButton(
                key: const Key('delete_account_cancel'),
                style: TextButton.styleFrom(shape: shape),
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
