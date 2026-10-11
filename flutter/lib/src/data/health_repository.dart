import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';

/// Round 13 — combines the Health Connect reads and the Tabs backend into
/// the home screen's data: today's vitals, the 7-day snapshot metrics,
/// and the streak pair.
///
/// Founder data rules enforced throughout:
/// - Biometric 0 = failed read → excluded before aggregating, never
///   charted/averaged/cached (see `health_data.dart`).
/// - HR is daytime-only (7am–10pm, device-local) everywhere.
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

  HealthRepository({HealthConnectService? hc, TabsBackend? backend})
      : hc = hc ?? HealthConnectService(),
        backend = backend ?? TabsBackend();

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
    int logCountToday = 0;
    try {
      final today = _dateStr(DateTime.now());
      final entries = await backend.fetchLogEntries();
      logCountToday = entries
          .where((t) =>
              _dateStr(DateTime.fromMillisecondsSinceEpoch(t)) == today)
          .length;
    } catch (_) {
      // 0 stays the fallback.
    }
    if (!connected) return TodayVitals(logCountToday: logCountToday);

    int? heartRate;
    int? activeCalories;
    int? sleepMinutes;
    try {
      final today = _dateStr(DateTime.now());
      heartRate = daytimeHeartRateAvg(await hc.readHeartRateSamples(today));
      final cal = await hc.readActiveCalories(today);
      activeCalories = (cal != null && cal > 0) ? cal : null;
      final sleep = await hc.readSleepMinutes(today);
      sleepMinutes = (sleep != null && sleep > 0) ? sleep : null;
    } catch (_) {
      // Nulls stand — the UI shows "--".
    }
    return TodayVitals(
      heartRate: heartRate,
      activeCalories: activeCalories,
      sleepMinutes: sleepMinutes,
      logCountToday: logCountToday,
    );
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
    try {
      switch (metric) {
        case SnapshotMetric.sleepHours:
          final mins = <String, int>{};
          for (final d in dateStrs) {
            final m = await hc.readSleepMinutes(d);
            if (m != null && m > 0) mins[d] = m;
          }
          return buildSleepMetric(dateStrs, labels, mins);
        case SnapshotMetric.restingHeartRate:
          final history = await hc.readRestingHrHistory(7);
          return buildRestingHrMetric(
              dateStrs, labels, {for (final h in history) h.date: h.bpm});
        case SnapshotMetric.hrSpikes:
          final counts = <String, int>{};
          for (final d in dateStrs) {
            final summary =
                computeDailyHrSummary(d, await hc.readHeartRateSamples(d));
            counts[d] = summary?.spikeCount ?? 0;
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
