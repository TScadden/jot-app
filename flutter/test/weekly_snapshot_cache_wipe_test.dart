import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/data/weekly_snapshot_cache.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';

/// Vera BLOCKING fix (Oct 30, 2026): the Weekly Snapshot session
/// cache is account-bound health data, so the AccountActions
/// logout / reset / delete wipe (`_clearDefaultCaches`, which all
/// three funnels route through) must purge it — a departed
/// account's cached week must not survive logout in app-session
/// memory behind the login/register owner-mismatch guard.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cache = WeeklySnapshotCache.instance;

  WeeklySnapshotMetricData dataFor(SnapshotMetric metric) {
    final now = DateTime.now();
    return WeeklySnapshotMetricData(
      metric: metric,
      points: List.generate(7, (i) {
        final d = now.subtract(Duration(days: 6 - i));
        return DailySnapshotPoint(
          dateStr: d.toIso8601String().substring(0, 10),
          dayLabel: 'D$i',
          value: 6.0 + i * 0.25,
        );
      }),
      averageOrTotalText: 'Avg for ${metric.displayName}',
    );
  }

  setUp(() => cache.clear());
  tearDown(() => cache.clear());

  test(
      'logout wipe (AccountActions.clearDefaultCaches) empties a '
      'populated WeeklySnapshotCache and drops its owner binding',
      () async {
    // Bind the singleton to account A (the login-funnel call on an
    // empty, unowned cache binds without dropping anything), then
    // populate it as account A's Home visit would.
    expect(cache.clearIfOwnerMismatch('a@example.com'), isFalse);
    expect(cache.ownerEmail, 'a@example.com');
    cache.store(
        SnapshotMetric.sleepHours, dataFor(SnapshotMetric.sleepHours));
    cache.store(SnapshotMetric.restingHeartRate,
        dataFor(SnapshotMetric.restingHeartRate));
    expect(cache.lookup(SnapshotMetric.sleepHours), isNotNull);
    expect(cache.lookup(SnapshotMetric.restingHeartRate), isNotNull);

    await AccountActions.clearDefaultCaches();

    expect(cache.lookup(SnapshotMetric.sleepHours), isNull);
    expect(cache.lookup(SnapshotMetric.restingHeartRate), isNull);
    expect(cache.ownerEmail, isNull);
  });
}
