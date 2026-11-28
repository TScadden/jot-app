import 'dart:async';
import 'dart:convert';

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
///     `remainingCount == 0` under the ONE resolved definition
///     ([todayPlanItemResolved] — founder ruling, Nov 25, 2026:
///     a deliberately SKIPPED dose resolves its item for
///     completion counting, so it DOES resolve `remainingCount`.
///     This supersedes the pre-ruling subtitle rule, under which
///     a skipped dose left the count at 1 while the rendered plan
///     and the progress bar already read complete. Per-item
///     records are unchanged: a skipped dose still reads skipped,
///     never taken, in adherence/medication views);
/// (c) the 1–5 feeling check-in exists for that feeling day
///     ([hasFeelingCheckIn]).
///
/// Evidence window = the feeling day [feelingDayStart, +24h)
/// (the feeling day's start is the shared Tabs-day definition in
/// tabs_day.dart — 04:00 local under the legacy rule, midnight
/// from the persisted cutover on); the plan is the plan of the
/// calendar date the feeling day starts on.
///
/// Firing (the watcher below) is OPEN-DAY ONLY (Vera condition 2 /
/// A8): re-evaluation happens on check-in commit, log-entry commit,
/// Home load, and app resume, but [SummaryCompletionWatcher] only
/// ever fires [StreakStore.recordSummaryComplete] for the
/// currently open feeling day, exactly once per feeling day.
/// Evidence backfilled into a closed day's window after the
/// feeling day closes never retro-fires it.

/// Authoritative plan attestation (P0 fix, Defect A2 — Vera D11
/// condition 1 in substance). The pre-fix Home attested
/// planResolved as `profile != null`: a profile payload ARRIVING
/// proved nothing about whether the plan reflected the day's real
/// obligations — a payload whose medications/reminders fields were
/// absent or undecodable decoded to empty lists, read
/// plannedCount == 0, and fired on the check-in alone.
///
/// This value attests the plan's INPUTS individually, at the
/// decode layer: each flag is true only when that input was
/// actually loaded — for profile fields, the field is PRESENT in
/// the payload and decodable as a list (possibly empty); for
/// habits, the fetch actually answered (fetchHabitsOrNull non-
/// null). A genuinely plan-free account (every input loaded, all
/// empty) attests fully resolved and can still complete on the
/// check-in alone — Vera's protected case.
class PlanAttestation {
  final bool medicationsResolved;
  final bool remindersResolved;
  final bool habitsResolved;

  const PlanAttestation({
    required this.medicationsResolved,
    required this.remindersResolved,
    required this.habitsResolved,
  });

  /// Nothing attested — the state whenever any part of the plan's
  /// inputs failed to load.
  const PlanAttestation.unresolved()
      : medicationsResolved = false,
        remindersResolved = false,
        habitsResolved = false;

  bool get resolved =>
      medicationsResolved && remindersResolved && habitsResolved;

  @override
  bool operator ==(Object other) =>
      other is PlanAttestation &&
      other.medicationsResolved == medicationsResolved &&
      other.remindersResolved == remindersResolved &&
      other.habitsResolved == habitsResolved;

  @override
  int get hashCode =>
      Object.hash(medicationsResolved, remindersResolved, habitsResolved);
}

/// Whether one profile list field (e.g. `medications`) is PRESENT
/// in [profile] and decodable as a list — the decode-layer
/// distinction between "field absent / payload partial" (false)
/// and "field present, decoded, possibly empty" (true). Mirrors
/// TabsBackend.decodeProfileList's tolerance (JSON string,
/// double-encoded string, already-decoded List/Map) but reports
/// decodability instead of collapsing every failure to [].
bool profileListFieldResolved(Map<String, dynamic> profile, String key) {
  if (!profile.containsKey(key)) return false;
  final raw = profile[key];
  if (raw == null) return false;
  if (raw is List || raw is Map) return true;
  if (raw is String) {
    if (raw.trim().isEmpty) return false;
    try {
      var decoded = jsonDecode(raw);
      var guard = 0;
      while (decoded is String && decoded.trim().isNotEmpty && guard < 3) {
        guard++;
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {
          break;
        }
      }
      return decoded is List || decoded is Map;
    } catch (_) {
      return false;
    }
  }
  return false;
}

