import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Developer Terminal dev gems grant (DEV GEMS package, Nov 27,
/// 2026).
///
/// Placement fence — identical to the Restore Streak entry's and
/// the Grants diagnostics card's: this entry renders ONLY when
/// the caller gates it on the signed-in account's pulled
/// `dev_access` flag. That gate is a display convenience, NOT the
/// security: the grant itself is authorized server-side by
/// POST /api/gems/dev-grant, which credits exactly 1,000 gems
/// through the gem ledger (reason `dev_grant`) only for a dev
/// account and answers 403 — no credit, no ledger row — to any
/// other token.
///
/// The flow follows the other gem flows exactly: the call goes
/// through [GemService.devGrant] (the same service the pill and
/// the store read), and on success the service adopts the
/// returned server balance, so the gem pill and the store reflect
/// it immediately. On ANY failure (403, offline, server error)
/// nothing is adopted, the local balance stands untouched, and
/// the error is shown here, honestly.
///
/// The confirm dialog is deliberate (Juno copy ruling,
/// build-dev-gems/JUNO-RELEASE-NOTES.md §3): a tap here moves
/// real, spendable currency, and the button sits beside dev-area
/// test controls that are tapped casually. Every dialog string is
/// byte-exact from that ruling. Each confirmed tap generates a
/// fresh grantId, so repeated deliberate grants each land as
/// their own ledger entry; a replayed grantId is a server-side
/// replay, never a double grant.
///
/// This entry never touches the chest or store endpoints — the
/// dev-grant endpoint is the only network call on this path.
class DevGemsEntry extends StatefulWidget {
  final GemService? gemService;

  const DevGemsEntry({super.key, this.gemService});

  GemService get _gems => gemService ?? GemService.instance;

  @override
  State<DevGemsEntry> createState() => _DevGemsEntryState();
}

class _DevGemsEntryState extends State<DevGemsEntry> {
  bool _granting = false;
  String? _status;
  bool _statusIsError = false;

  Future<void> _onTap() async {
    if (_granting) return;
    // Juno ruling (JUNO-RELEASE-NOTES.md §3) — byte-exact strings.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Grant 1,000 gems?'),
        content: const Text(
          'This adds 1,000 real, spendable gems to your account. '
          'The grant is logged as a dev grant.',
        ),
        actions: [
          TextButton(
            key: const Key('devGemsCancelButton'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('devGemsConfirmButton'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Grant gems'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _granting = true;
      _status = null;
      _statusIsError = false;
    });
    final result = await widget._gems.devGrant();
    if (!mounted) return;
    setState(() {
      _granting = false;
      switch (result.status) {
        case GemDevGrantStatus.success:
        case GemDevGrantStatus.replay:
          final balance = result.balance ?? widget._gems.balance;
          _status = balance == null
              ? 'Granted 1,000 gems.'
              : 'Granted 1,000 gems. New balance: $balance gems.';
          _statusIsError = false;
        case GemDevGrantStatus.forbidden:
          _status = 'The server refused this grant (403): this '
              'account is not a dev account. Nothing was granted.';
          _statusIsError = true;
        case GemDevGrantStatus.failed:
          _status = 'Grant failed. Nothing was granted — check '
              'your connection and try again.';
          _statusIsError = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            key: const Key('devGemsGrantButton'),
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: _granting ? null : () => unawaited(_onTap()),
            // The label is byte-exact in every state (Juno ruling).
            child: const Text('Grant 1,000 gems (dev)'),
          ),
        ),
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(
            _status!,
            key: const Key('devGemsStatus'),
            style: TextStyle(
              color: _statusIsError
                  ? Colors.redAccent
                  : NotelColors.textPrimary,
              fontSize: 13,
            ),
          ),
        ],
      ],
    );
  }
}
