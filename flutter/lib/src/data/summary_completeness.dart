import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';

/// Daily Summary completeness (streak upgrade D11, Vera round-2
/// ruling with two BINDING conditions; design SIGNED round 3).
///
/// A Tabs day's Daily Summary is complete iff ALL of:
/// (a) the day's plan is RESOLVED — actually loaded, not a default
///     (Vera condition 1: an unresolved plan can never read as
///     `plannedCount == 0` complete; a not-yet-loaded plan and an
///     empty plan must not be the same value on this path, or a
///     completion fires on absent data — a fabricated counted day);
/// (b) the plan has nothing remaining: `plannedCount == 0` OR
///     `remainingCount == 0` under the EXISTING evidence rules
///     (the subtitle rule, not the progress-bar rule — a SKIPPED
///     dose does NOT resolve `remainingCount`);
/// (c) the 1–5 feeling check-in exists for that feeling day
///     ([hasFeelingCheckIn]).
///
/// Evidence window = the feeling day [04:00, +24h); the plan is
/// the plan of the calendar date the feeling day starts on.
///
/// Firing (the watcher below) is OPEN-DAY ONLY (Vera condition 2 /
/// A8): re-evaluation happens on check-in commit, log-entry commit,
/// Home load, and app resume, but [SummaryCompletionWatcher] only
/// ever fires [StreakStore.recordSummaryComplete] for the
/// currently open feeling day, exactly once per feeling day.
/// Evidence backfilled into a closed day's window after the 04:00
/// close never retro-fires it.

/// The composed completeness test. [plan] is the feeling day's
/// plan (see [buildPlanForFeelingDay]); [planResolved] is the
/// caller's attestation that the plan was actually loaded for
/// that day — pass false whenever the plan is a default, a cache
/// placeholder for another day, or not yet loaded, and completion
/// can never fire (Vera condition 1).
bool isSummaryComplete({
  required DateTime feelingDayStart,
  required TodayPlanData? plan,
  required bool planResolved,
  required List<QuickLogEntry> entries,
  required int? moodCategoryId,
}) {
  if (!planResolved || plan == null) return false;
  if (moodCategoryId == null) return false;
  if (!(plan.plannedCount == 0 || plan.remainingCount == 0)) {
    return false;
  }
  // hasFeelingCheckIn derives its window from feelingDayStart(now);
  // a moment safely inside the feeling day names the same window.
  return hasFeelingCheckIn(
    entries,
    moodCategoryId: moodCategoryId,
    now: feelingDayStart.add(const Duration(hours: 2)),
  );
}

/// Builds the feeling day's plan via the existing [buildTodayPlan]
/// with the D11 window semantics: evidence is restricted to the
/// feeling-day window [04:00, +24h) FIRST, and the plan date is
/// the calendar date the feeling day starts on.
///
/// [buildTodayPlan] filters evidence by calendar date, so an
/// entry logged at 01:00 on the NEXT calendar date (still inside
/// the feeling window) would be dropped by it, and an entry at
/// 01:00 on the plan date (BEFORE the window opened) would be
/// kept. The window pre-filter fixes the second; for the first,
/// in-window entries whose calendar date is not the plan date are
/// re-stamped to the plan date's noon for the plan computation
/// ONLY (body/category/chips untouched; the caller's entries are
/// never mutated — new [QuickLogEntry] values are built). The
/// check-in test in [isSummaryComplete] always reads the ORIGINAL
/// entries, never these.
TodayPlanData buildPlanForFeelingDay({
  required DateTime feelingDayStart,
  required List<SummaryMedication> medications,
  required List<SummaryReminder> reminders,
  required List<HabitDto> habits,
  required TodayPlanLocalState localState,
  required List<QuickLogEntry> entries,
  required int? medicationCategoryId,
  int? goalsCategoryId,
}) {
  final planDate = DateTime(
    feelingDayStart.year,
    feelingDayStart.month,
    feelingDayStart.day,
  );
  final planDateStr = dateStrOf(planDate);
  final startMs = feelingDayStart.millisecondsSinceEpoch;
  final endMs = feelingDayStart
      .add(const Duration(days: 1))
      .millisecondsSinceEpoch;
  final noonMs = DateTime(
    planDate.year,
    planDate.month,
    planDate.day,
    12,
  ).millisecondsSinceEpoch;
  final windowEntries = <QuickLogEntry>[];
  for (final e in entries) {
    if (e.timestamp < startMs || e.timestamp >= endMs) continue;
    if (dateStrOf(DateTime.fromMillisecondsSinceEpoch(e.timestamp)) ==
        planDateStr) {
      windowEntries.add(e);
    } else {
      windowEntries.add(
        QuickLogEntry(
          id: e.id,
          categoryId: e.categoryId,
          body: e.body,
          chips: e.chips,
          manualText: e.manualText,
          timestamp: noonMs,
        ),
      );
    }
  }
  return buildTodayPlan(
    medications: medications,
    reminders: reminders,
    habits: habits,
    localState: localState,
    entries: windowEntries,
    medicationCategoryId: medicationCategoryId,
    goalsCategoryId: goalsCategoryId,
    now: DateTime(planDate.year, planDate.month, planDate.day, 12),
  );
}