/// A feeling day's plan together with the attestation of its
/// inputs: the plan VALUE carries its resolved-ness (P0 fix) — no
/// side boolean attested by proxy can drift from the plan it
/// describes.
class AttestedPlan {
  final TodayPlanData plan;
  final PlanAttestation attestation;

  const AttestedPlan({required this.plan, required this.attestation});

  bool get resolved => attestation.resolved;
}

/// The composed completeness test. [attestedPlan] is the feeling
/// day's plan (see [buildPlanForFeelingDay]) WITH its input
/// attestation; an unattested or partially-attested plan can
/// never complete (Vera condition 1).
bool isSummaryComplete({
  required DateTime feelingDayStart,
  required AttestedPlan? attestedPlan,
  required List<QuickLogEntry> entries,
  required String? moodCategoryId,
  DateTime? evidenceWindowEnd,
}) {
  if (attestedPlan == null || !attestedPlan.resolved) return false;
  final plan = attestedPlan.plan;
  if (moodCategoryId == null) return false;
  if (!(plan.plannedCount == 0 || plan.remainingCount == 0)) {
    return false;
  }
  // hasFeelingCheckIn derives its window from feelingDayStart(now);
  // a moment safely inside the feeling day names the same window.
  // [evidenceWindowEnd] is the Midnight Grace override: while grace
  // runs, the closing day's evidence window extends to the grace
  // deadline, so a check-in logged inside the window counts for the
  // closing day. Null (every non-grace evaluation) = +24h, exactly
  // the shipped rule.
  return hasFeelingCheckIn(
    entries,
    moodCategoryId: moodCategoryId,
    now: feelingDayStart.add(const Duration(hours: 2)),
    windowEnd: evidenceWindowEnd,
  );
}

