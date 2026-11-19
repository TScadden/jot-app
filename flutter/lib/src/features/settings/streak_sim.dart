import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/features/home/streak_celebration_screen.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Developer Terminal SIM (streak upgrade deliverable 7; B2 + A10).
///
/// A10 GREP FENCE: this file must never reference the streak
/// store, the server backend, or any metrics-reporting API. The
/// preview is built from plain values passed in by the caller
/// (the current settled count and the nickname) and exists ONLY
/// in memory: a throwaway display state (settled count + 1, today
/// completed) is constructed here, the celebration screen opens
/// with it, and it is discarded. No persistence, no network, no
/// metrics — Vera verifies the fence and the A10 isolation test
/// snapshots storage + profile + the metrics sink around a full
/// SIM run.
///
/// Placement (founder ruling, Nov 18, 2026 — supersedes B2's
/// lab-flavor gate): the entry renders ONLY when the caller gates
/// it on the signed-in account's pulled `dev_access` flag
/// (Tyson's account only — not other admins, not any flavor).
class StreakSimEntry extends StatelessWidget {
  /// The current SETTLED streak count (a plain value read by the
  /// caller; the SIM itself reads nothing).
  final int currentCount;
  final String? nickname;
  final DateTime now;

  const StreakSimEntry({
    super.key,
    required this.currentCount,
    required this.nickname,
    required this.now,
  });

  /// The throwaway preview state: settled count + 1 with today
  /// completed, IN MEMORY ONLY.
  @visibleForTesting
  static StreakCelebrationData buildPreviewData({
    required int currentCount,
    required DateTime now,
  }) {
    final count = currentCount + 1;
    final today = tabsDayStr(now);
    final todayDate = DateTime.parse(today);
    final monday = todayDate.subtract(Duration(days: todayDate.weekday - 1));
    const labels = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
    final week =
        <({String label, bool counted, bool isToday, bool restored})>[];
    for (var i = 0; i < 7; i++) {
      final d = monday.add(Duration(days: i));
      week.add((
        label: labels[i],
        // Days up to and including today read as counted in the
        // preview week row; future days do not.
        counted: !d.isAfter(todayDate),
        isToday: streakDayStr(d) == today,
        // The SIM has no freeze data and invents none.
        restored: false,
      ));
    }
    return StreakCelebrationData(
      count: count,
      week: week,
      isMilestoneDay: isMilestone(count),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            key: const Key('streakSimPreviewButton'),
            style: ElevatedButton.styleFrom(
              backgroundColor: NotelColors.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final data = buildPreviewData(
                currentCount: currentCount,
                now: now,
              );
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => StreakCelebrationScreen(
                    data: data,
                    nickname: nickname,
                  ),
                ),
              );
            },
            // Juno §8 — verbatim.
            child: const Text('Preview celebration — streak +1 [SIM]'),
          ),
        ),
        const SizedBox(height: 8),
        // Juno §8 — the caption is part of the approval: the button
        // may not render without it. It is also the button's
        // accessibility label.
        Semantics(
          label: 'Simulation only. This does not change your real streak.',
          child: const Text(
            'Simulation only. This does not change your real streak.',
            key: Key('streakSimCaption'),
            style: TextStyle(
              fontSize: 12,
              color: LabBlackColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
