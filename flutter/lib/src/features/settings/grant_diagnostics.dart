import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Developer Terminal "Grants diagnostics" card (Nov 20, 2026
/// grants fix).
///
/// Placement fence — identical to the Restore Streak entry's:
/// this card renders ONLY when the caller gates it on the
/// signed-in account's pulled `dev_access` flag.
///
/// Why it exists: gems and badges shipped with every failure on
/// the grant path swallowed by a catch-all — no log, no surface —
/// so when the on-device grant path died, the production gem
/// ledger sat at 0 rows for every user while the app looked fine.
/// This card is the visible surface that silence used to hide
/// behind: each service's loaded state, pending queue count,
/// granted count, and last recorded error, read live from the
/// services' diagnostics getters. The retry button flushes both
/// pending queues (the same retry the app-open sync runs) and
/// re-reads the state.
class GrantDiagnosticsCard extends StatefulWidget {
  final GemService? gemService;
  final BadgeService? badgeService;

  const GrantDiagnosticsCard({
    super.key,
    this.gemService,
    this.badgeService,
  });

  GemService get _gems => gemService ?? GemService.instance;
  BadgeService get _badges => badgeService ?? BadgeService.instance;

  @override
  State<GrantDiagnosticsCard> createState() => _GrantDiagnosticsCardState();
}

class _GrantDiagnosticsCardState extends State<GrantDiagnosticsCard> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget._gems.retryPending();
      await widget._badges.retryPending();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  String _line({
    required String label,
    required bool loaded,
    required bool recovered,
    required int pending,
    required String grantedLabel,
    required String? lastError,
  }) {
    final load = loaded ? 'loaded' : 'NOT loaded';
    final rec = recovered ? ', recovered from a wedged entry' : '';
    final err = lastError ?? 'none';
    return '$label: $load$rec · pending $pending · '
        '$grantedLabel · last error: $err';
  }

  @override
  Widget build(BuildContext context) {
    final gems = widget._gems;
    final badges = widget._badges;
    final style = TextStyle(color: NotelColors.textSecondary, fontSize: 13);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Grants diagnostics',
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _line(
            label: 'Gems',
            loaded: gems.diagLoaded,
            recovered: gems.diagRecoveredLoad,
            pending: gems.diagPendingCount,
            grantedLabel: 'granted ${gems.diagGrantedCount}',
            lastError: gems.diagLastError,
          ),
          style: style,
        ),
        const SizedBox(height: 4),
        Text(
          _line(
            label: 'Badges',
            loaded: badges.diagLoaded,
            recovered: badges.diagRecoveredLoad,
            pending: badges.diagPendingCount,
            grantedLabel:
                'paid ${badges.diagPaidCount} of ${badges.diagGrantedRungs} rungs',
            lastError: badges.diagLastError,
          ),
          style: style,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _retrying ? null : () => unawaited(_retry()),
          child: Text(_retrying ? 'Retrying…' : 'Retry pending grants'),
        ),
      ],
    );
  }
}
