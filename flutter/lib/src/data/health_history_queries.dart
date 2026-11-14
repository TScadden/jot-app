import 'dart:async';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';

/// R70 WS2 — the ONE union helper every historical reader goes
/// through. Local-first: a requested day range is served as
///
///   store range ∪ fresh Health Connect range reads
///
/// per field, with FRESH HC winning for the days it covers (HC is
/// the source of truth inside its retention window) and the store
/// filling everything older / everything HC no longer holds. Any
/// HC data fetched here is `mergeRefresh`ed into the store BEFORE
/// returning, so no reader can bypass the store's growth — every
/// read deepens the well.
///
/// Founder rules, enforced on the HC side exactly as the readers
/// they replace did it (see `health_data.dart`):
/// - a biometric 0 is a failed read: resting HR / sleep / deep /
///   calories / HRV values ≤ 0 never enter the returned maps and
///   never reach the store (the store re-applies the same rule on
///   merge). A spike count of 0 is REAL data and is kept.
/// - genuinely-absent dates stay absent — maps hold only real
///   values, never zero-filled placeholders.
///
/// Failure handling: the HC service fails closed (empty / null)
/// and each read's outcome object carries that read's OWN failure
/// or partial signal (Phase 2 §1 — `HcReadOutcome`); a PARTIAL read
/// (some chunks missing, real rows returned) is reported in
/// [HistoryUnion.partialMetrics] — never as a failure. Each loader
/// claims its signals from its own read's outcome object, so a
/// failed metric is reported in [HistoryUnion.failedMetrics] —
/// callers that must not mistake an outage for emptiness (the Key
/// Metrics CSV export, Vera F5) check it; everyone else just gets
/// the honest store-backed remainder. Attribution no longer rides
/// on the service's legacy slot fields at all: two concurrent
/// unions sharing one service instance cannot cross-talk, by
/// construction.
///
/// HC fetch depth is capped at [maxHealthConnectFetchDays]: HC
/// retention is a few weeks, so for a deeper request (a report's
/// 180 days is the deepest real one; Key Metrics "All Time" asks
/// for years) the store is the only possible source beyond the cap
/// and a giant bridge scan would buy nothing.

/// One store-backed metric family. `sleep` covers both the sleep
/// total and deep sleep (one bridge read produces both).
enum HistoryMetric { restingHr, sleep, calories, spikes, hrv }

/// The union result for one range: per-metric date → value maps
/// (dates "YYYY-MM-DD"), plus the metrics whose fresh HC read
/// FAILED (an outage signal, distinct from a genuinely-empty read).
class HistoryUnion {
  final String startDate; // inclusive, "YYYY-MM-DD"
  final String endDate; // inclusive, "YYYY-MM-DD"

  /// Resting HR (bpm), values > 0 only.
  final Map<String, int> restingHr;

  /// Sleep minutes per night, values > 0 only.
  final Map<String, int> sleepMinutes;

  /// Deep-sleep minutes per night, values > 0 only.
  final Map<String, int> deepSleepMinutes;

  /// Calories (kcal) — the bridge's active-preferred figure, the
  /// same definition every reader has always used. Values > 0 only.
  final Map<String, int> calories;

  /// HR spike counts. 0 is a real sampled day and is kept.
  final Map<String, int> spikes;

  /// HRV RMSSD (ms), values > 0 only.
  final Map<String, double> hrv;

  /// Metrics whose fresh HC read failed during this load. A metric
  /// absent from the request is never in this set.
  final Set<HistoryMetric> failedMetrics;

  /// Metrics whose fresh HC read returned PARTIAL data during this
  /// load (some chunks missing — Vera F2): the rows ARE in the maps
  /// above and the metric is NOT in [failedMetrics]; this set is
  /// the warning signal for callers that surface completeness
  /// (e.g. the Key Metrics CSV export).
  final Set<HistoryMetric> partialMetrics;

