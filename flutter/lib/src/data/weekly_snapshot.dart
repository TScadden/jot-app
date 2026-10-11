import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 8 — Weekly Snapshot data model.
///
/// Port of the native `data/model/WeeklySnapshotMetric.kt` enum,
/// `DailySnapshotPoint` / `WeeklySnapshotMetricData` (in
/// `data/repository/WeeklySnapshotRepository.kt`), and the
/// `WeeklySnapshotAggregator` empty-state strings.
///
/// DATA STATUS THIS ROUND: the real data sources are NOT wired in this
/// fresh app yet. Future hookups (native source in parentheses):
/// - sleep_hours → Health Connect sleep history
///   (`HealthConnectCoordinator.getSleepHistory`)
/// - resting_heart_rate → Health Connect heart-rate history
///   (`HealthConnectCoordinator.getHeartRateHistory`)
/// - hr_spikes → Health Connect HR-spike history
///   (`HealthConnectCoordinator.getHrSpikesHistory`)
/// - calories → Health Connect calories history
///   (`HealthConnectCoordinator.getCaloriesHistory`)
/// - logs → local log DB (`LogEntryDao.getEntriesInDateRangeDirect`)
/// - habit_completion → server habits (`HabitRepository.habits`)
/// - blood_pressure → `BloodPressureRepository` (Health Connect + manual)
///
/// Until then every metric reports the native empty state — no values
/// are invented. The one exception is Logs: the native aggregator
/// counts real log entries, and this fresh app genuinely has zero, so
/// it shows "7-Day Total: 0 logs" with an empty bar chart, exactly as
/// the native app does with no logs.
enum SnapshotMetric {
  sleepHours('sleep_hours', 'Sleep Hours', 'h'),
  restingHeartRate('resting_heart_rate', 'Resting Heart Rate', 'bpm'),
  hrSpikes('hr_spikes', 'HR Spikes', 'spikes'),
  calories('calories', 'Active Calories', 'kcal'),
  logs('logs', 'Logs', ''),
  habitCompletion('habit_completion', 'Habit Completion', '%'),
  bloodPressure('blood_pressure', 'Blood Pressure', 'mmHg');

  final String stableKey;
  final String displayName;
  final String unit;

  const SnapshotMetric(this.stableKey, this.displayName, this.unit);

  /// Line/bar color per metric, verbatim from native
  /// `WeeklySnapshotInteractiveCanvas`.
  Color get chartColor {
    switch (this) {
      case SnapshotMetric.sleepHours:
        return NotelColors.info;
      case SnapshotMetric.restingHeartRate:
        return NotelColors.heartRateRed;
      case SnapshotMetric.hrSpikes:
        return NotelColors.error;
      case SnapshotMetric.calories:
        return NotelColors.warning;
      case SnapshotMetric.logs:
        return NotelColors.success;
      case SnapshotMetric.habitCompletion:
        return NotelColors.warning;
      case SnapshotMetric.bloodPressure:
        return NotelColors.error; // systolic; diastolic uses NotelColors.info
    }
  }

  bool get isBarChart => switch (this) {
        SnapshotMetric.hrSpikes ||
        SnapshotMetric.calories ||
        SnapshotMetric.logs ||
        SnapshotMetric.habitCompletion =>
          true,
        _ => false,
      };

  bool get isBloodPressure => this == SnapshotMetric.bloodPressure;
}

/// One day's value. `value` is null when the day has no data —
/// never 0 as a placeholder (native "never show placeholder zeros" rule).
/// `secondaryValue` carries diastolic pressure for Blood Pressure.
class DailySnapshotPoint {
  final String dateStr; // "YYYY-MM-DD"
  final String dayLabel; // e.g. "Thu"
  final double? value;
  final double? secondaryValue;

  const DailySnapshotPoint({
    required this.dateStr,
    required this.dayLabel,
    required this.value,
    this.secondaryValue,
  });
}

class WeeklySnapshotMetricData {
  final SnapshotMetric metric;
  final List<DailySnapshotPoint> points; // always 7, oldest → today
  final String averageOrTotalText;
  final bool isAvailable;
  final String? emptyMessage;

  const WeeklySnapshotMetricData({
    required this.metric,
    required this.points,
    required this.averageOrTotalText,
    this.isAvailable = true,
    this.emptyMessage,
  });

  bool get isEmpty =>
      !isAvailable || (emptyMessage != null && points.every((p) => p.value == null));
}

/// Builds the honest empty-state data for a metric: 7 null points over
/// the last 7 days, with the native aggregator's exact empty message.
/// Logs is the exception — a real zero count, per the native aggregator.
WeeklySnapshotMetricData emptyMetricData(SnapshotMetric metric) {
  final now = DateTime.now();
  const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  List<DailySnapshotPoint> points(int nullCount) {
    return List.generate(7, (i) {
      final d = now.subtract(Duration(days: 6 - i));
      final dateStr =
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      return DailySnapshotPoint(
        dateStr: dateStr,
        dayLabel: dayNames[d.weekday - 1],
        value: null,
      );
    });
  }

  switch (metric) {
    case SnapshotMetric.sleepHours:
      return WeeklySnapshotMetricData(
        metric: metric,
        points: points(7),
        averageOrTotalText: 'Not enough sleep data yet',
        emptyMessage: 'Not enough sleep data yet',
      );
    case SnapshotMetric.restingHeartRate:
      return WeeklySnapshotMetricData(
        metric: metric,
        points: points(7),
        averageOrTotalText: 'No heart rate data logged past 7 days',
        emptyMessage: 'No heart rate data logged past 7 days',
      );
    case SnapshotMetric.hrSpikes:
      return WeeklySnapshotMetricData(
        metric: metric,
        points: points(7),
        averageOrTotalText: 'Could not load HR spike records',
        emptyMessage: 'Could not load HR spike records',
      );
    case SnapshotMetric.calories:
      return WeeklySnapshotMetricData(
        metric: metric,
        points: points(7),
        averageOrTotalText: 'No calorie data logged past 7 days',
        emptyMessage: 'No calorie data logged past 7 days',
      );
    case SnapshotMetric.logs:
      // Real: this fresh app has zero logs — the native aggregator shows
      // the raw count even when 0, so this is honest, not a placeholder.
      final now2 = DateTime.now();
      final zeroPoints = List.generate(7, (i) {
        final d = now2.subtract(Duration(days: 6 - i));
        final dateStr =
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        return DailySnapshotPoint(
          dateStr: dateStr,
          dayLabel: dayNames[d.weekday - 1],
          value: 0,
        );
      });
      return WeeklySnapshotMetricData(
        metric: metric,
        points: zeroPoints,
        averageOrTotalText: '7-Day Total: 0 logs',
      );
    case SnapshotMetric.habitCompletion:
      return WeeklySnapshotMetricData(
        metric: metric,
        points: points(7),
        averageOrTotalText: 'No habits configured',
        emptyMessage: 'No habits configured',
      );
    case SnapshotMetric.bloodPressure:
      return WeeklySnapshotMetricData(
        metric: metric,
        points: points(7),
        averageOrTotalText: 'No blood pressure records found',
        isAvailable: false,
        emptyMessage: 'No blood pressure records found',
      );
  }
}