/// Builds the feeling day's plan via the existing [buildTodayPlan]
/// with the D11 window semantics: evidence is restricted to the
/// feeling-day window [feelingDayStart, +24h) FIRST, and the plan date is
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
  required String? medicationCategoryId,
  String? goalsCategoryId,
  DateTime? evidenceWindowEnd,
}) {
  final planDate = DateTime(
    feelingDayStart.year,
    feelingDayStart.month,
    feelingDayStart.day,
  );
  final planDateStr = dateStrOf(planDate);
  final startMs = feelingDayStart.millisecondsSinceEpoch;
  // Midnight Grace: [evidenceWindowEnd] extends the evidence window
  // to the grace deadline (entries logged inside grace, whose
  // calendar date is the NEXT day, are re-stamped to the plan
  // date's noon below — computation only, entries never mutated).
  // Null = the shipped [feelingDayStart, +24h) window.
  final endMs = (evidenceWindowEnd ??
          feelingDayStart.add(const Duration(days: 1)))
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
  final AttestedPlan? attestedPlan;
  final List<QuickLogEntry> entries;
  final String? moodCategoryId;

  const SummaryCompletionContext({
    required this.attestedPlan,
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
  ///
  /// Midnight Grace (Nov 21, 2026): while a grace window is active,
  /// Home passes [fireableDayStartOverride] = the CLOSING day's
  /// start and [evidenceWindowEnd] = the grace deadline. The
  /// fireable day is then the closing day — the one exception to
  /// the A8 open-day rule, bounded by the live window: Home only
  /// passes the override while MidnightGraceController reports an
  /// active window, and the completeness test only credits
  /// evidence inside [closing start, deadline). Both default null,
  /// which is byte-identical to the shipped A8 behavior.
  ///
  /// Vera C2 (binding): [graceStillActive] is the liveness probe
  /// for that window, consulted at the fire point below. The
  /// caller resolves its inputs across awaits, and the window can
  /// end (expiry, backgrounding, any reason) while resolution is
  /// in flight; a fire that lands after the window ended would
  /// create a completion after the window, which the founder spec
  /// forbids. When the probe reports the window gone, this call
  /// fires nothing and writes NO fired-day marker — the day simply
  /// settles through the normal post-window paths. Null (every
  /// non-grace call) = no probe, shipped behavior.
  Future<bool> maybeFireSummaryCompletion({
    required SummaryCompletionContext context,
    required bool pullSucceeded,
    required int? seedCurrent,
    required int? seedBest,
    required String? seedStateJson,
    int? seedPurchasedFreezes,
    StreakSyncPush? push,
    DateTime? now,
    DateTime? fireableDayStartOverride,
    DateTime? evidenceWindowEnd,
    bool Function()? graceStillActive,
  }) async {
    if (_firing) return false;
    final at = now ?? DateTime.now();
    // Vera condition 2 / A8: ONLY the currently open feeling day
    // can fire. The day is derived from [at] here — never taken
    // from the context — so a context resolved for a closed day
    // (stale load, backfilled evidence) cannot retro-fire it.
    // Midnight Grace: the override substitutes the closing day
    // while its window is live (see the doc above).
    final openDayStart = fireableDayStartOverride ?? feelingDayStart(at);
    final openDayStr = dateStrOf(openDayStart);

    final fired = _firedDayMemory ?? await _readMarker(firedDayStorageKey);
    if (fired == openDayStr) {
      _firedDayMemory = fired;
      return false;
    }

    if (!isSummaryComplete(
      feelingDayStart: openDayStart,
      attestedPlan: context.attestedPlan,
      entries: context.entries,
      moodCategoryId: context.moodCategoryId,
      evidenceWindowEnd: evidenceWindowEnd,
    )) {
      return false;
    }

    // Vera C2: the last-moment liveness check — the grace window
    // this fire was evaluated under must still be live NOW, at
    // the fire point. A window that ended during the caller's
    // input resolution (or during the marker read above) refuses
    // the fire entirely: no counted day, no marker.
    if (graceStillActive != null && !graceStillActive()) {
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
        // Midnight Grace no-gems (Nov 21, 2026): a fire that ran
        // under the grace overrides (the closing day substituted
        // for the open day, liveness-probed above) marks the day
        // grace-completed — the streak counts, the gems do not
        // pay. Every non-grace fire passes no override → false →
        // byte-identical shipped behavior.
        viaGrace: fireableDayStartOverride != null,
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

// ── Bounded re-settlement (skip-counts-complete, Nov 25, 2026) ─────
//
// The founder ruling above changed the completion PREDICATE: a day
// that was skip-only-incomplete under the taken-only rule (the
// founder's own Nov 25: every item resolved, one dose deliberately
// skipped, check-in recorded) can be complete under the resolved
// rule. The watcher is open-day-only BY DESIGN (Vera condition 2),
// so it can never heal such a day after it closes. This service is
// the ONE bounded exception, scoped by the coordinator's design
// (Nov 25, 2026) to exactly the predicate-version transition:
//
// - It runs only while the stored predicate-version marker is
//   behind [SummaryResettlement.currentPredicateVersion]; a
//   definitive scan advances the marker and it never runs again.
//   An INDEFINITIVE scan (plan unattested, no record anywhere)
//   does NOT advance the marker — the one shot is not burned by a
//   transient load failure; the next app start retries. The
//   marker is consulted only when a candidate gap actually
//   exists: launches with no settled-but-uncounted day return
//   from an in-memory derivation before any storage read, so the
//   hook is free on the settlement path it precedes.
// - The scan covers ONLY settled-but-uncounted days in the
//   streak-threatening class: the contiguous closed Tabs days
//   strictly after the last counted day and strictly before
//   today, oldest first. It stops at the first day that still
//   fails [isSummaryComplete] — completing a later day across a
//   failed one would need settlement's freeze bridge, which this
//   heal must never trigger (see the freeze guard). Counted-but-
//   not-summary days are OUT of scope by coordinator ruling
//   (rebuilding their plans from today's medication list is
//   unsound) and are never touched.
// - Each passing day completes through the NORMAL store path
//   ([StreakStore.recordSummaryComplete] — adoption,
//   anti-fabrication, blob push and all) called DIRECTLY, never
//   through [SummaryCompletionWatcher]: no completion event is
//   emitted and no celebration is held for a re-settled past day,
//   ever. The caller's [onResettled] hook exists for the gem
//   claim chain only (push-then-claim, exactly Home's completion
//   chain minus the celebration).
// - Freeze guard (binding): a candidate is completed only when it
//   is exactly the day after the evolving record's last counted
//   day (adjacency), AND a pure [completeDay] preview on that
//   record leaves `consumedSaveMonths`, `spoiledMonths`, and
//   `restoredDays` byte-identical. Adjacency makes settlement's
//   gap bridging unreachable (it runs only on a gap > 1); the
//   preview proves it on the actual record before any store call.
//   A day that fails the guard is reported via
//   [SummaryResettlementOutcome.freezeGuardBlockedDay] and the
//   scan stops — it never improvises around the guard.
// - It never un-counts: after each completion the outcome is
//   verified to still contain every previously counted day plus
//   the healed day in both `countedDays` and
//   `summaryCompletedDays`; a violation stops the scan and is
//   reported the same way.
// - Idempotent: the version marker makes the scan one-shot, and
//   every completion goes through the per-day-idempotent store
//   path — running the scan twice changes nothing the second
//   time (pinned by test).

/// One day healed by [SummaryResettlement]: its ISO Tabs day, the
/// completion result the store path produced, and the settled
/// state after it.
class ResettledDay {
  final String day;
  final StreakCompletionResult result;
  final StreakState state;

  const ResettledDay({
    required this.day,
    required this.result,
    required this.state,
  });
}

/// The outcome of one [SummaryResettlement.maybeResettle] call.
class SummaryResettlementOutcome {
  /// Days healed by this call, oldest first.
  final List<ResettledDay> resettled;

  /// True when the predicate-version marker stands at (or was
  /// advanced to) the current version by this call — the scan
  /// will not run again.
  final bool markerAdvanced;

  /// True when the scan could not reach a definitive evaluation
  /// (unattested plan, or no record anywhere under the store's
  /// anti-fabrication rule). The marker was NOT advanced; a later
  /// app start retries. Days in [resettled] still stand.
  final bool deferred;

  /// The day the freeze / never-un-count guard stopped the scan
  /// on, when it did. The marker was NOT advanced.
  final String? guardBlockedDay;

  const SummaryResettlementOutcome({
    required this.resettled,
    required this.markerAdvanced,
    this.deferred = false,
    this.guardBlockedDay,
  });
}

String _nextTabsDay(String day) {
  final d = DateTime.parse(day);
  final u = DateTime.utc(d.year, d.month, d.day).add(const Duration(days: 1));
  return streakDayStr(u);
}

class SummaryResettlement {
  /// Storage key for the completion-predicate version marker.
  static const String predicateVersionStorageKey =
      'completion_predicate_version_v1';

  /// Predicate versions: 1 = the pre-ruling taken-only rule (never
  /// written explicitly — absence means 1); 2 = the Nov 25, 2026
  /// resolved rule ([todayPlanItemResolved]).
  static const int currentPredicateVersion = 2;

  final StreakStore store;

  Future<String?> Function(String key) _readVersion = (key) =>
      const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _writeVersion =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);

  bool _running = false;

  SummaryResettlement({StreakStore? store})
      : store = store ?? StreakStore.instance;

  @visibleForTesting
  void debugSetVersionStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
  }) {
    _readVersion = read;
    _writeVersion = write;
  }

  Future<void> _advanceMarker() async {
    try {
      await _writeVersion(
        predicateVersionStorageKey,
        '$currentPredicateVersion',
      ).timeout(const Duration(seconds: 2), onTimeout: () {});
    } catch (_) {
      // Best-effort: the per-day completions are idempotent, so a
      // re-run after a failed marker write re-evaluates healed
      // days as already counted (they are no longer candidates)
      // and changes nothing.
    }
  }

  /// Run the bounded scan once, if the predicate-version marker
  /// says it has not definitively run. See the section doc above
  /// for the full contract. [recordState] is the caller's best
  /// view of the authoritative record (the pulled streak blob,
  /// parsed) — candidate derivation unions it with the store's
  /// loaded local record. [resolveContext] resolves one past
  /// day's completeness inputs exactly as Home resolves the open
  /// day's (same attestation discipline). The streak-record seeds
  /// and [push] mirror [StreakStore.recordSummaryComplete]'s.
  /// [onResettled] (the gem claim hook) runs after each healed
  /// day's store completion; its failures are swallowed — a claim
  /// failure queues/retryably refuses server-side and never
  /// un-heals the day.
  Future<SummaryResettlementOutcome> maybeResettle({
    required StreakState? recordState,
    required DateTime now,
    required Future<SummaryCompletionContext?> Function(DateTime dayStart)
        resolveContext,
    required bool pullSucceeded,
    required int? seedCurrent,
    required int? seedBest,
    required String? seedStateJson,
    int? seedPurchasedFreezes,
    StreakSyncPush? push,
    Future<void> Function(ResettledDay day)? onResettled,
  }) async {
    if (_running) {
      return const SummaryResettlementOutcome(
        resettled: [],
        markerAdvanced: false,
        deferred: true,
      );
    }

    _running = true;
    try {
      await store.ensureLoaded();
      final local = store.state;
      // The evolving preview record: the union view of the pulled
      // blob and the local record (the same union the store's
      // adoption merge would produce for the day sets).
      StreakState? evolving;
      if (recordState != null && local != null) {
        evolving = recordState.copyWith(
          countedDays: {...recordState.countedDays, ...local.countedDays},
          summaryCompletedDays: {
            ...recordState.summaryCompletedDays,
            ...local.summaryCompletedDays,
          },
          consumedSaveMonths: {
            ...recordState.consumedSaveMonths,
            ...local.consumedSaveMonths,
          },
          spoiledMonths: {
            ...recordState.spoiledMonths,
            ...local.spoiledMonths,
          },
          restoredDays: {...recordState.restoredDays, ...local.restoredDays},
        );
      } else {
        evolving = recordState ?? local;
      }
      if (evolving == null) {
        // No record anywhere: nothing can be derived or counted
        // (anti-fabrication parity) — retry on a later start.
        return const SummaryResettlementOutcome(
          resettled: [],
          markerAdvanced: false,
          deferred: true,
        );
      }

      final today = tabsDayStr(now);
      final pastCounted = evolving.countedDays
          .where((d) => d.compareTo(today) < 0)
          .toList()
        ..sort();
      if (pastCounted.isEmpty) {
        // No counted anchor: no streak-threatening chain exists
        // to heal — and nothing else runs (see the cheap gate
        // below).
        return const SummaryResettlementOutcome(
          resettled: [],
          markerAdvanced: false,
        );
      }

      // Candidates: every closed Tabs day after the last counted
      // day, before today, oldest first.
      final candidates = <String>[];
      var cursor = _nextTabsDay(pastCounted.last);
      while (cursor.compareTo(today) < 0) {
        candidates.add(cursor);
        cursor = _nextTabsDay(cursor);
      }
      // CHEAP GATE (load-bearing): this hook sits on the app-open
      // settlement path, ahead of recordOpen. Most launches have
      // NO settled-but-uncounted gap (the last counted day is
      // yesterday, or there is no record) — those launches return
      // here, before the version-marker storage is read and before
      // any context is resolved, so the hook costs one in-memory
      // derivation and can never wedge or slow the settlement it
      // precedes.
      if (candidates.isEmpty) {
        return const SummaryResettlementOutcome(
          resettled: [],
          markerAdvanced: false,
        );
      }

      // The version gate, read only when a candidate exists. The
      // read is time-bounded: a wedged storage channel degrades
      // to "not yet run" (every completion below is per-day
      // idempotent, so a redundant scan changes nothing) rather
      // than blocking settlement.
      int storedVersion = 0;
      try {
        storedVersion = int.tryParse(
              await _readVersion(predicateVersionStorageKey).timeout(
                const Duration(seconds: 2),
                onTimeout: () => null,
              ) ??
                  '',
            ) ??
            0;
      } catch (_) {
        storedVersion = 0;
      }
      if (storedVersion >= currentPredicateVersion) {
        return const SummaryResettlementOutcome(
          resettled: [],
          markerAdvanced: true,
        );
      }

      final resettled = <ResettledDay>[];
      var current = evolving;
      for (final day in candidates) {
        // Adjacency (freeze guard, part 1): the candidate must be
        // exactly the day after the evolving record's last counted
        // day before today. After a healed day the record evolves,
        // so the chain stays adjacent by construction; any drift
        // stops the scan.
        final countedBefore = current.countedDays
            .where((d) => d.compareTo(today) < 0)
            .toList()
          ..sort();
        if (countedBefore.isEmpty || _nextTabsDay(countedBefore.last) != day) {
          return SummaryResettlementOutcome(
            resettled: resettled,
            markerAdvanced: false,
            guardBlockedDay: day,
          );
        }
        // The feeling-day start of the candidate's Tabs day: a
        // moment safely inside it names its start under the
        // shared Tabs-day definition.
        final dayStart = feelingDayStart(
          DateTime.parse(day).add(const Duration(hours: 12)),
        );
        SummaryCompletionContext? context;
        try {
          context = await resolveContext(dayStart);
        } catch (_) {
          context = null;
        }
        if (context == null ||
            context.attestedPlan == null ||
            !context.attestedPlan!.resolved) {
          // Indefinitive: an unattested plan can prove nothing
          // either way (Vera condition 1). Do not burn the shot.
          return SummaryResettlementOutcome(
            resettled: resettled,
            markerAdvanced: false,
            deferred: true,
          );
        }
        if (!isSummaryComplete(
          feelingDayStart: dayStart,
          attestedPlan: context.attestedPlan,
          entries: context.entries,
          moodCategoryId: context.moodCategoryId,
        )) {
          // Definitive failure: the day stays uncounted, silently
          // — and the scan stops, because any later day could
          // only complete across this one via a freeze bridge.
          break;
        }
        // Freeze guard, part 2: the pure completion preview on
        // the actual record must leave every freeze/month list
        // untouched.
        final preview = completeDay(current, summaryTabsDay: day, now: now);
        if (!setEquals(
              preview.state.consumedSaveMonths,
              current.consumedSaveMonths,
            ) ||
            !setEquals(preview.state.spoiledMonths, current.spoiledMonths) ||
            !setEquals(preview.state.restoredDays, current.restoredDays)) {
          return SummaryResettlementOutcome(
            resettled: resettled,
            markerAdvanced: false,
            guardBlockedDay: day,
          );
        }
        final countedSnapshot = current.countedDays;
        final outcome = await store.recordSummaryComplete(
          pullSucceeded: pullSucceeded,
          seedCurrent: seedCurrent,
          seedBest: seedBest,
          seedStateJson: seedStateJson,
          seedPurchasedFreezes: seedPurchasedFreezes,
          now: now,
          summaryDay: dayStart,
          push: push,
        );
        final completion = outcome.completion;
        if (!outcome.state.seeded || completion == null) {
          // Anti-fabrication parity with the watcher: no record
          // and no successful pull counted nothing. Indefinitive
          // for the scan as a whole — retry on a later start.
          return SummaryResettlementOutcome(
            resettled: resettled,
            markerAdvanced: false,
            deferred: true,
          );
        }
        // Never-un-count verification: every previously counted
        // day still counted, the healed day counted AND recorded
        // summary-complete, and the freeze/month lists still
        // untouched in the installed state.
        if (!outcome.state.countedDays.containsAll(countedSnapshot) ||
            !outcome.state.countedDays.contains(day) ||
            !outcome.state.summaryCompletedDays.contains(day) ||
            !setEquals(
              outcome.state.consumedSaveMonths,
              current.consumedSaveMonths,
            ) ||
            !setEquals(outcome.state.spoiledMonths, current.spoiledMonths) ||
            !setEquals(outcome.state.restoredDays, current.restoredDays)) {
          return SummaryResettlementOutcome(
            resettled: resettled,
            markerAdvanced: false,
            guardBlockedDay: day,
          );
        }
        current = outcome.state;
        final healed = ResettledDay(
          day: day,
          result: completion,
          state: outcome.state,
        );
        resettled.add(healed);
        if (onResettled != null) {
          try {
            await onResettled(healed);
          } catch (_) {
            // The claim chain queues/retries on its own discipline;
            // a claim failure never un-heals the day.
          }
        }
      }
      await _advanceMarker();
      return SummaryResettlementOutcome(
        resettled: resettled,
        markerAdvanced: true,
      );
    } finally {
      _running = false;
    }
  }
}
