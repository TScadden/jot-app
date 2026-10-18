import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';

/// Round 13 — pure health-data logic: no platform channel, fully testable.
///
/// Ports from the native app (`data/healthconnect/HealthConnectManager.kt`,
/// `data/repository/WeeklySnapshotRepository.kt`):
/// - [daytimeHeartRateAvg] — daytime-only (7am–11pm) HR average.
/// - [computeDailyHrSummary] — verbatim port of native
///   `computeDailyHeartRateSummary` (spike detection, 10th-percentile
///   baseline, day/night split).
/// - `build*Metric` snapshot builders — replicate the native
///   `WeeklySnapshotAggregator` exactly: same average texts, same empty
///   messages, same null-vs-0 rules.
///
/// FOUNDER HARD RULES (non-negotiable):
/// - A 0 in biometric data is a failed read — excluded BEFORE aggregating,
///   never charted, averaged, or cached. (`bpm <= 0`, `<= 0` for calories,
///   sleep minutes, resting HR.)
/// - Heart rate is daytime-only (device-local hour 7..22, i.e.
///   [07:00, 23:00)) everywhere — founder decision Oct 12, 2026
///   (Round 26), superseding the older 7 AM–10 PM (7..21) rule.
/// - Missing data → null → the UI's "--"/empty states. Never invented.

/// One raw intraday heart-rate sample.
class HrSample {
  final int timeMs; // epoch millis
  final int bpm;

  const HrSample({required this.timeMs, required this.bpm});
}

/// Per-day heart-rate summary — port of native `DailyHeartRateSummary`
/// (minus the event list, which no snapshot UI consumes).
class DailyHrSummary {
  static const int spikeThresholdBpm = 100;

  final String date; // "YYYY-MM-DD"
  final int avg;
  final int max;
  final int min;
  final int baseline; // 10th percentile — true resting estimate
  final int spikeCount;
  final int daySpikeCount; // events starting 7am–11pm
  final int nightSpikeCount; // events starting 11pm–7am
  final int awakeAvg; // daytime-only average (falls back to [avg])
  final int maxDelta; // max - baseline (POTS orthostatic delta)

  const DailyHrSummary({
    required this.date,
    required this.avg,
    required this.max,
    required this.min,
    required this.baseline,
    required this.spikeCount,
    required this.daySpikeCount,
    required this.nightSpikeCount,
    required this.awakeAvg,
    required this.maxDelta,
  });
}

/// Blood pressure record — covers both Health Connect reads
/// (`{t, sys, dia}`) and the manual-logs JSON string
/// (`{systolic, diastolic, timeEpochMs, ...}`).
class BpRecord {
  final int systolic;
  final int diastolic;
  final int timeEpochMs;

  const BpRecord({
    required this.systolic,
    required this.diastolic,
    required this.timeEpochMs,
  });

  /// Tolerant parse: [FormatException] on malformed input; callers skip.
  factory BpRecord.fromJson(Map<String, dynamic> map) {
    final sys = _asInt(map['systolic']);
    final dia = _asInt(map['diastolic']);
    final t = _asInt(map['timeEpochMs'] ?? map['t']);
    if (sys == null || dia == null || t == null) {
      throw const FormatException('Invalid blood pressure record');
    }
    return BpRecord(systolic: sys, diastolic: dia, timeEpochMs: t);
  }

  static int? _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// Habit DTO — mirrors native `HabitDtoModel` (id, title, target_time,
/// logs of date strings; other fields ignored).
class HabitDto {
  final String id;
  final String title;
  final List<String> logs; // "YYYY-MM-DD" entries

  /// Native `HabitDtoModel.target_time` — the plan row's time label.
  /// Native defaults a missing/null value to "Anytime" (the DTO's own
  /// default); the Today Summary port (round 35) needs it for the
  /// plan item's timeDisplay + overdue rule.
  final String targetTime;

  const HabitDto({
    required this.id,
    required this.title,
    required this.logs,
    this.targetTime = 'Anytime',
  });

