import 'dart:async';

import 'package:tabs_lab/src/data/correlation_engine.dart'
    show deriveFeelingByDay;
import 'package:tabs_lab/src/data/hc_availability.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';

/// Round 13 — combines the Health Connect reads and the Tabs backend into
/// the home screen's data: today's vitals, the 7-day snapshot metrics,
/// and the streak pair.
///
/// Founder data rules enforced throughout:
/// - Biometric 0 = failed read → excluded before aggregating, never
///   charted/averaged/cached (see `health_data.dart`).
/// - HR is daytime-only (7am–11pm, device-local hour 7..22) everywhere.
/// - Missing → null → the UI's "--"/empty states. Nothing invented.
/// - Nothing here ever throws: every source is caught into its honest
///   empty outcome.
class TodayVitals {
  /// Daytime-only HR average; null when no usable samples.
  final int? heartRate;

  /// Active calories today; null when missing or 0.
  final int? activeCalories;

  /// Sleep minutes last night; null when missing or 0.
  final int? sleepMinutes;

  /// Raw log count for today — 0 is real (native shows the raw count).
  final int logCountToday;

  /// HC Grant Hardening §3.2 — wedge evidence from THIS load's own
  /// reads: a core read failed with a SecurityException while its
  /// permission was granted. Deliberately conservative: the three
  /// vitals reads run in parallel over the service's shared
  /// diagnostic slots, so a security failure is attributed to the
  /// load (not to a single type) and only counts when EVERY
  /// attempted core type's grant state was full — a failure under
  /// a partial grant may belong to the missing leg, which is a
  /// missing permission, not a wedge. False on every load that did
  /// not run or did not fail that way.
  final bool coreReadWedged;

  const TodayVitals({
    this.heartRate,
    this.activeCalories,
    this.sleepMinutes,
    this.logCountToday = 0,
    this.coreReadWedged = false,
  });
}

class HealthRepository {
  final HealthConnectService hc;
  final TabsBackend backend;

  /// R70 WS1b — history capture hook (injectable for tests).
  final HealthHistorySync historySync;

  /// R70 WS2 — the local-first union reader (store ∪ fresh HC).
  final HealthHistoryQueries historyQueries;

  HealthRepository({
    HealthConnectService? hc,
    TabsBackend? backend,
    HealthHistorySync? historySync,
    HealthHistoryQueries? historyQueries,
  }) : this._internal(
          hc ?? HealthConnectService(),
          backend ?? TabsBackend(),
          historySync ?? HealthHistorySync.instance,
          historyQueries,
        );

  HealthRepository._internal(
    this.hc,
    this.backend,
    this.historySync,
    HealthHistoryQueries? queries,
  ) : historyQueries = queries ?? HealthHistoryQueries(hc: hc);

  /// Fire-and-forget history capture after a successful connected
  /// load. Behind the sync's 6h throttle, unawaited, and never
  /// throws — home load latency and behavior are unchanged.
  void _triggerHistoryCapture() {
    try {
      unawaited(historySync.capture());
    } catch (_) {}
  }

  /// The missing set the per-type gates consume for [snapshot]:
  /// a confirmed-UNAVAILABLE service is a known state in which
  /// every type is effectively missing (no read can succeed), so
  /// the gates see the full required set as missing instead of
  /// the unknown-layer null — the pre-hardening fast path (an
  /// unavailable device resolves its loads immediately, with no
  /// doomed bridge reads).
  Set<String>? _missingForGates(HcAvailability snapshot) =>
      snapshot.status == HealthConnectStatus.unavailable
          ? HealthConnectService.requiredPermissions
          : snapshot.missingIfKnown;