/// The inputs one completeness re-evaluation needs, resolved by
/// the caller for the CURRENTLY OPEN feeling day (plan + entries
/// + category resolution are Home's data, not the watcher's).
class SummaryCompletionContext {
  final TodayPlanData? plan;
  final bool planResolved;
  final List<QuickLogEntry> entries;
  final int? moodCategoryId;

  const SummaryCompletionContext({
    required this.plan,
    required this.planResolved,
    required this.entries,
    required this.moodCategoryId,
  });
}

/// Fires the streak completion for a Daily Summary the moment it
/// becomes complete — exactly once per feeling day, open day only.
///
/// Callable from check-in commit, log-entry commit, Home load, and
/// app resume; every call is a cheap re-evaluation and only the
/// first one that finds the open day complete does anything. The
/// fired-day marker is a small LOCAL key (injectable for tests) —
/// never a server write. The completion itself goes through
/// [StreakStore.recordSummaryComplete], inheriting its
/// anti-fabrication rule: with no record anywhere and no
/// successful pull, nothing fires and no marker is written, so a
/// later call with a real record can still complete the day.
class SummaryCompletionWatcher {
  static const String firedDayStorageKey = 'summary_completion_fired_v1';

  final StreakStore store;

  /// The completion event the UI layer subscribes to for the
  /// celebration: a broadcast stream plus an optional callback,
  /// both fed exactly once per fired feeling day.
  final StreamController<StreakCompletionResult> _events =
      StreamController<StreakCompletionResult>.broadcast();
  Stream<StreakCompletionResult> get completions => _events.stream;
  final void Function(StreakCompletionResult result, StreakState state)?
  onCompletion;

  Future<String?> Function(String key) _readMarker = (key) =>
      const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _writeMarker = (key, value) =>
      const FlutterSecureStorage().write(key: key, value: value);

  bool _firing = false;
  String? _firedDayMemory;

  SummaryCompletionWatcher({StreakStore? store, this.onCompletion})
    : store = store ?? StreakStore.instance;

  @visibleForTesting
  void debugSetMarkerStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
  }) {
    _readMarker = read;
    _writeMarker = write;
  }

  @visibleForTesting
  void debugReset() {
    _firing = false;
    _firedDayMemory = null;
  }

  /// Re-evaluate the currently open feeling day and fire its
  /// completion if it just became complete. Returns true when
  /// THIS call fired. [context] must be resolved for the open
  /// feeling day of [now] (defaults to the wall clock); the
  /// streak-record inputs mirror [StreakStore.recordSummaryComplete]'s.
  Future<bool> maybeFireSummaryCompletion({
    required SummaryCompletionContext context,
    required bool pullSucceeded,
    required int? seedCurrent,
    required int? seedBest,
    required String? seedStateJson,
    int? seedPurchasedFreezes,
    StreakSyncPush? push,
    DateTime? now,
  }) async {
    if (_firing) return false;
    final at = now ?? DateTime.now();
    // Vera condition 2 / A8: ONLY the currently open feeling day
    // can fire. The day is derived from [at] here — never taken
    // from the context — so a context resolved for a closed day
    // (stale load, backfilled evidence) cannot retro-fire it.
    final openDayStart = feelingDayStart(at);
    final openDayStr = dateStrOf(openDayStart);

    final fired = _firedDayMemory ?? await _readMarker(firedDayStorageKey);
    if (fired == openDayStr) {
      _firedDayMemory = fired;
      return false;
    }

    if (!isSummaryComplete(
      feelingDayStart: openDayStart,
      plan: context.plan,
      planResolved: context.planResolved,
      entries: context.entries,
      moodCategoryId: context.moodCategoryId,
    )) {
      return false;
    }

    _firing = true;
    try {
      final outcome = await store.recordSummaryComplete(
        pullSucceeded: pullSucceeded,
        seedCurrent: seedCurrent,
        seedBest: seedBest,
        seedStateJson: seedStateJson,
        seedPurchasedFreezes: seedPurchasedFreezes,
        now: at,
        summaryDay: openDayStart,
        push: push,
      );
      final completion = outcome.completion;
      if (!outcome.state.seeded || completion == null) {
        // Anti-fabrication: no record anywhere and no successful
        // pull — nothing counted, and NO marker: a later call
        // with a real record must still be able to fire today.
        return false;
      }
      // Marker BEFORE the event: a re-entrant call from a
      // celebration listener can never double-fire the day.
      _firedDayMemory = openDayStr;
      try {
        await _writeMarker(firedDayStorageKey, openDayStr);
      } catch (_) {
        // The in-memory marker still holds for this session; the
        // next cold start re-evaluates, and recordSummaryComplete
        // is idempotent per day (the day is already counted), so
        // a re-fire can never double-count.
      }
      if (!_events.isClosed) _events.add(completion);
      onCompletion?.call(completion, outcome.state);
      return true;
    } finally {
      _firing = false;
    }
  }

  void dispose() {
    unawaited(_events.close());
  }
}