  factory HabitDto.fromJson(Map<String, dynamic> map) {
    final logsRaw = map['logs'];
    final target = map['target_time']?.toString();
    return HabitDto(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      logs: logsRaw is List
          ? logsRaw.map((e) => e.toString()).toList()
          : const [],
      targetTime: target ?? 'Anytime',
    );
  }
}

/// One day in the 7-day snapshot window.
typedef WindowDay = ({String dateStr, String dayLabel});

/// 7-day window ending today (device-local), oldest → today.
List<WindowDay> sevenDayWindow() {
  final now = DateTime.now();
  const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return List.generate(7, (i) {
    final d = now.subtract(Duration(days: 6 - i));
    final dateStr =
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return (dateStr: dateStr, dayLabel: dayNames[d.weekday - 1]);
  });
}

/// Daytime-only (device-local hour 7..22) heart-rate average.
///
/// Zero-exclusion (founder rule): bpm ≤ 0 samples are dropped first.
/// When the day has NO daytime samples, falls back to the average of all
/// non-zero samples (native `awakeAvg` behavior). Null when nothing
/// usable remains — never 0.
int? daytimeHeartRateAvg(List<HrSample> samples) {
  int hourOf(int timeMs) => DateTime.fromMillisecondsSinceEpoch(timeMs).hour;
  final valid = samples.where((s) => s.bpm > 0).toList();
  if (valid.isEmpty) return null;
  final daytime = valid.where((s) {
    final h = hourOf(s.timeMs);
    return h >= 7 && h <= 22;
  }).toList();
  final source = daytime.isNotEmpty ? daytime : valid;
  final sum = source.fold<int>(0, (a, s) => a + s.bpm);
  return (sum / source.length).toInt();
}

/// Verbatim port of native `computeDailyHeartRateSummary`
/// (HealthConnectManager.kt):
/// - baseline = 10th percentile of sorted bpm values
/// - a spike event starts at the first reading ≥ 100 and absorbs
///   subsequent ≥100 readings within 5 minutes
/// - day/night split by the event START hour in 7..22
///
/// Round 27 note: the founder approved (Oct 12, 2026) aligning the
/// day/night SPIKE split with Round 26's unified awake window — event
/// starts in hour 7..22 ([07:00, 23:00)) classify as day, everything
/// else as night. This supersedes the Round 26 decision to leave the
/// split at the native 7..21.
///
/// Deviation from native (founder rule): bpm ≤ 0 samples are excluded
/// before the algorithm runs. Null when no usable samples remain.
DailyHrSummary? computeDailyHrSummary(String date, List<HrSample> samples) {
  final usable =
      samples.where((s) => s.bpm > 0).toList()
        ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  if (usable.isEmpty) return null;

  const threshold = DailyHrSummary.spikeThresholdBpm;
  final bpms = usable.map((s) => s.bpm).toList()..sort();
  final avg = (bpms.fold<int>(0, (a, b) => a + b) / bpms.length).toInt();
  final max = bpms.last;
  final min = bpms.first;
  var p10Index = (bpms.length * 0.10).toInt();
  if (p10Index < 0) p10Index = 0;
  final baseline = bpms[p10Index];
  final maxDelta = max - baseline;

  int hourOf(int timeMs) => DateTime.fromMillisecondsSinceEpoch(timeMs).hour;
  final daytime =
      usable.where((s) {
        final h = hourOf(s.timeMs);
        return h >= 7 && h <= 22;
      }).toList();
  final awakeAvg = daytime.isNotEmpty
      ? (daytime.fold<int>(0, (a, s) => a + s.bpm) / daytime.length).toInt()
      : avg;

  int dayCount = 0;
  int nightCount = 0;
  int currentEventPeak = 0;
  int currentEventStartHour = 0;
  bool inEvent = false;
  int eventEndMs = 0;

  for (final s in usable) {
    if (s.bpm >= threshold) {
      if (!inEvent || s.timeMs > eventEndMs) {
        if (inEvent) {
          if (currentEventStartHour >= 7 && currentEventStartHour <= 22) {
            dayCount++;
          } else {
            nightCount++;
          }
        }
        inEvent = true;
        currentEventStartHour = hourOf(s.timeMs);
        currentEventPeak = s.bpm;
      } else {
        if (s.bpm > currentEventPeak) currentEventPeak = s.bpm;
      }
      eventEndMs = s.timeMs + 300000; // 5 minutes
    }
  }
  if (inEvent) {
    if (currentEventStartHour >= 7 && currentEventStartHour <= 22) {
      dayCount++;
    } else {
      nightCount++;
    }
  }

  return DailyHrSummary(
    date: date,
    avg: avg,
    max: max,
    min: min,
    baseline: baseline,
    spikeCount: dayCount + nightCount,
    daySpikeCount: dayCount,
    nightSpikeCount: nightCount,
    awakeAvg: awakeAvg,
    maxDelta: maxDelta,
  );
}

// ── Snapshot builders — native WeeklySnapshotAggregator ports ────────────

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Sleep: value = minutes/60 hours; null when mins is null or ≤ 0.
WeeklySnapshotMetricData buildSleepMetric(
  List<String> dateStrs,
  List<String> dayLabels,
  Map<String, int> minsByDate,
) {
  final points = <DailySnapshotPoint>[];
  for (var i = 0; i < dateStrs.length; i++) {
    final mins = minsByDate[dateStrs[i]];
    points.add(DailySnapshotPoint(
      dateStr: dateStrs[i],
      dayLabel: dayLabels[i],
      value: (mins != null && mins > 0) ? mins / 60.0 : null,
    ));
  }
  final valid = points.map((p) => p.value).whereType<double>().toList();
  String avgText;
  String? emptyMsg;
  if (valid.isNotEmpty) {
    final avg = valid.reduce((a, b) => a + b) / valid.length;
    final h = avg.toInt();
    final m = ((avg - h) * 60).toInt();
    // R61 — compact sleep format via the single shared formatter
    // (founder ruling, Oct 15, 2026: `7h6m` everywhere). The h/m split
    // above keeps the native truncation semantics for the double-hours
    // average; only the rendering changed.
    avgText = '7-Day Avg: ${formatSleepMinutes(h * 60 + m)}';
  } else {
    avgText = 'Not enough sleep data yet';
    emptyMsg = 'Not enough sleep data yet';
  }
  return WeeklySnapshotMetricData(
    metric: SnapshotMetric.sleepHours,
    points: points,
    averageOrTotalText: avgText,
    emptyMessage: emptyMsg,
  );
}

/// Resting HR: null when bpm is null or ≤ 0.
WeeklySnapshotMetricData buildRestingHrMetric(
  List<String> dateStrs,
  List<String> dayLabels,
  Map<String, int> bpmByDate,
) {
  final points = <DailySnapshotPoint>[];
  for (var i = 0; i < dateStrs.length; i++) {
    final bpm = bpmByDate[dateStrs[i]];
    points.add(DailySnapshotPoint(
      dateStr: dateStrs[i],
      dayLabel: dayLabels[i],
      value: (bpm != null && bpm > 0) ? bpm.toDouble() : null,
    ));
  }
  final valid = points.map((p) => p.value).whereType<double>().toList();
  String avgText;
  String? emptyMsg;
  if (valid.isNotEmpty) {
    avgText = '7-Day Avg: ${(valid.reduce((a, b) => a + b) / valid.length).toInt()} bpm';
  } else {
    avgText = 'No heart rate data logged past 7 days';
    emptyMsg = 'No heart rate data logged past 7 days';
  }
  return WeeklySnapshotMetricData(
    metric: SnapshotMetric.restingHeartRate,
    points: points,
    averageOrTotalText: avgText,
    emptyMessage: emptyMsg,
  );
}

/// HR spikes: count per day (0 is REAL); null input → could-not-load state.
WeeklySnapshotMetricData buildSpikesMetric(
  List<String> dateStrs,
  List<String> dayLabels,
  Map<String, int>? countsByDate,
) {
  if (countsByDate == null) {
    return WeeklySnapshotMetricData(
      metric: SnapshotMetric.hrSpikes,
      points: [
        for (var i = 0; i < dateStrs.length; i++)
          DailySnapshotPoint(
              dateStr: dateStrs[i], dayLabel: dayLabels[i], value: null),
      ],
      averageOrTotalText: 'Could not load HR spike records',
      emptyMessage: 'Could not load HR spike records',
    );
  }
  final points = <DailySnapshotPoint>[];
  for (var i = 0; i < dateStrs.length; i++) {
    points.add(DailySnapshotPoint(
      dateStr: dateStrs[i],
      dayLabel: dayLabels[i],
      value: (countsByDate[dateStrs[i]] ?? 0).toDouble(),
    ));
  }
  final total =
      points.fold<int>(0, (a, p) => a + (p.value?.toInt() ?? 0));
  return WeeklySnapshotMetricData(
    metric: SnapshotMetric.hrSpikes,
    points: points,
    averageOrTotalText: '7-Day Total: $total spikes',
  );
}

/// Calories: null when kcal is null or ≤ 0.
WeeklySnapshotMetricData buildCaloriesMetric(
  List<String> dateStrs,
  List<String> dayLabels,
  Map<String, int> kcalByDate,
) {
  final points = <DailySnapshotPoint>[];
  for (var i = 0; i < dateStrs.length; i++) {
    final kcal = kcalByDate[dateStrs[i]];
    points.add(DailySnapshotPoint(
      dateStr: dateStrs[i],
      dayLabel: dayLabels[i],
      value: (kcal != null && kcal > 0) ? kcal.toDouble() : null,
    ));
  }
  final valid = points.map((p) => p.value).whereType<double>().toList();
  String avgText;
  String? emptyMsg;
  if (valid.isNotEmpty) {
    avgText = '7-Day Total: ${valid.fold<double>(0, (a, b) => a + b).toInt()} kcal';
  } else {
    avgText = 'No calorie data logged past 7 days';
    emptyMsg = 'No calorie data logged past 7 days';
  }
  return WeeklySnapshotMetricData(
    metric: SnapshotMetric.calories,
    points: points,
    averageOrTotalText: avgText,
    emptyMessage: emptyMsg,
  );
}

/// Logs: per-day counts from entry timestamps (device-local); 0 is real.
WeeklySnapshotMetricData buildLogsMetric(
  List<String> dateStrs,
  List<String> dayLabels,
  List<int> entryTimestampsMs,
) {
  final counts = <String, int>{};
  for (final t in entryTimestampsMs) {
    final key = _dateStr(DateTime.fromMillisecondsSinceEpoch(t));
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final points = <DailySnapshotPoint>[];
  for (var i = 0; i < dateStrs.length; i++) {
    points.add(DailySnapshotPoint(
      dateStr: dateStrs[i],
      dayLabel: dayLabels[i],
      value: (counts[dateStrs[i]] ?? 0).toDouble(),
    ));
  }
  final total = points.fold<int>(0, (a, p) => a + (p.value?.toInt() ?? 0));
  return WeeklySnapshotMetricData(
    metric: SnapshotMetric.logs,
    points: points,
    averageOrTotalText: '7-Day Total: $total logs',
  );
}

/// Habits: pct = completed/total*100 per day (completed when dateStr ∈
/// habit.logs); mirrors the native aggregator including its messages.
WeeklySnapshotMetricData buildHabitsMetric(
  List<String> dateStrs,
  List<String> dayLabels,
  List<HabitDto> habits,
  bool initialized,
) {
  if (!initialized) {
    return WeeklySnapshotMetricData(
      metric: SnapshotMetric.habitCompletion,
      points: [
        for (var i = 0; i < dateStrs.length; i++)
          DailySnapshotPoint(
              dateStr: dateStrs[i], dayLabel: dayLabels[i], value: null),
      ],
      averageOrTotalText: 'Loading habits...',
    );
  }
  final points = <DailySnapshotPoint>[];
  for (var i = 0; i < dateStrs.length; i++) {
    if (habits.isEmpty) {
      points.add(DailySnapshotPoint(
          dateStr: dateStrs[i], dayLabel: dayLabels[i], value: null));
    } else {
      final completed = habits.where((h) => h.logs.contains(dateStrs[i])).length;
      points.add(DailySnapshotPoint(
        dateStr: dateStrs[i],
        dayLabel: dayLabels[i],
        value: (completed / habits.length) * 100.0,
      ));
    }
  }
  final valid = points.map((p) => p.value).whereType<double>().toList();
  String avgText;
  String? emptyMsg;
  if (valid.isNotEmpty) {
    avgText =
        '7-Day Completion: ${(valid.reduce((a, b) => a + b) / valid.length).toInt()}%';
  } else {
    avgText = 'No habits configured';
  }
  if (habits.isEmpty) {
    emptyMsg = 'No habits configured';
  } else if (valid.isEmpty) {
    emptyMsg = 'No habit logs past 7 days';
  }
  return WeeklySnapshotMetricData(
    metric: SnapshotMetric.habitCompletion,
    points: points,
    averageOrTotalText: avgText,
    emptyMessage: emptyMsg,
  );
}

/// Blood pressure: per-day average sys/dia (HC + manual combined, grouped
/// device-local). No records at all → the native not-available state.
WeeklySnapshotMetricData buildBpMetric(
  List<String> dateStrs,
  List<String> dayLabels,
  List<BpRecord> records,
) {
  if (records.isEmpty) {
    return WeeklySnapshotMetricData(
      metric: SnapshotMetric.bloodPressure,
      points: [
        for (var i = 0; i < dateStrs.length; i++)
          DailySnapshotPoint(
              dateStr: dateStrs[i], dayLabel: dayLabels[i], value: null),
      ],
      averageOrTotalText: 'No blood pressure records found',
      isAvailable: false,
      emptyMessage: 'No blood pressure records found',
    );
  }
  final grouped = <String, List<BpRecord>>{};
  for (final r in records) {
    final key = _dateStr(DateTime.fromMillisecondsSinceEpoch(r.timeEpochMs));
    (grouped[key] ??= []).add(r);
  }
  final points = <DailySnapshotPoint>[];
  for (var i = 0; i < dateStrs.length; i++) {
    final dayRecords = grouped[dateStrs[i]];
    if (dayRecords == null || dayRecords.isEmpty) {
      points.add(DailySnapshotPoint(
          dateStr: dateStrs[i], dayLabel: dayLabels[i], value: null));
    } else {
      final avgSys =
          dayRecords.fold<int>(0, (a, r) => a + r.systolic) / dayRecords.length;
      final avgDia =
          dayRecords.fold<int>(0, (a, r) => a + r.diastolic) / dayRecords.length;
      points.add(DailySnapshotPoint(
        dateStr: dateStrs[i],
        dayLabel: dayLabels[i],
        value: avgSys,
        secondaryValue: avgDia,
      ));
    }
  }
  final validSys = points.map((p) => p.value).whereType<double>().toList();
  final validDia =
      points.map((p) => p.secondaryValue).whereType<double>().toList();
  String avgText;
  String? emptyMsg;
  if (validSys.isNotEmpty && validDia.isNotEmpty) {
    avgText =
        '7-Day Avg: ${(validSys.reduce((a, b) => a + b) / validSys.length).toInt()}/${(validDia.reduce((a, b) => a + b) / validDia.length).toInt()} mmHg';
  } else {
    avgText = 'No blood pressure data logged past 7 days';
  }
  if (validSys.isEmpty) {
    emptyMsg = 'No blood pressure data logged past 7 days';
  }
  return WeeklySnapshotMetricData(
    metric: SnapshotMetric.bloodPressure,
    points: points,
    averageOrTotalText: avgText,
    emptyMessage: emptyMsg,
  );
}