  Future<bool> _loggedIn() async {
    try {
      final token = await backend.readToken();
      return token != null && token.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Today's vitals for the [VitalsStrip].
  ///
  /// HC Grant Hardening §3.4 — the reads are gated PER TYPE off
  /// the caller's availability [snapshot] (Home probes once and
  /// shares it): each type is attempted unless ITS permission set
  /// is verified missing, and an unknown grant layer attempts
  /// (reads fail closed to honest empty values). A type that is
  /// not attempted keeps its null (the native empty state); the
  /// log count still comes from the backend when logged in.
  /// Never throws.
  Future<TodayVitals> loadTodayVitals(
      {required HcAvailability snapshot}) async {
    // Round 60 — every source here is independent, so they run in
    // PARALLEL (measured at base: the log-count pull, then the HR,
    // calories, and sleep bridge reads ran one after another —
    // 4 × 150ms fakes = ~658ms; parallel lands at the max, ~150ms).
    // The log-count future starts FIRST and is awaited LAST so it
    // overlaps the Health Connect reads instead of gating them.
    final logCountFuture = _todayLogCount();
    final missing = _missingForGates(snapshot);
    final hrAttempt = hcShouldAttemptRead(heartPermissions, missing);
    final calAttempt = hcShouldAttemptRead(vitalsCaloriesPermissions,
        missing,
        anySufficient: true);
    final sleepAttempt = hcShouldAttemptRead(sleepPermissions, missing);
    if (!hrAttempt && !calAttempt && !sleepAttempt) {
      return TodayVitals(logCountToday: await logCountFuture);
    }

    int? heartRate;
    int? activeCalories;
    int? sleepMinutes;
    var coreReadWedged = false;
    try {
      // The service keeps its read error codes without clearing
      // them on success; reset them so the write-through gate
      // below judges THIS load's reads, not a stale earlier one
      // (mirrors heart_screen._load's reset before its read).
      hc.lastReadErrorCode = null;
      hc.lastPartialErrorCode = null;
      hc.lastReadErrorDetails = null;
      final today = _dateStr(DateTime.now());
      // Round 60 fix (Vera blocker) — each read enters the wait
      // through its OWN error-isolating wrapper, so the wait itself
      // cannot fail: a read that THROWS (not a null failure — a
      // parse/type error in the bridge's sample loop, an
      // invokeMethod type mismatch, a throwing HC implementation)
      // degrades to its honest empty value ([] / null) and the
      // other two reads still land, exactly as the sequential base
      // assigned each value as it arrived. Without the wrappers,
      // one throw poisoned all three assignments after the await.
      // A type whose gate closed never enters the wait at all —
      // its slot in the results is its honest empty value.
      //
      // Heart store-first fix (Nov 24, 2026): the HR read runs
      // FIRST and completes before the cal/sleep wait starts. It
      // now enters through the outcome bridge, whose slot gate
      // (for subclass-override reads) clears the shared diagnostic
      // slots when its frame runs — if that frame straddled the
      // parallel bundle, its clear could land AFTER a sibling's
      // synchronous slot write and wipe this load's wedge
      // evidence before the coreReadWedged derivation below reads
      // it. HR is the long pole of the three reads and the other
      // two are single aggregate queries, so the overlap given up
      // is the two fast reads only; their own parallelism is
      // unchanged.
      final hrOutcome = hrAttempt
          ? await _hrOutcomeOrEmpty(today)
          : HcReadOutcome<List<HrSample>>(value: const <HrSample>[]);
      final reads = await Future.wait<Object?>([
        calAttempt ? _caloriesOrNull(today) : Future<Object?>.value(null),
        sleepAttempt ? _sleepOrNull(today) : Future<Object?>.value(null),
      ]);
      final hrSamples = hrOutcome.value;
      // Perf package (Nov 2, 2026) — write-through: this load just
      // paid the full raw-day HR read; share the series with the
      // Heart screen through its cache (memory only here — the
      // Heart screen persists its own loads, so this path never
      // writes an ownerless disk blob). A Heart open within the
      // cache's fresh window then needs NO Health Connect read at
      // all. Only a clean read writes through: a failure code on
      // the read, or a PARTIAL code (deliberately kept apart from
      // the failure code per the F2 rule, so partial data is never
      // discarded as an outage), blocks it — a partial series has
      // chunks missing, so it must never become the cache's
      // "fresh" data or be painted as complete (the cache itself
      // also refuses to stamp failed applies). The zero rule is
      // re-applied inside the cache's apply.
      //
      // Heart store-first fix (Nov 24, 2026): the gate now claims
      // the HR read's OWN outcome object instead of the shared
      // slot fields (lastReadErrorCode / lastPartialErrorCode).
      // All three reads share one service instance and every
      // sibling read writes those same slots, so any sibling
      // failure or partial landing after the HR read silently
      // skipped this write-through while Home still rendered HR
      // from the samples it held — Home showed HR 64 the same
      // morning the Heart cache stayed empty. The outcome travels
      // with its own read and cannot be dirtied by a sibling.
      if (hrAttempt &&
          hrOutcome.errorCode == null &&
          hrOutcome.partialCode == null) {
        try {
          HeartDataCache.instance.apply(today, hrSamples);
        } catch (_) {
          // Cache write-through is an optimization; never fail vitals.
        }
      }
      // HC Grant Hardening §3.2 — this load's wedge evidence (see
      // [TodayVitals.coreReadWedged] for the conservative rule).
      final attemptedStates = <HcGrantState>[
        if (hrAttempt) hcGrantStateFor(heartPermissions, missing),
        if (calAttempt)
          hcGrantStateFor(vitalsCaloriesPermissions, missing),
        if (sleepAttempt) hcGrantStateFor(sleepPermissions, missing),
      ];
      coreReadWedged = snapshot.grantKnown &&
          hc.lastReadErrorCode != null &&
          (hc.lastReadErrorDetails?.contains('SecurityException') ??
              false) &&
          attemptedStates.every((s) => s == HcGrantState.full);
      heartRate = daytimeHeartRateAvg(hrSamples);
      final cal = reads[0] as int?;
      // Biometric 0 = failed read → null, never shown/averaged.
      activeCalories = (cal != null && cal > 0) ? cal : null;
      final sleep = reads[1] as int?;
      sleepMinutes = (sleep != null && sleep > 0) ? sleep : null;
    } catch (_) {
      // Nulls stand — the UI shows "--".
    }
    final vitals = TodayVitals(
      heartRate: heartRate,
      activeCalories: activeCalories,
      sleepMinutes: sleepMinutes,
      logCountToday: await logCountFuture,
      coreReadWedged: coreReadWedged,
    );
    // R70 WS1b — values are computed; capture history behind the
    // throttle without blocking the return. HC Grant Hardening
    // §1.3 — the capture fires when at least one of its core
    // inputs (HR, sleep) was attempted-or-readable; the capture
    // and the Daily Score engine already suppress per-metric, so
    // a partial grant no longer starves the score of the metrics
    // it does have.
    if (hrAttempt || sleepAttempt) _triggerHistoryCapture();
    return vitals;
  }

  /// Round 60 fix (Vera blocker) — per-read error isolation for the
  /// parallel vitals reads: a throwing read becomes its honest
  /// empty value instead of failing the whole [Future.wait].
  ///
  /// Heart store-first fix: the HR leg reads through the
  /// outcome-carrying variant so its caller claims the read's OWN
  /// outcome (see the write-through gate in [loadTodayVitals]). A
  /// throwing read degrades to a failed outcome carrying no
  /// samples — never a clean outcome — so the gate stays closed
  /// exactly as a thrown legacy read kept it closed.
  Future<HcReadOutcome<List<HrSample>>> _hrOutcomeOrEmpty(
      String today) async {
    try {
      return await hc.readHeartRateSamplesWithOutcome(today);
    } catch (_) {
      return HcReadOutcome<List<HrSample>>(
          value: const [], errorCode: 'HR_SAMPLES_READ_FAILED');
    }
  }

  Future<int?> _caloriesOrNull(String today) async {
    try {
      return await hc.readActiveCalories(today);
    } catch (_) {
      return null;
    }
  }

  Future<int?> _sleepOrNull(String today) async {
    try {
      return await hc.readSleepMinutes(today);
    } catch (_) {
      return null;
    }
  }

  /// Today's log count from the backend pull (0 on any failure —
  /// the honest fallback the pre-Round-60 sequential code used).
  Future<int> _todayLogCount() async {
    try {
      final today = _dateStr(DateTime.now());
      final entries = await backend.fetchLogEntries();
      return entries
          .where((t) =>
              _dateStr(DateTime.fromMillisecondsSinceEpoch(t)) == today)
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// 7-day snapshot for one metric, oldest → today, device-local dates.
  ///
  /// HC Grant Hardening §3.4 — each Health Connect metric loads
  /// behind the gate for ITS OWN permission set (the report map's
  /// sets for the union metrics; READ_BLOOD_PRESSURE for the BP
  /// half): a metric whose set is verified missing renders the
  /// native empty state for THAT metric only, and an unknown grant
  /// layer attempts (the union fails closed per metric). Logs/
  /// habits/manual-BP and the Morning Score (Daily Ranking
  /// entries) come from the backend when a session token exists.
  /// Never throws.
  Future<WeeklySnapshotMetricData> loadSnapshot(SnapshotMetric metric) async {
    final window = sevenDayWindow();
    final dateStrs = [for (final w in window) w.dateStr];
    final labels = [for (final w in window) w.dayLabel];
    final snapshot = await hc.probeAvailability();
    final missing = _missingForGates(snapshot);
    // The HC attempt verdict for THIS metric's load (BP decides
    // its own below — only its HC half is gated).
    final bool hcAttempt = switch (metric) {
      SnapshotMetric.sleepHours =>
        hcShouldAttemptRead(sleepPermissions, missing),
      SnapshotMetric.restingHeartRate => hcShouldAttemptRead(
          reportMetricPermissions[HistoryMetric.restingHr]!, missing),
      SnapshotMetric.hrSpikes =>
        hcShouldAttemptRead(heartPermissions, missing),
      SnapshotMetric.calories => hcShouldAttemptRead(
          vitalsCaloriesPermissions, missing,
          anySufficient: true),
      _ => false,
    };
    final hcOnly = metric != SnapshotMetric.logs &&
        metric != SnapshotMetric.habitCompletion &&
        metric != SnapshotMetric.bloodPressure &&
        metric != SnapshotMetric.morningScore;
    if (!hcAttempt && hcOnly) return emptyMetricData(metric);
    // R70 WS1b — a snapshot load that attempts an HC metric also
    // feeds the history store (throttled, fire-and-forget; the
    // load below is fail-soft and never throws past its honest
    // empty states). HC Grant Hardening §3.4: the trigger follows
    // the attempt, not a global verdict.
    if (hcAttempt) _triggerHistoryCapture();
    try {
      switch (metric) {
        case SnapshotMetric.sleepHours:
          // R70 WS2 — local-first union (store ∪ fresh HC range
          // read) instead of 7 per-day bridge reads; the builder
          // and its zero rule are unchanged, so identical inputs
          // render identical output.
          final union = await historyQueries.loadDays(7,
              metrics: {HistoryMetric.sleep});
          return buildSleepMetric(dateStrs, labels, union.sleepMinutes);
        case SnapshotMetric.restingHeartRate:
          final union = await historyQueries.loadDays(7,
              metrics: {HistoryMetric.restingHr});
          return buildRestingHrMetric(dateStrs, labels, union.restingHr);
        case SnapshotMetric.hrSpikes:
          // R70 WS2 — spike counts come from the union (the store's
          // counts are the readSpikeCounts bridge rule, the same
          // computation WS1's capture stores). A day with no count
          // in the map renders 0 via the builder, exactly as the
          // old per-day sample computation rendered a sampled day
          // with no spikes.
          final union = await historyQueries.loadDays(7,
              metrics: {HistoryMetric.spikes});
          return buildSpikesMetric(dateStrs, labels, union.spikes);
        case SnapshotMetric.calories:
          final union = await historyQueries.loadDays(7,
              metrics: {HistoryMetric.calories});
          return buildCaloriesMetric(dateStrs, labels, union.calories);
        case SnapshotMetric.logs:
          final entries =
              await _loggedIn() ? await backend.fetchLogEntries() : <int>[];
          return buildLogsMetric(dateStrs, labels, entries);
        case SnapshotMetric.habitCompletion:
          final habits =
              await _loggedIn() ? await backend.fetchHabits() : <HabitDto>[];
          return buildHabitsMetric(dateStrs, labels, habits, true);
        case SnapshotMetric.bloodPressure:
          final records = <BpRecord>[];
          if (hcShouldAttemptRead(bloodPressurePermissions, missing)) {
            records.addAll(await hc.readBloodPressure(7));
          }
          if (await _loggedIn()) records.addAll(await backend.fetchManualBpLogs());
          return buildBpMetric(dateStrs, labels, records);
        case SnapshotMetric.morningScore:
          // The Daily Ranking lives in the sync pull (a Quick Log
          // entry), not Health Connect — logged out means the honest
          // empty week, exactly like Logs with no session.
          if (!await _loggedIn()) {
            return buildMorningScoreMetric(dateStrs, labels, const {});
          }
          final entries = await backend.fetchLogEntryDtos();
          final categories = await backend.fetchLogCategories();
          return buildMorningScoreMetric(
            dateStrs,
            labels,
            deriveFeelingByDay(entries, categories),
          );
      }
    } catch (_) {
      return emptyMetricData(metric);
    }
  }

  /// Streak pair from the backend; nulls when logged out or on any
  /// failure — the streak row renders "--".
  ///
  /// C-02 — the result carries the success bit (the same distinction
  /// [loadStreakRecord] already makes via `fetchStreakRecord`): a
  /// failed pull reports `succeeded: false` with null counters,
  /// while a successful pull of a profile with no streak fields is
  /// a confirmed-empty streak (`succeeded: true`, nulls). Callers
  /// that CACHE the pair must skip the cache write on failure —
  /// nulls produced by a failure are not data and must never
  /// overwrite the last known streak.
  Future<({bool succeeded, int? current, int? best})> loadStreak() async {
    try {
      final rec = await backend.fetchStreakRecord();
      return (
        succeeded: rec.succeeded,
        current: rec.current,
        best: rec.best
      );
    } catch (_) {
      return (succeeded: false, current: null, best: null);
    }
  }

  /// The full authoritative streak record (VC 100115); a failed
  /// pull reports `succeeded: false` so the streak store never
  /// fabricates a run from silence.
  Future<
      ({
        bool succeeded,
        int? current,
        int? best,
        String? stateJson,
        int? purchasedFreezes
      })> loadStreakRecord() async {
    try {
      // Field-mapped (not returned directly): fetchStreakRecord's
      // record also carries gemBalance, which this pinned shape
      // deliberately omits — existing test fakes construct it.
      final rec = await backend.fetchStreakRecord();
      return (
        succeeded: rec.succeeded,
        current: rec.current,
        best: rec.best,
        stateJson: rec.stateJson,
        purchasedFreezes: rec.purchasedFreezes,
      );
    } catch (_) {
      return (
        succeeded: false,
        current: null,
        best: null,
        stateJson: null,
        purchasedFreezes: null
      );
    }
  }

  /// The server gem balance from the same sync pull
  /// (jot-server PR #41: profile `gem_balance`). Null on any
  /// failure — callers keep the last server value, never a guess.
  Future<int?> loadGemBalance() async {
    try {
      final rec = await backend.fetchStreakRecord();
      return rec.succeeded ? rec.gemBalance : null;
    } catch (_) {
      return null;
    }
  }

  /// Push one settled streak record back to the profile
  /// (VC 100115). False on any failure — the local record stays
  /// strictly newer and re-pushes on the next settle.
  /// [purchasedFreezes] rides along only when the settle consumed
  /// a purchased freeze (streak upgrade A2).
  Future<bool> pushStreakRecord(int current, int best, String stateJson,
      {int? purchasedFreezes}) async {
    try {
      return await backend.pushStreakRecord(current, best, stateJson,
          purchasedFreezes: purchasedFreezes);
    } catch (_) {
      return false;
    }
  }
}

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