  /// Per-metric failure evidence for the metrics in [failedMetrics]:
  /// the failing read's error detail from that read's OWN outcome
  /// object (the native exception CLASS only, e.g.
  /// `SecurityException`, never health values), or the thrown
  /// error's string form when a read throws instead of returning
  /// an outcome. A metric whose failure carried no detail is
  /// absent from this map. This is the ONLY stale-grant evidence
  /// the report collector uses: it comes from the metric's own
  /// read, never from a status/probe call.
  final Map<HistoryMetric, String> failureDetails;

  const HistoryUnion({
    required this.startDate,
    required this.endDate,
    this.restingHr = const {},
    this.sleepMinutes = const {},
    this.deepSleepMinutes = const {},
    this.calories = const {},
    this.spikes = const {},
    this.hrv = const {},
    this.failedMetrics = const {},
    this.partialMetrics = const {},
    this.failureDetails = const {},
  });

  bool failed(HistoryMetric metric) => failedMetrics.contains(metric);

  bool partial(HistoryMetric metric) => partialMetrics.contains(metric);

  /// True when [metric]'s own fresh read failed AND its recorded
  /// failure detail names a SecurityException — the stale/wedged
  /// grant signature (grant present, read blocked) for THAT metric.
  bool failedWithSecurityException(HistoryMetric metric) =>
      failed(metric) &&
      (failureDetails[metric]?.contains('SecurityException') ?? false);

  /// Every date that carries at least one metric in this union,
  /// sorted ascending — the export/report "actual depth" view.
  List<String> get dates {
    final all = <String>{
      ...restingHr.keys,
      ...sleepMinutes.keys,
      ...deepSleepMinutes.keys,
      ...calories.keys,
      ...spikes.keys,
      ...hrv.keys,
    }.toList()
      ..sort();
    return all;
  }
}

/// VC 100133 (Phase 5) — ONE metric loader's finished work,
/// returned (never thrown) by each union loader: the rows it
/// collected in its OWN map (absorbed into the union's shared
/// fresh map centrally, in canonical order, only if the loader
/// was not abandoned at the union budget), plus its failure /
/// partial signals claimed from its own read's outcome object.
class _UnionLoaderResult {
  final Map<String, DailyBiometrics> rows;
  final bool failed;
  final String? failureDetail;
  final bool partial;

  const _UnionLoaderResult({
    this.rows = const {},
    this.partial = false,
  })  : failed = false,
        failureDetail = null;

  const _UnionLoaderResult.failure(String? detail)
      : rows = const {},
        failed = true,
        failureDetail = detail,
        partial = false;
}

String historyDateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class HealthHistoryQueries {
  /// Deepest fresh-HC scan the union will ever request (see the
  /// file header): beyond this, the store is the only source.
  static const int maxHealthConnectFetchDays = 180;

  final HealthConnectService hc;
  final HealthHistoryStore store;

  HealthHistoryQueries({HealthConnectService? hc, HealthHistoryStore? store})
      : hc = hc ?? HealthConnectService(),
        store = store ?? HealthHistoryStore.instance;

  /// Union for the [days]-day window ending at [end] (inclusive,
  /// device-local calendar days; defaults to today).
  ///
  /// The VC 100130 bounds ([readTimeout], [unionBudget],
  /// [maxFetchDays]) are opt-in and default to the historical
  /// unbounded behavior, so existing callers are unchanged; the
  /// report collector opts in (see progress_report.dart).
  Future<HistoryUnion> loadDays(
    int days, {
    DateTime? end,
    Set<HistoryMetric> metrics = const {
      HistoryMetric.restingHr,
      HistoryMetric.sleep,
      HistoryMetric.calories,
      HistoryMetric.spikes,
    },
    bool fetchFromHealthConnect = true,
    Duration? readTimeout,
    Duration? unionBudget,
    int? maxFetchDays,
  }) {
    final e = end ?? DateTime.now();
    final endDay = DateTime(e.year, e.month, e.day);
    final startDay = endDay.subtract(Duration(days: days - 1));
    return loadRange(
      startDate: historyDateStr(startDay),
      endDate: historyDateStr(endDay),
      metrics: metrics,
      fetchFromHealthConnect: fetchFromHealthConnect,
      readTimeout: readTimeout,
      unionBudget: unionBudget,
      maxFetchDays: maxFetchDays,
    );
  }

  /// Union for an explicit inclusive date range. Never throws:
  /// a failing source degrades to the other source's data, with
  /// HC failures named in [HistoryUnion.failedMetrics].
  ///
  /// VC 100130 bounds (all optional, null = unbounded / uncapped,
  /// preserving every existing caller):
  /// - [readTimeout]: a per-read bound. Each loader's outcome
  ///   await is wrapped so a read that exceeds it fails THAT
  ///   metric only, recorded with the class-only detail
  ///   `TimeoutException` (the Juno J1 evidence convention — a
  ///   class-style token, never a message).
  /// - [unionBudget]: a soft budget for the whole union, tracked
  ///   from loadRange entry. VC 100133: the loaders run
  ///   concurrently, and the budget binds two ways — a loader
  ///   whose start is already past the budget never issues its
  ///   read, and a loader still in flight when the budget runs
  ///   out is abandoned (its late result is never merged); both
  ///   are noted failed with the class-style token
  ///   `UnionBudgetExhausted`. Skipped/abandoned metrics surface
  ///   through the callers' existing failed-metric derivation
  ///   (failed + store data → stored data; failed + no data →
  ///   the existing error/denied/stale logic) — there are no new
  ///   union states.
  /// - [maxFetchDays]: caps the fresh-HC scan depth for THIS call
  ///   only (default: [maxHealthConnectFetchDays]).
  Future<HistoryUnion> loadRange({
    required String startDate,
    required String endDate,
    Set<HistoryMetric> metrics = const {
      HistoryMetric.restingHr,
      HistoryMetric.sleep,
      HistoryMetric.calories,
      HistoryMetric.spikes,
    },
    bool fetchFromHealthConnect = true,
    Duration? readTimeout,
    Duration? unionBudget,
    int? maxFetchDays,
  }) async {
    // The union soft budget is tracked from loadRange entry.
    final unionWatch = Stopwatch()..start();
    // 1. The store's slice of the range (full stored depth).
    Map<String, DailyBiometrics> stored = const {};
    try {
      stored = await store.readRange(startDate, endDate);
    } catch (_) {
      stored = const {};
    }
    final restingHr = <String, int>{
      for (final e in stored.entries)
        if (e.value.restingHrBpm != null) e.key: e.value.restingHrBpm!,
    };
    final sleepMinutes = <String, int>{
      for (final e in stored.entries)
        if (e.value.sleepMinutes != null) e.key: e.value.sleepMinutes!,
    };
    final deepSleepMinutes = <String, int>{
      for (final e in stored.entries)
        if (e.value.deepSleepMinutes != null) e.key: e.value.deepSleepMinutes!,
    };
    final calories = <String, int>{
      for (final e in stored.entries)
        if (e.value.caloriesKcal != null) e.key: e.value.caloriesKcal!,
    };
    final spikes = <String, int>{
      for (final e in stored.entries)
        if (e.value.spikeCount != null) e.key: e.value.spikeCount!,
    };
    final hrv = <String, double>{
      for (final e in stored.entries)
        if (e.value.hrvRmssdMs != null) e.key: e.value.hrvRmssdMs!,
    };

    final failed = <HistoryMetric>{};
    final partial = <HistoryMetric>{};
    final failureDetails = <HistoryMetric, String>{};
    if (!fetchFromHealthConnect) {
      return HistoryUnion(
        startDate: startDate,
        endDate: endDate,
        restingHr: restingHr,
        sleepMinutes: sleepMinutes,
        deepSleepMinutes: deepSleepMinutes,
        calories: calories,
        spikes: spikes,
        hrv: hrv,
      );
    }

    // 2. Fresh HC for the same window (capped — see header). HC
    //    range reads are anchored on today, so the fetch depth is
    //    the range length plus the range end's distance back from
    //    today, at most the cap.
    final rangeDays = _rangeDayCount(startDate, endDate);
    final endParsed = DateTime.tryParse(endDate);
    final nowDay = DateTime.now();
    var daysBack = 0;
    if (endParsed != null) {
      daysBack =
          DateTime(nowDay.year, nowDay.month, nowDay.day)
              .difference(
                  DateTime(endParsed.year, endParsed.month, endParsed.day))
              .inDays;
      if (daysBack < 0) daysBack = 0;
    }
    final wantedFetch = rangeDays + daysBack;
    final fetchCap = (maxFetchDays != null && maxFetchDays > 0)
        ? maxFetchDays
        : maxHealthConnectFetchDays;
    final fetchDays = wantedFetch > fetchCap ? fetchCap : wantedFetch;

    // Fresh rows collected per date, merged into the store in
    // step 3 and overlaid on the returned maps in step 4.
    final fresh = <String, DailyBiometrics>{};
    void putFresh(
      String date, {
      int? hr,
      int? sleep,
      int? deep,
      int? kcal,
      int? spikeCount,
      double? hrvValue,
    }) {
      if (date.compareTo(startDate) < 0 || date.compareTo(endDate) > 0) {
        return; // bridge rows outside the requested range don't leak in
      }
      final prev = fresh[date];
      fresh[date] = DailyBiometrics(
        date: date,
        restingHrBpm: hr ?? prev?.restingHrBpm,
        sleepMinutes: sleep ?? prev?.sleepMinutes,
        deepSleepMinutes: deep ?? prev?.deepSleepMinutes,
        caloriesKcal: kcal ?? prev?.caloriesKcal,
        spikeCount: spikeCount ?? prev?.spikeCount,
        hrvRmssdMs: hrvValue ?? prev?.hrvRmssdMs,
      );
    }

    // 2b. Attribution by outcome (Phase 2 §1): each loader reads
    //     its metric through the outcome-carrying variant and
    //     claims the failure / partial signals from THAT read's
    //     own outcome object. The legacy slot protocol (the
    //     service-global error-slot reset-then-claim drain this
    //     step used to run) is DELETED from the union path — no
    //     code here reads the slots any more, so attribution cannot
    //     cross-talk: two concurrent unions sharing one service
    //     instance each hold their own reads' outcomes, for every
    //     record timing, record-then-yield included (the Phase 1
    //     Vera residual, closed by construction).
    //
    //     VC 100133 (Phase 5): the five loaders now run
    //     CONCURRENTLY within one union. That is safe by the same
    //     construction: attribution was already per-read (outcome
    //     objects, never the shared slots — the production cores
    //     carry their outcome through a per-call Zone box, so
    //     overlapping reads on one service instance attribute
    //     exactly), and each loader now builds its OWN row map
    //     and returns it in a [_UnionLoaderResult]; the shared
    //     [fresh] / [failed] / [partial] state is merged
    //     afterwards, in canonical metric order, on this one
    //     isolate. No loader mutates shared state while reads are
    //     in flight, so a loader abandoned at the union budget
    //     (below) can never write into a union that has already
    //     returned: its late result is simply never merged.
    //     Per-read error isolation is unchanged (the R60 Vera
    //     pattern: a loader that throws marks only its own metric
    //     failed and never fails the union) — every loader catches
    //     its own errors and RETURNS its result, so loader futures
    //     never complete with an error.
    //
    //     Platform concurrency, honestly stated: the five bridge
    //     calls are issued without waiting on each other. On the
    //     Kotlin side each call launches its own coroutine in the
    //     plugin's engineScope (SupervisorJob + Dispatchers.Main)
    //     against the shared HealthConnectClient (an IPC stub,
    //     safe for concurrent calls): the suspending Health
    //     Connect IPC waits overlap, while the CPU-bound record
    //     mapping inside each read still serializes on the main
    //     dispatcher. The win is therefore the overlapped IPC /
    //     pagination wait, not 5× CPU — measured wall-clocks are
    //     in the VC 100133 acceptance tests.
    void noteFailure(HistoryMetric metric, String? details) {
      failed.add(metric);
      if (details != null && details.isNotEmpty) {
        failureDetails[metric] = details;
      }
    }

    // VC 100130: the per-read bound. A timeout surfaces as a
    // thrown TimeoutException, which the loader's catch records
    // with the class-only detail token below (Juno J1) — never
    // the raw TimeoutException string, which carries a message.
    Future<T> bounded<T>(Future<T> read) {
      final t = readTimeout;
      return t == null ? read : read.timeout(t);
    }

    String failureDetailOf(Object e) =>
        e is TimeoutException ? 'TimeoutException' : e.toString();

    // Row accumulation for ONE loader, in the loader's own map —
    // the parallel replacement for writing the shared [fresh]
    // map mid-read. Same range guard and per-field merge as
    // [putFresh]; the loader's finished map is absorbed into
    // [fresh] centrally (see [absorbRows]).
    void putRow(
      Map<String, DailyBiometrics> rows,
      String date, {
      int? hr,
      int? sleep,
      int? deep,
      int? kcal,
      int? spikeCount,
      double? hrvValue,
    }) {
      if (date.compareTo(startDate) < 0 || date.compareTo(endDate) > 0) {
        return; // bridge rows outside the requested range don't leak in
      }
      final prev = rows[date];
      rows[date] = DailyBiometrics(
        date: date,
        restingHrBpm: hr ?? prev?.restingHrBpm,
        sleepMinutes: sleep ?? prev?.sleepMinutes,
        deepSleepMinutes: deep ?? prev?.deepSleepMinutes,
        caloriesKcal: kcal ?? prev?.caloriesKcal,
        spikeCount: spikeCount ?? prev?.spikeCount,
        hrvRmssdMs: hrvValue ?? prev?.hrvRmssdMs,
      );
    }

    void absorbRows(Map<String, DailyBiometrics> rows) {
      for (final row in rows.values) {
        putFresh(
          row.date,
          hr: row.restingHrBpm,
          sleep: row.sleepMinutes,
          deep: row.deepSleepMinutes,
          kcal: row.caloriesKcal,
          spikeCount: row.spikeCount,
          hrvValue: row.hrvRmssdMs,
        );
      }
    }

    Future<_UnionLoaderResult> loadRestingHr() async {
      final rows = <String, DailyBiometrics>{};
      try {
        final outcome =
            await bounded(hc.readRestingHrHistoryWithOutcome(fetchDays));
        if (outcome.failed) {
          return _UnionLoaderResult.failure(outcome.errorDetails);
        }
        for (final r in outcome.value) {
          // Zero rule, exactly as the readers it replaces.
          if (r.bpm > 0) putRow(rows, r.date, hr: r.bpm);
        }
        return _UnionLoaderResult(rows: rows);
      } catch (e) {
        return _UnionLoaderResult.failure(failureDetailOf(e));
      }
    }

    Future<_UnionLoaderResult> loadSleep() async {
      final rows = <String, DailyBiometrics>{};
      try {
        final outcome =
            await bounded(hc.readSleepHistoryWithOutcome(fetchDays));
        if (outcome.failed) {
          return _UnionLoaderResult.failure(outcome.errorDetails);
        }
        // Partial data is data (F2): rows are processed; the
        // partial signal rides along as a warning, never as a
        // failed metric.
        for (final r in outcome.value) {
          if (r.mins > 0) putRow(rows, r.date, sleep: r.mins);
          if (r.deep > 0) putRow(rows, r.date, deep: r.deep);
        }
        return _UnionLoaderResult(rows: rows, partial: outcome.partial);
      } catch (e) {
        return _UnionLoaderResult.failure(failureDetailOf(e));
      }
    }

    Future<_UnionLoaderResult> loadCalories() async {
      final rows = <String, DailyBiometrics>{};
      try {
        final outcome =
            await bounded(hc.readCaloriesHistoryWithOutcome(fetchDays));
        if (outcome.failed) {
          return _UnionLoaderResult.failure(outcome.errorDetails);
        }
        for (final r in outcome.value) {
          if (r.kcal > 0) putRow(rows, r.date, kcal: r.kcal);
        }
        return _UnionLoaderResult(rows: rows);
      } catch (e) {
        return _UnionLoaderResult.failure(failureDetailOf(e));
      }
    }

    Future<_UnionLoaderResult> loadSpikes() async {
      final rows = <String, DailyBiometrics>{};
      try {
        final outcome =
            await bounded(hc.readSpikeCountsWithOutcome(fetchDays));
        if (outcome.failed) {
          return _UnionLoaderResult.failure(outcome.errorDetails);
        }
        for (final r in outcome.value) {
          // 0 spikes is REAL data (a sampled day, no spikes).
          if (r.count >= 0) putRow(rows, r.date, spikeCount: r.count);
        }
        return _UnionLoaderResult(rows: rows);
      } catch (e) {
        return _UnionLoaderResult.failure(failureDetailOf(e));
      }
    }

    Future<_UnionLoaderResult> loadHrv() async {
      // R71 — ONE range read of raw HRV samples; day attribution +
      // the daily top-tier rule run in Dart (attributeDailyHrv).
      final rows = <String, DailyBiometrics>{};
      try {
        final outcome =
            await bounded(hc.readHrvSamplesWithOutcome(fetchDays));
        if (outcome.failed) {
          return _UnionLoaderResult.failure(outcome.errorDetails);
        }
        // Partial data is data (Defect 0): the surviving chunks'
        // samples are processed; the partial signal rides along
        // as a warning, exactly like sleep above.
        final dailyHrv = attributeDailyHrv(
            outcome.value, _datesInRange(startDate, endDate).toSet());
        for (final entry in dailyHrv.entries) {
          if (entry.value > 0) putRow(rows, entry.key, hrvValue: entry.value);
        }
        return _UnionLoaderResult(rows: rows, partial: outcome.partial);
      } catch (e) {
        return _UnionLoaderResult.failure(failureDetailOf(e));
      }
    }

    // VC 100130 union soft budget, VC 100133 parallel form. The
    // budget is tracked from loadRange entry (unionWatch) and
    // bounds the union two ways:
    // - launch gate (the VC 100130 semantics): a loader whose
    //   start would already be past the budget never issues its
    //   read and is noted failed 'UnionBudgetExhausted';
    // - completion cap: a loader still in flight when the budget
    //   runs out is ABANDONED — noted failed with the same token
    //   and never merged, even when its read later completes (its
    //   result object is dropped; the loader itself only ever
    //   wrote its own row map, so nothing leaks into the returned
    //   union or the store refresh below).
    // With the production wiring (30 s per-read bound inside a
    // 90 s budget) a wedged read still classifies by its OWN
    // timeout first ('TimeoutException', at 30 s); the cap is the
    // backstop that keeps the whole union inside the budget when
    // the per-read bound is the larger of the two. Either way the
    // metric surfaces over its store data through the normal
    // union below — no new union states.
    Future<_UnionLoaderResult> runLoader(
        Future<_UnionLoaderResult> Function() loader) async {
      final budget = unionBudget;
      if (budget != null && unionWatch.elapsed > budget) {
        return const _UnionLoaderResult.failure('UnionBudgetExhausted');
      }
      final result = loader();
      if (budget == null) return result;
      final remaining = budget - unionWatch.elapsed;
      if (remaining <= Duration.zero) {
        return const _UnionLoaderResult.failure('UnionBudgetExhausted');
      }
      return result.timeout(
        remaining,
        onTimeout: () =>
            const _UnionLoaderResult.failure('UnionBudgetExhausted'),
      );
    }

    // The launch plan, in the canonical (pre-Phase-5) read
    // order. Every requested loader is STARTED before any is
    // awaited — calling runLoader issues its bridge read
    // synchronously — then all results are awaited together and
    // merged in this same order, so the returned union is
    // identical in content to the sequential union's.
    final plan = <(HistoryMetric, Future<_UnionLoaderResult> Function())>[
      if (metrics.contains(HistoryMetric.restingHr))
        (HistoryMetric.restingHr, loadRestingHr),
      if (metrics.contains(HistoryMetric.sleep))
        (HistoryMetric.sleep, loadSleep),
      if (metrics.contains(HistoryMetric.calories))
        (HistoryMetric.calories, loadCalories),
      if (metrics.contains(HistoryMetric.spikes))
        (HistoryMetric.spikes, loadSpikes),
      if (metrics.contains(HistoryMetric.hrv)) (HistoryMetric.hrv, loadHrv),
    ];
    final pending = [for (final step in plan) runLoader(step.$2)];
    final results = await Future.wait(pending);
    for (var i = 0; i < plan.length; i++) {
      final metric = plan[i].$1;
      final result = results[i];
      if (result.failed) {
        noteFailure(metric, result.failureDetail);
        continue;
      }
      if (result.partial) partial.add(metric);
      absorbRows(result.rows);
    }

    // 3. Everything fresh feeds the store BEFORE returning — no
    //    reader can bypass the store's growth. mergeRefresh
    //    re-applies the zero rule; a failed store write never
    //    breaks a reader (the store keeps memory regardless).
    if (fresh.isNotEmpty) {
      try {
        await store.mergeRefresh(fresh.values);
      } catch (_) {}
    }

    // 4. Per-field union: fresh HC wins for the days/fields it
    //    covers; the store fills everything else in the range.
    for (final row in fresh.values) {
      if (row.restingHrBpm != null) restingHr[row.date] = row.restingHrBpm!;
      if (row.sleepMinutes != null) sleepMinutes[row.date] = row.sleepMinutes!;
      if (row.deepSleepMinutes != null) {
        deepSleepMinutes[row.date] = row.deepSleepMinutes!;
      }
      if (row.caloriesKcal != null) calories[row.date] = row.caloriesKcal!;
      if (row.spikeCount != null) spikes[row.date] = row.spikeCount!;
      if (row.hrvRmssdMs != null) hrv[row.date] = row.hrvRmssdMs!;
    }

    return HistoryUnion(
      startDate: startDate,
      endDate: endDate,
      restingHr: restingHr,
      sleepMinutes: sleepMinutes,
      deepSleepMinutes: deepSleepMinutes,
      calories: calories,
      spikes: spikes,
      hrv: hrv,
      failedMetrics: failed,
      partialMetrics: partial,
      failureDetails: failureDetails,
    );
  }

  static int _rangeDayCount(String startDate, String endDate) {
    final s = DateTime.tryParse(startDate);
    final e = DateTime.tryParse(endDate);
    if (s == null || e == null) return 1;
    final days = e.difference(s).inDays + 1;
    return days < 1 ? 1 : days;
  }

  static List<String> _datesInRange(String startDate, String endDate) {
    final s = DateTime.tryParse(startDate);
    final e = DateTime.tryParse(endDate);
    if (s == null || e == null) return const [];
    final out = <String>[];
    var d = DateTime(s.year, s.month, s.day);
    final last = DateTime(e.year, e.month, e.day);
    while (!d.isAfter(last)) {
      out.add(historyDateStr(d));
      d = d.add(const Duration(days: 1));
    }
    return out;
  }
}
