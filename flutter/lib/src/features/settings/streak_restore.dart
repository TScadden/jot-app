import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/theme/lab_black_colors.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Developer Terminal "Restore Streak" (founder ask, Nov 19,
/// 2026, verbatim: a button that "will bring back whatever my
/// last day was as if I did complete that day").
///
/// Placement fence — identical to the SIM's: this entry renders
/// ONLY when the caller gates it on the signed-in account's
/// pulled `dev_access` flag (Tyson's account only — not other
/// admins, not any build flavor). Unlike the SIM this is a REAL
/// action: the caller's callback runs the restore through the
/// streak store's authoritative state path (adopt → revalidate →
/// restore → settle → profile push), marking the most recent
/// broken day as a normal completed day — never a freeze day, no
/// freeze consumed or granted. The widget itself is a dumb
/// surface: it holds no store/backend references and renders the
/// outcome the callback reports.
///
/// Feedback copy ruled by Juno (streak-bugs package, Nov 19,
/// 2026; JUNO-COPY.md §2 — ship exactly). The button label is the
/// founder's own name for the feature. The caption is plain
/// dev-facing description, outside Juno's ruled strings.
abstract final class StreakRestoreCopy {
  static const String buttonLabel = 'Restore Streak';

  /// Juno §2a template, exact: the restored day (YYYY-MM-DD) and
  /// the resulting current streak count filled in.
  static String restored(String date, int current) =>
      'Restored — $date marked complete. Streak is now $current.';

  /// Juno §2b, exact.
  static const String noBrokenDay = 'Nothing to restore — no broken day found.';

  static const String caption =
      'Dev only — marks your most recent missed day as completed and restores the streak it broke.';
}

/// The outcome of one restore tap, reported by the caller's
/// authoritative-path callback: the day restored (null = no
/// broken day, a safe no-op) and the recomputed counters.
class StreakRestoreOutcome {
  final String? restoredDay;
  final int current;
  final int best;

  const StreakRestoreOutcome({
    required this.restoredDay,
    required this.current,
    required this.best,
  });
}

class StreakRestoreEntry extends StatefulWidget {
  /// Runs the restore through the authoritative streak path and
  /// reports its outcome. Injected so the widget stays a pure
  /// surface (unit-testable without the store or backend).
  final Future<StreakRestoreOutcome> Function() onRestore;

  const StreakRestoreEntry({super.key, required this.onRestore});

  @override
  State<StreakRestoreEntry> createState() => _StreakRestoreEntryState();
}

class _StreakRestoreEntryState extends State<StreakRestoreEntry> {
  bool _busy = false;
  String? _feedback;

  Future<void> _tap() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final outcome = await widget.onRestore();
      if (!mounted) return;
      setState(() {
        _feedback = outcome.restoredDay != null
            ? StreakRestoreCopy.restored(outcome.restoredDay!, outcome.current)
            : StreakRestoreCopy.noBrokenDay;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _feedback = StreakRestoreCopy.noBrokenDay);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            key: const Key('streakRestoreButton'),
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: _busy ? null : () => unawaited(_tap()),
            child: const Text(StreakRestoreCopy.buttonLabel),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          StreakRestoreCopy.caption,
          key: Key('streakRestoreCaption'),
          style: TextStyle(fontSize: 12, color: LabBlackColors.textSecondary),
        ),
        if (_feedback != null) ...[
          const SizedBox(height: 8),
          Text(
            _feedback!,
            key: const Key('streakRestoreFeedback'),
            style: const TextStyle(
              fontSize: 13,
              color: LabBlackColors.textPrimary,
            ),
          ),
        ],
      ],
    );
  }
}
