import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/workout_sync_store.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Developer Terminal "Workout sync diagnostics" card (ROUND 3,
/// Nov 27, 2026).
///
/// Placement fence — identical to the GrantDiagnosticsCard's:
/// this card renders ONLY when the caller gates it on the
/// signed-in account's pulled `dev_access` flag (the
/// Developer Terminal's debug page).
///
/// Why it exists: workout sync shipped fail-closed and silent —
/// every gate/read/loop failure was swallowed by a catch-all, so
/// when the founder's production build imported zero workouts
/// there was no on-device surface that could say WHERE the run
/// died. The service now records a [WorkoutSyncRunRecord] on
/// every exit path; this card renders that record. COUNTS,
/// STAGES, AND CODES ONLY — no health values, no session
/// content, no exception messages ever appear here.
class WorkoutSyncDiagnosticsCard extends StatefulWidget {
  final WorkoutSyncStore? store;

  const WorkoutSyncDiagnosticsCard({super.key, this.store});

  WorkoutSyncStore get _store => store ?? WorkoutSyncStore.instance;

  @override
  State<WorkoutSyncDiagnosticsCard> createState() =>
      _WorkoutSyncDiagnosticsCardState();
}

class _WorkoutSyncDiagnosticsCardState
    extends State<WorkoutSyncDiagnosticsCard> {
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  /// Read-only surface: an unbound warm just loads the blob
  /// as-is so the last recorded run can render.
  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await widget._store.warmFromDisk();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _timeLine(String label, int? ms) {
    if (ms == null) return '$label: never';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '$label: $t';
  }

  @override
  Widget build(BuildContext context) {
    final store = widget._store;
    final run = store.lastRun;
    const style = TextStyle(color: NotelColors.textSecondary, fontSize: 13);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Workout sync diagnostics',
          style: TextStyle(
            color: NotelColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        if (run == null)
          const Text('Last run: no run recorded yet', style: style)
        else ...[
          Text(_timeLine('Last run', run.finishedAtMs), style: style),
          const SizedBox(height: 4),
          Text('Stage reached: ${run.stage}', style: style),
          const SizedBox(height: 4),
          Text('Grant verdict: ${run.grantVerdict}', style: style),
          const SizedBox(height: 4),
          Text(
            'Sessions read: ${run.sessionsRead?.toString() ?? 'unknown'}',
            style: style,
          ),
          const SizedBox(height: 4),
          Text('Entries created: ${run.entriesCreated}', style: style),
          const SizedBox(height: 4),
          Text('Entries adopted: ${run.entriesAdopted}', style: style),
          const SizedBox(height: 4),
          Text('Sessions skipped: ${run.sessionsSkipped}', style: style),
          const SizedBox(height: 4),
          Text('Partial read: ${run.readPartial ? 'yes' : 'no'}',
              style: style),
          const SizedBox(height: 4),
          Text('Abort code: ${run.abortCode ?? 'none'}', style: style),
        ],
        const SizedBox(height: 4),
        Text(_timeLine('Last synced', store.lastSyncMs), style: style),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _loading ? null : () => unawaited(_refresh()),
          child: Text(_loading ? 'Refreshing…' : 'Refresh'),
        ),
      ],
    );
  }
}
