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
/// and records the failure in `lastReadErrorCode`; a PARTIAL read
/// (some chunks missing, real rows returned) records
/// `lastPartialErrorCode` instead and is reported in
/// [HistoryUnion.partialMetrics] — never as a failure. The union runs
/// the per-metric reads CONCURRENTLY and each read claims the
/// recorded code in its own completion continuation (see step 2b in
/// [HealthHistoryQueries.loadRange] for the attribution protocol) so
/// a failed metric is reported in [HistoryUnion.failedMetrics] —
/// callers that must not mistake an outage for emptiness (the Key
/// Metrics CSV export, Vera F5) check it; everyone else just gets
/// the honest store-backed remainder.
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
  });

  bool failed(HistoryMetric metric) => failedMetrics.contains(metric);

  bool partial(HistoryMetric metric) => partialMetrics.contains(metric);

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
  }) {
    final e = end ?? DateTime.now();
    final endDay = DateTime(e.year, e.month, e.day);
    final startDay = endDay.subtract(Duration(days: days - 1));
    return loadRange(
      startDate: historyDateStr(startDay),
      endDate: historyDateStr(endDay),
      metrics: metrics,
      fetchFromHealthConnect: fetchFromHealthConnect,
    );
  }

  /// Union for an explicit inclusive date range. Never throws:
  /// a failing source degrades to the other source's data, with
  /// HC failures named in [HistoryUnion.failedMetrics].
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
  }) async {
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
    final fetchDays = wantedFetch > maxHealthConnectFetchDays
        ? maxHealthConnectFetchDays
        : wantedFetch;

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

    // 2b. The per-metric HC reads run CONCURRENTLY (screen-load
    //     perf fix; this step used to await them one after another,
    //     so a 5-metric union cost the SUM of 5 bridge range reads).
    //     Concurrency is safe here: the reads touch independent
    //     bridge methods, Flutter MethodChannel replies are matched
    //     per call, and shipped code already Future.waits bridge
    //     reads over this same channel (health_repository.dart
    //     loadTodayVitals, R60; the Sleep screen's parallel per-day
    //     reads). The union's wall time is now the MAX of the reads.
    //
    //     Error attribution under concurrency: the service records
    //     a read's failure / partial signal in the shared
    //     lastReadErrorCode / lastPartialErrorCode fields BEFORE that
    //     read's future completes, and nothing else writes or clears
    //     them. So the fields are cleared ONCE, before any read
    //     starts, and each metric's loader CLAIMS the signal in its
    //     own completion continuation (reads the field, then clears
    //     it). Platform replies are delivered one message at a time
    //     and Dart microtasks — these continuations — flush between
    //     messages, so the first continuation to run after a signal
    //     is set is the one belonging to the read that set it:
    //     attribution stays per-metric, exactly as the old sequential
    //     clear-snapshot-check around each read. Per-read error
    //     isolation is preserved (the R60 Vera pattern): a loader
    //     that throws marks only its own metric failed and never
    //     fails the Future.wait or the union.
    hc.lastReadErrorCode = null;
    hc.lastPartialErrorCode = null;

    bool claimReadError() {
      final readFailed = hc.lastReadErrorCode != null;
      if (readFailed) hc.lastReadErrorCode = null;
      return readFailed;
    }

    bool claimPartial() {
      final readPartial = hc.lastPartialErrorCode != null;
      if (readPartial) hc.lastPartialErrorCode = null;
      return readPartial;
    }

    Future<void> loadRestingHr() async {
      try {
        final rows = await hc.readRestingHrHistory(fetchDays);
        if (claimReadError()) {
          failed.add(HistoryMetric.restingHr);
          return;
        }
        for (final r in rows) {
          // Zero rule, exactly as the readers it replaces.
          if (r.bpm > 0) putFresh(r.date, hr: r.bpm);
        }
      } catch (_) {
        failed.add(HistoryMetric.restingHr);
      }
    }

    Future<void> loadSleep() async {
      try {
        final rows = await hc.readSleepHistory(fetchDays);
        if (claimReadError()) {
          // Same-read hygiene: a failed read's partial signal is
          // not a warning anyone can act on — drain it so a later
          // loader's continuation cannot claim it as its own.
          claimPartial();
          failed.add(HistoryMetric.sleep);
          return;
        }
        // Partial data is data (F2): rows are processed; the
        // partial signal rides along as a warning, never as a
        // failed metric.
        if (claimPartial()) partial.add(HistoryMetric.sleep);
        for (final r in rows) {
          if (r.mins > 0) putFresh(r.date, sleep: r.mins);
          if (r.deep > 0) putFresh(r.date, deep: r.deep);
        }
      } catch (_) {
        claimPartial();
        failed.add(HistoryMetric.sleep);
      }
    }

    Future<void> loadCalories() async {
      try {
        final rows = await hc.readCaloriesHistory(fetchDays);
        if (claimReadError()) {
          failed.add(HistoryMetric.calories);
          return;
        }
        for (final r in rows) {
          if (r.kcal > 0) putFresh(r.date, kcal: r.kcal);
        }
      } catch (_) {
        failed.add(HistoryMetric.calories);
      }
    }

    Future<void> loadSpikes() async {
      try {
        final rows = await hc.readSpikeCounts(fetchDays);
        if (claimReadError()) {
          failed.add(HistoryMetric.spikes);
          return;
        }
        for (final r in rows) {
          // 0 spikes is REAL data (a sampled day, no spikes).
          if (r.count >= 0) putFresh(r.date, spikeCount: r.count);
        }
      } catch (_) {
        failed.add(HistoryMetric.spikes);
      }
    }

    Future<void> loadHrv() async {
      // R71 — ONE range read of raw HRV samples; day attribution +
      // the daily top-tier rule run in Dart (attributeDailyHrv).
      try {
        final samples = await hc.readHrvSamples(fetchDays);
        if (claimReadError()) {
          claimPartial();
          failed.add(HistoryMetric.hrv);
          return;
        }
        // Partial data is data (Defect 0): the surviving chunks'
        // samples are processed; the partial signal rides along
        // as a warning, exactly like sleep above.
        if (claimPartial()) partial.add(HistoryMetric.hrv);
        final dailyHrv = attributeDailyHrv(
            samples, _datesInRange(startDate, endDate).toSet());
        for (final entry in dailyHrv.entries) {
          if (entry.value > 0) putFresh(entry.key, hrvValue: entry.value);
        }
      } catch (_) {
        claimPartial();
        failed.add(HistoryMetric.hrv);
      }
    }

    await Future.wait([
      if (metrics.contains(HistoryMetric.restingHr)) loadRestingHr(),
      if (metrics.contains(HistoryMetric.sleep)) loadSleep(),
      if (metrics.contains(HistoryMetric.calories)) loadCalories(),
      if (metrics.contains(HistoryMetric.spikes)) loadSpikes(),
      if (metrics.contains(HistoryMetric.hrv)) loadHrv(),
    ]);

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
