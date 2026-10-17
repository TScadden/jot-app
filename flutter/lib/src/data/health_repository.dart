import 'dart:async';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
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

  const TodayVitals({
    this.heartRate,
    this.activeCalories,
    this.sleepMinutes,
    this.logCountToday = 0,
  });
}

class HealthRepository {
  final HealthConnectService hc;
  final TabsBackend backend;

  /// R70 WS1b — history capture hook (injectable for tests).
  final HealthHistorySync historySync;

  HealthRepository({
    HealthConnectService? hc,
    TabsBackend? backend,
    HealthHistorySync? historySync,
  })  : hc = hc ?? HealthConnectService(),
        backend = backend ?? TabsBackend(),
        historySync = historySync ?? HealthHistorySync.instance;

  /// Fire-and-forget history capture after a successful connected
  /// load. Behind the sync's 6h throttle, unawaited, and never
  /// throws — home load latency and behavior are unchanged.
  void _triggerHistoryCapture() {
    try {
      unawaited(historySync.capture());
    } catch (_) {}
  }

  Future<bool> _connected() async {
    try {
      return await hc.isConnected();
    } catch (_) {
      return false;
    }
  }

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
  /// When [connected] is false, biometrics stay null (the native empty
  /// state); the log count still comes from the backend when logged in.
  /// Never throws.
  Future<TodayVitals> loadTodayVitals({required bool connected}) async {
    // Round 60 — every source here is independent, so they run in
    // PARALLEL (measured at base: the log-count pull, then the HR,
    // calories, and sleep bridge reads ran one after another —
    // 4 × 150ms fakes = ~658ms; parallel lands at the max, ~150ms).
    // The log-count future starts FIRST and is awaited LAST so it
    // overlaps the Health Connect reads instead of gating them.
    final logCountFuture = _todayLogCount();
    if (!connected) {
      return TodayVitals(logCountToday: await logCountFuture);
    }

    int? heartRate;
    int? activeCalories;
    int? sleepMinutes;
    try {
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
      final reads = await Future.wait<Object?>([
        _hrSamplesOrEmpty(today),
        _caloriesOrNull(today),
        _sleepOrNull(today),
      ]);
      heartRate = daytimeHeartRateAvg(reads[0] as List<HrSample>);
      final cal = reads[1] as int?;
      // Biometric 0 = failed read → null, never shown/averaged.
      activeCalories = (cal != null && cal > 0) ? cal : null;
      final sleep = reads[2] as int?;
      sleepMinutes = (sleep != null && sleep > 0) ? sleep : null;
    } catch (_) {
      // Nulls stand — the UI shows "--".
    }
    final vitals = TodayVitals(
      heartRate: heartRate,
      activeCalories: activeCalories,
      sleepMinutes: sleepMinutes,
      logCountToday: await logCountFuture,
    );
    // R70 WS1b — values are computed; capture history behind the
    // throttle without blocking the return.
    _triggerHistoryCapture();
    return vitals;
  }

  /// Round 60 fix (Vera blocker) — per-read error isolation for the
  /// parallel vitals reads: a throwing read becomes its honest
  /// empty value instead of failing the whole [Future.wait].
  Future<List<HrSample>> _hrSamplesOrEmpty(String today) async {
    try {
      return await hc.readHeartRateSamples(today);
    } catch (_) {
      return const [];
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
  /// Health Connect metrics load ONLY when connected — otherwise the
  /// native empty state for that metric. Logs/habits/manual-BP come from
  /// the backend when a session token exists. Never throws.
  Future<WeeklySnapshotMetricData> loadSnapshot(SnapshotMetric metric) async {
    final window = sevenDayWindow();
    final dateStrs = [for (final w in window) w.dateStr];
    final labels = [for (final w in window) w.dayLabel];
    final connected = await _connected();
    final hcOnly = metric != SnapshotMetric.logs &&
        metric != SnapshotMetric.habitCompletion &&
        metric != SnapshotMetric.bloodPressure;
    if (!connected && hcOnly) return emptyMetricData(metric);
    // R70 WS1b — a connected snapshot load also feeds the history
    // store (throttled, fire-and-forget; the load below is
    // fail-soft and never throws past its honest empty states).
    if (connected) _triggerHistoryCapture();
    try {
      switch (metric) {
        case SnapshotMetric.sleepHours:
          // Round 60 — the 7 per-day reads are independent: parallel
          // (was a sequential loop, 7 × bridge latency at cold start).
          final sleepReads = await Future.wait([
            for (final d in dateStrs) hc.readSleepMinutes(d),
          ]);
          final mins = <String, int>{};
          for (var i = 0; i < dateStrs.length; i++) {
            final m = sleepReads[i];
            if (m != null && m > 0) mins[dateStrs[i]] = m;
          }
          return buildSleepMetric(dateStrs, labels, mins);
        case SnapshotMetric.restingHeartRate:
          final history = await hc.readRestingHrHistory(7);
          return buildRestingHrMetric(
              dateStrs, labels, {for (final h in history) h.date: h.bpm});
        case SnapshotMetric.hrSpikes:
          // Round 60 — same parallelization as sleepHours.
          final spikeReads = await Future.wait([
            for (final d in dateStrs) hc.readHeartRateSamples(d),
          ]);
          final counts = <String, int>{};
          for (var i = 0; i < dateStrs.length; i++) {
            final summary =
                computeDailyHrSummary(dateStrs[i], spikeReads[i]);
            counts[dateStrs[i]] = summary?.spikeCount ?? 0;
          }
          return buildSpikesMetric(dateStrs, labels, counts);
        case SnapshotMetric.calories:
          final history = await hc.readCaloriesHistory(7);
          return buildCaloriesMetric(
              dateStrs, labels, {for (final h in history) h.date: h.kcal});
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
          if (connected) records.addAll(await hc.readBloodPressure(7));
          if (await _loggedIn()) records.addAll(await backend.fetchManualBpLogs());
          return buildBpMetric(dateStrs, labels, records);
      }
    } catch (_) {
      return emptyMetricData(metric);
    }
  }

  /// Streak pair from the backend; nulls when logged out or on any
  /// failure — the streak row renders "--".
  Future<({int? current, int? best})> loadStreak() async {
    try {
      return await backend.fetchStreak();
    } catch (_) {
      return (current: null, best: null);
    }
  }
}

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
